"""Scale-out test: load the gateway until ECS adds a task, then watch it scale back in.

Holds a fixed number of concurrent requests open against /v1/chat/completions for
--duration minutes, then stops and watches the service until it is back at its minimum
task count (or --scale-in-timeout passes). Every 30 s it prints the request rate, errors,
p95 latency, service CPU and the running/desired task counts.

By default requests carry LiteLLM's `mock_response`: the proxy does all its work (auth,
key and budget checks, routing, logging, spend writes) but makes no Bedrock call, so the
test costs nothing in tokens. LiteLLM ignores mock_response unless the key's metadata has
allow_client_mock_response: true, which the script sets on its temporary key. --real sends
real requests to --model instead.

The edge WAF allows CLOUDFRONT_WAF_RATE_LIMIT requests per 5 minutes per IP (2000 by
default, about 7/s), which is too few to load a task from one machine. Raise it in .env and
redeploy for the test, then put it back.

  AWS_PROFILE=sandbox uv run python scripts/load-test.py --concurrency 40 --duration 8
"""

import argparse
import asyncio
import json
import subprocess
import sys
import time
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path

import aiohttp
import boto3

REPO = Path(__file__).resolve().parent.parent


def tf_output(name: str) -> str:
    out = subprocess.run(
        ["terraform", "output", "-raw", name],
        cwd=REPO / "litellm-terraform-stack",
        capture_output=True,
        text=True,
    )
    return out.stdout.strip() if out.returncode == 0 else ""


def master_key(region: str) -> str:
    sm = boto3.client("secretsmanager", region_name=region)
    for page in sm.get_paginator("list_secrets").paginate():
        for s in page["SecretList"]:
            if s["Name"].startswith("LiteLLMMasterSalt"):
                return json.loads(
                    sm.get_secret_value(SecretId=s["Name"])["SecretString"]
                )["LITELLM_MASTER_KEY"]
    sys.exit("no LiteLLMMasterSalt-* secret found")


class Stats:
    def __init__(self) -> None:
        self.ok = 0
        self.errors: dict[str, int] = {}
        self.latencies: list[float] = []

    def take(self) -> tuple[int, dict[str, int], list[float]]:
        out = (self.ok, self.errors, self.latencies)
        self.ok, self.errors, self.latencies = 0, {}, []
        return out


async def worker(
    session, url, headers, body_fn, stats: Stats, stop: asyncio.Event
) -> None:
    while not stop.is_set():
        t0 = time.perf_counter()
        try:
            async with session.post(url, headers=headers, json=body_fn()) as r:
                await r.read()
                if r.status == 200:
                    stats.ok += 1
                    stats.latencies.append((time.perf_counter() - t0) * 1000)
                else:
                    stats.errors[str(r.status)] = stats.errors.get(str(r.status), 0) + 1
        except Exception as e:  # noqa: BLE001 - every failure is counted, not raised
            name = type(e).__name__
            stats.errors[name] = stats.errors.get(name, 0) + 1


def service_state(ecs, cw, cluster: str, service: str) -> dict:
    svc = ecs.describe_services(cluster=cluster, services=[service])["services"][0]
    now = datetime.now(UTC)
    points = cw.get_metric_statistics(
        Namespace="AWS/ECS",
        MetricName="CPUUtilization",
        Dimensions=[
            {"Name": "ClusterName", "Value": cluster},
            {"Name": "ServiceName", "Value": service},
        ],
        StartTime=now - timedelta(minutes=3),
        EndTime=now,
        Period=60,
        Statistics=["Average"],
    )["Datapoints"]
    cpu = max(points, key=lambda p: p["Timestamp"])["Average"] if points else None
    return {"running": svc["runningCount"], "desired": svc["desiredCount"], "cpu": cpu}


def p95(values: list[float]) -> float | None:
    return sorted(values)[int(0.95 * (len(values) - 1))] if values else None


