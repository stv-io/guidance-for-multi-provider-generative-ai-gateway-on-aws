"""Latency the gateway adds over calling Bedrock directly (PoC criterion 4).

Sends the same short, non-streaming prompt through the gateway (/v1/chat/completions) and
straight to Bedrock (Converse), alternating between the two so both see the same Bedrock
conditions. The gateway's response cache is bypassed. Reports p50/p95/p99 for each path and
the difference, plus LiteLLM's own x-litellm-overhead-duration-ms header.

  AWS_PROFILE=sandbox uv run python scripts/latency-overhead.py -n 50
  AWS_PROFILE=sandbox uv run python scripts/latency-overhead.py --model eu.amazon.nova-micro-v1:0

It reads the service URL from the Terraform outputs and creates (then deletes) a temporary
virtual key with the master key from Secrets Manager. Pass --base-url and --api-key to use an
existing key instead.
"""

import argparse
import json
import statistics
import subprocess
import sys
import time
import uuid
from datetime import UTC, datetime
from pathlib import Path

import boto3
import requests

REPO = Path(__file__).resolve().parent.parent
PASS_P95_MS = 300


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
    names = [
        s["Name"]
        for page in sm.get_paginator("list_secrets").paginate()
        for s in page["SecretList"]
        if s["Name"].startswith("LiteLLMMasterSalt")
    ]
    if not names:
        sys.exit("no LiteLLMMasterSalt-* secret found")
    return json.loads(sm.get_secret_value(SecretId=names[0])["SecretString"])[
        "LITELLM_MASTER_KEY"
    ]


def pct(values: list[float], p: float) -> float:
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, round(p / 100 * (len(ordered) - 1)))]


