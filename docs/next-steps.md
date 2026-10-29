# Next steps: picking the fork up again

Where the work stopped, and what to do next, in order.

## Where it stands (2026-10-29)

- `main` has everything: the phase 1 hardening, phase 2 (PR #2: health alarms, log hygiene,
  the LiteLLM upgrade routine with the provenance check, hidden API docs, new smoke tests) and
  phase 3 (PR #3: the performance and resilience test scripts, the faster outage alarm,
  LiteLLM v1.106.5).
- The sandbox was redeployed on 2026-10-28, tested, and torn down on 2026-10-29. What remains
  in the account: the Terraform state bucket, the `sandbox.example.com` hosted zone, and
  the Marketplace agreements for the Claude 5.5 models (account-level, no standing cost).
- Last smoke run before the teardown (`ALL_MODELS=1`): **44 pass** of 44.

## 1. Bring the sandbox back (about 30 minutes)

1. Check LiteLLM first: `scripts/litellm-bump.sh` moves to the newest patch on the current
   line and refuses images that fail the digest, signature or provenance checks. Read the
   release notes it lists. Commit the change on a branch.
2. Build `.env`: `cat .env.template envs/sandbox.env > .env`, then set
   `TERRAFORM_S3_BUCKET_NAME`, `HOSTED_ZONE_NAME` and `ALARM_EMAIL` (all stay out of git).
3. `AWS_PROFILE=sandbox ./deploy.sh`. Off a terminal it stops after each plan with changes and
   keeps it as `tfplan`: review it, `terraform apply tfplan`, rerun `deploy.sh`. A fresh deploy
   is about 110 resources in the main stack and 4 in the log-bucket stack.
4. Confirm the SNS subscription email (a new one is sent on every deploy), then
   `AWS_PROFILE=sandbox ALL_MODELS=1 ./validation/smoke.sh`.

See [`deployment.md`](deployment.md) → *Deploy the sandbox* for detail.

## 2. The Claude 5.5 models (done 2026-10-29)

Bedrock serves `claude-haiku-5-5` and `claude-sonnet-5-5` only after a one-time AWS Marketplace
agreement per account; the gateway's task role can't create it (no `aws-marketplace:Subscribe`).
The sandbox account now has both, accepted with
`aws bedrock create-foundation-model-agreement` (offer token from
`list-foundation-model-agreement-offers`). It took about a minute to become `AVAILABLE`, and
the gateway kept returning 403 for a few minutes after that. A new account (production) needs
the same step, or one prompt to each model in the Bedrock console playground.

## 3. Phase 3 tests (run 2026-10-28)

| Test | Result |
|------|--------|
| Latency overhead (`scripts/latency-overhead.py`, Haiku 4.5, n=50) | **Pass.** Per-request difference p50 +61 ms, p95 +191 ms (target < 300 ms). LiteLLM's own overhead p50 16 ms, p95 30 ms; the rest is CloudFront and the middleware hop |
| Scale-out (`scripts/load-test.py`, mocked responses) | **Pass.** 17,190 requests, 0 errors. Out to 2 tasks after 275 s, back to 1 about 17 minutes after the load stopped. One 1-vCPU task serves ~27 requests a second |
| Health alarm (`scripts/alarm-test.sh`) | **Pass after a fix.** A crashed task was replaced in ~110 s without alarming (shorter than the 3-minute rule). A full outage first alarmed only after ~10 minutes, because the ALB publishes no data with no targets; the alarm now uses `FILL(HealthyHostCount, 0)` and fired after ~6 minutes |
| Claude Code | **Pass.** A real session through the gateway with an Admin-UI key: wrote a test, fixed the bug, ran the tests; spend shows on the key and team |
| Admin UI | **Pass.** Team with models and a monthly budget, a key inside it with its own budget and rpm limit, spend by key and team, request logs |

Screen recordings of the admin and engineer journeys were made with `vhs` (terminal) and
Playwright (Admin UI, key text blurred). They are not in the repo.

## 4. Decision: run the PoC

PoC criterion 2 needs 5 engineers on their own keys for 10 working days, so the sandbox has to
stay up for about two weeks (around $75–85/month plus Bedrock tokens). See
[`poc-success-criteria.md`](poc-success-criteria.md).

## 5. Later (not decided)

From [`decisions.md`](decisions.md) → *Open items*:

- **D3**: OIDC (Google) sign-in for `/user/new`.
- **TODO-2**: a scheduled LiteLLM upgrade check.
- Admin UI sign-in: create named admin users or SSO, then set
  `general_settings.disable_env_credential_login: true` (LiteLLM warns that master-key sign-in is
  a shared static secret).
- Faster outage detection, if 6 minutes is too slow: a synthetic check (Route 53 health check or
  CloudWatch Synthetics) on `/health/liveliness`.
- A production-profile deploy (`envs/production.env`, own account), with AZ-loss, database
  failover and backup-restore tests.
- Langfuse tracing.
- Contributing fixes upstream to `aws-solutions-library-samples`: issue drafts exist but are
  not filed. Security findings go to AWS vulnerability reporting, not GitHub issues
  (upstream `CONTRIBUTING.md`).