async def run(args) -> int:
    base = (args.base_url or tf_output("ServiceURL")).rstrip("/")
    cluster, service = tf_output("LitellmEcsCluster"), tf_output("LitellmEcsTask")
    if not (base and cluster and service):
        sys.exit("could not read the Terraform outputs (deploy first)")
    ecs = boto3.client("ecs", region_name=args.region)
    cw = boto3.client("cloudwatch", region_name=args.region)
    aas = boto3.client("application-autoscaling", region_name=args.region)
    target = aas.describe_scalable_targets(
        ServiceNamespace="ecs", ResourceIds=[f"service/{cluster}/{service}"]
    )["ScalableTargets"][0]
    min_tasks, max_tasks = target["MinCapacity"], target["MaxCapacity"]

    mk = master_key(args.region)
    timeout = aiohttp.ClientTimeout(total=120)
    log: list[dict] = []
    async with aiohttp.ClientSession(
        timeout=timeout, connector=aiohttp.TCPConnector(limit=args.concurrency)
    ) as session:
        async with session.post(
            f"{base}/key/generate",
            headers={"Authorization": f"Bearer {mk}"},
            json={
                "models": [args.model],
                "max_budget": args.budget,
                "key_alias": f"load-{uuid.uuid4().hex[:8]}",
                # LiteLLM drops a client's mock_response unless the key allows it
                "metadata": {"allow_client_mock_response": not args.real},
            },
        ) as r:
            r.raise_for_status()
            key = (await r.json())["key"]
        headers = {"Authorization": f"Bearer {key}"}

        def body() -> dict:
            b = {
                "model": args.model,
                "max_tokens": 8,
                "messages": [
                    {"role": "user", "content": f"Say OK. {uuid.uuid4().hex}"}
                ],
            }
            if not args.real:
                b["mock_response"] = "OK"
            return b

        start = time.monotonic()
        state = service_state(ecs, cw, cluster, service)
        print(
            f"{base}  model={args.model} {'(real calls)' if args.real else '(mock_response, no Bedrock calls)'}"
        )
        print(
            f"Tasks min/max {min_tasks}/{max_tasks}; now running {state['running']}, desired {state['desired']}"
        )
        print(f"Load: {args.concurrency} concurrent requests for {args.duration} min\n")
        print(
            f"{'time':>6} {'phase':<8}{'req/s':>7}{'errors':>8}{'p95 ms':>8}{'cpu %':>7}  tasks"
        )

        stats, stop = Stats(), asyncio.Event()
        workers = [
            asyncio.create_task(
                worker(
                    session, f"{base}/v1/chat/completions", headers, body, stats, stop
                )
            )
            for _ in range(args.concurrency)
        ]
        peak, scaled_out_at, scaled_in_at, phase = state["desired"], None, None, "load"
        try:
            while True:
                t_tick = time.monotonic()
                await asyncio.sleep(args.interval)
                elapsed = time.monotonic() - start
                if phase == "load" and elapsed >= args.duration * 60:
                    stop.set()
                    await asyncio.gather(*workers, return_exceptions=True)
                    phase, load_end = "cooldown", elapsed
                ok, errors, lat = stats.take()
                state = await asyncio.to_thread(
                    service_state, ecs, cw, cluster, service
                )
                rate = ok / (time.monotonic() - t_tick)
                if state["desired"] > peak:
                    peak = state["desired"]
                if scaled_out_at is None and state["desired"] > min_tasks:
                    scaled_out_at = elapsed
                if (
                    phase == "cooldown"
                    and scaled_out_at
                    and state["desired"] == min_tasks
                    and state["running"] == min_tasks
                ):
                    scaled_in_at = elapsed
                row = {
                    "t": round(elapsed),
                    "phase": phase,
                    "ok": ok,
                    "rps": round(rate, 1),
                    "errors": errors,
                    "p95_ms": round(p95(lat)) if lat else None,
                    "cpu": state["cpu"],
                    "running": state["running"],
                    "desired": state["desired"],
                }
                log.append(row)
                cpu = f"{state['cpu']:.0f}" if state["cpu"] is not None else "-"
                err = sum(errors.values())
                print(
                    f"{int(elapsed // 60):>3}:{int(elapsed % 60):02d} {phase:<8}{rate:>7.1f}{err:>8}"
                    f"{row['p95_ms'] or '-':>8}{cpu:>7}  {state['running']}/{state['desired']}"
                    + (f"  {errors}" if errors else ""),
                    flush=True,
                )
                if scaled_in_at or (phase == "cooldown" and not scaled_out_at):
                    break
                if (
                    phase == "cooldown"
                    and elapsed - load_end > args.scale_in_timeout * 60
                ):
                    print("Scale-in timeout reached")
                    break
        finally:
            stop.set()
            async with session.post(
                f"{base}/key/delete",
                headers={"Authorization": f"Bearer {mk}"},
                json={"keys": [key]},
            ) as r:
                await r.read()

    total_ok = sum(r["ok"] for r in log)
    total_err = sum(sum(r["errors"].values()) for r in log)
    result = {
        "time": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "base_url": base,
        "model": args.model,
        "mock": not args.real,
        "concurrency": args.concurrency,
        "duration_min": args.duration,
        "min_tasks": min_tasks,
        "max_tasks": max_tasks,
        "peak_desired": peak,
        "scaled_out_after_s": round(scaled_out_at) if scaled_out_at else None,
        "scaled_in_after_load_s": round(scaled_in_at - load_end)
        if scaled_in_at
        else None,
        "requests_ok": total_ok,
        "errors": total_err,
        "log": log,
    }
    result["pass"] = bool(scaled_out_at and scaled_in_at) and total_err <= 0.01 * max(
        total_ok, 1
    )
    print()
    print(
        f"Scale-out: {'after ' + str(result['scaled_out_after_s']) + ' s' if scaled_out_at else 'did not happen'}"
        f" (peak {peak} tasks)"
    )
    print(
        f"Scale-in:  {str(result['scaled_in_after_load_s']) + ' s after the load stopped' if scaled_in_at else 'not seen'}"
    )
    print(f"Requests:  {result['requests_ok']} ok, {total_err} errors")
    print(f"Result:    {'PASS' if result['pass'] else 'FAIL'}")
    out = REPO / "validation/results" / f"load-{result['time'].replace(':', '')}.json"
    out.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Results:   {out.relative_to(REPO)}")
    return 0 if result["pass"] else 1


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--concurrency", type=int, default=40)
    ap.add_argument(
        "--duration", type=float, default=8, help="minutes of load (default 8)"
    )
    ap.add_argument(
        "--scale-in-timeout",
        type=float,
        default=30,
        help="minutes to wait for scale-in",
    )
    ap.add_argument(
        "--interval", type=int, default=30, help="seconds between status lines"
    )
    ap.add_argument("--model", default="eu.amazon.nova-micro-v1:0")
    ap.add_argument(
        "--real",
        action="store_true",
        help="real Bedrock calls instead of mock_response",
    )
    ap.add_argument(
        "--budget", type=float, default=2, help="max_budget of the temporary key, USD"
    )
    ap.add_argument("--region", default="eu-west-1")
    ap.add_argument("--base-url")
    sys.exit(asyncio.run(run(ap.parse_args())))


if __name__ == "__main__":
    main()