def summary(values: list[float]) -> dict:
    return {
        "n": len(values),
        "p50": round(pct(values, 50)),
        "p95": round(pct(values, 95)),
        "p99": round(pct(values, 99)),
        "mean": round(statistics.mean(values)),
    }


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "-n", type=int, default=50, help="measured requests per path (default 50)"
    )
    ap.add_argument(
        "--warmup", type=int, default=3, help="unmeasured requests per path first"
    )
    ap.add_argument(
        "--model",
        default="eu.anthropic.claude-haiku-4-5-20251001-v1:0",
        help="gateway model name; also the Bedrock model ID unless --bedrock-model is set",
    )
    ap.add_argument(
        "--bedrock-model",
        help="Bedrock model or inference profile ID for the direct path",
    )
    ap.add_argument("--max-tokens", type=int, default=16)
    ap.add_argument("--region", default="eu-west-1")
    ap.add_argument("--base-url", help="default: terraform output ServiceURL")
    ap.add_argument(
        "--api-key", help="an existing virtual key (default: a temporary one)"
    )
    ap.add_argument(
        "--out", help="results JSON (default: validation/results/latency-<time>.json)"
    )
    args = ap.parse_args()

    base = (args.base_url or tf_output("ServiceURL")).rstrip("/")
    if not base:
        sys.exit("no service URL: pass --base-url or deploy first")
    bedrock_model = args.bedrock_model or args.model
    http = requests.Session()

    temp_key = None
    key = args.api_key
    if not key:
        mk = master_key(args.region)
        r = http.post(
            f"{base}/key/generate",
            headers={"Authorization": f"Bearer {mk}"},
            json={
                "models": [args.model],
                "max_budget": 1,
                "key_alias": f"latency-{uuid.uuid4().hex[:8]}",
            },
            timeout=30,
        )
        r.raise_for_status()
        key = temp_key = r.json()["key"]
    headers = {"Authorization": f"Bearer {key}"}
    bedrock = boto3.client("bedrock-runtime", region_name=args.region)

    def via_gateway(prompt: str) -> tuple[float, float | None]:
        t0 = time.perf_counter()
        r = http.post(
            f"{base}/v1/chat/completions",
            headers=headers,
            timeout=60,
            json={
                "model": args.model,
                "max_tokens": args.max_tokens,
                "messages": [{"role": "user", "content": prompt}],
                "cache": {"no-cache": True},
            },
        )
        elapsed = (time.perf_counter() - t0) * 1000
        r.raise_for_status()
        overhead = r.headers.get("x-litellm-overhead-duration-ms")
        return elapsed, float(overhead) if overhead else None

    def direct(prompt: str) -> float:
        t0 = time.perf_counter()
        bedrock.converse(
            modelId=bedrock_model,
            messages=[{"role": "user", "content": [{"text": prompt}]}],
            inferenceConfig={"maxTokens": args.max_tokens},
        )
        return (time.perf_counter() - t0) * 1000

    gw, dr, litellm_overhead = [], [], []
    try:
        total = args.warmup + args.n
        for i in range(total):
            # A unique prompt per pair, so neither path can be served from a cache
            prompt = f"Reply with one word. Request {uuid.uuid4().hex[:8]}."
            # Alternate which path goes first, so neither always gets the warmer connection
            if i % 2:
                d = direct(prompt)
                g, o = via_gateway(prompt)
            else:
                g, o = via_gateway(prompt)
                d = direct(prompt)
            measured = i >= args.warmup
            if measured:
                gw.append(g)
                dr.append(d)
                if o is not None:
                    litellm_overhead.append(o)
            print(
                f"{'warmup' if not measured else f'{i - args.warmup + 1:>3}/{args.n}'}"
                f"  gateway {g:7.0f} ms   bedrock {d:7.0f} ms   diff {g - d:+6.0f} ms"
                + (f"   litellm overhead {o:5.0f} ms" if o is not None else ""),
                flush=True,
            )
    finally:
        if temp_key:
            http.post(
                f"{base}/key/delete",
                headers={"Authorization": f"Bearer {mk}"},
                json={"keys": [temp_key]},
                timeout=30,
            )

    result = {
        "time": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "base_url": base,
        "model": args.model,
        "bedrock_model": bedrock_model,
        "max_tokens": args.max_tokens,
        "gateway_ms": summary(gw),
        "bedrock_ms": summary(dr),
        "added_p50_ms": round(pct(gw, 50) - pct(dr, 50)),
        "added_p95_ms": round(pct(gw, 95) - pct(dr, 95)),
        "paired_diff_ms": summary([g - d for g, d in zip(gw, dr)]),
        "litellm_overhead_ms": summary(litellm_overhead) if litellm_overhead else None,
    }
    # Judged on the per-pair difference, which is stricter than the difference of the two p95s:
    # a slow Bedrock call in the direct path can't hide a slow gateway call
    result["pass"] = result["paired_diff_ms"]["p95"] < PASS_P95_MS

    print()
    print(f"{'':10}{'p50':>8}{'p95':>8}{'p99':>8}   (ms, n={args.n})")
    for name, s in [
        ("gateway", result["gateway_ms"]),
        ("bedrock", result["bedrock_ms"]),
    ]:
        print(f"{name:10}{s['p50']:>8}{s['p95']:>8}{s['p99']:>8}")
    if result["litellm_overhead_ms"]:
        s = result["litellm_overhead_ms"]
        print(
            f"{'litellm':10}{s['p50']:>8}{s['p95']:>8}{s['p99']:>8}   (x-litellm-overhead-duration-ms)"
        )
    verdict = "PASS" if result["pass"] else "FAIL"
    print(
        f"\nAdded latency: p50 {result['added_p50_ms']:+} ms, p95 {result['added_p95_ms']:+} ms"
        f"\nPer-request difference: p50 {result['paired_diff_ms']['p50']:+} ms,"
        f" p95 {result['paired_diff_ms']['p95']:+} ms  -> {verdict} (target: p95 < {PASS_P95_MS} ms)"
    )

    out = (
        Path(args.out)
        if args.out
        else REPO
        / "validation/results"
        / f"latency-{result['time'].replace(':', '')}.json"
    )
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(result, indent=2) + "\n")
    print(f"Results: {out.relative_to(REPO) if out.is_relative_to(REPO) else out}")
    sys.exit(0 if result["pass"] else 1)


if __name__ == "__main__":
    main()
