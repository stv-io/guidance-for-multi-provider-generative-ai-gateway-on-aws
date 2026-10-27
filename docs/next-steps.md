# Next steps: picking the fork up again

Where the work stopped, and what to do next, in order.

## Where it stands (2026-10-27)

- `main` has everything: the phase 1 hardening, plus phase 2 (PR #2): health alarms, log
  hygiene, the LiteLLM upgrade routine with the provenance check, LiteLLM v1.106.4 with the
  rotated signing key, hidden API docs, and new smoke tests.
- The sandbox was redeployed on 2026-10-27 from the *Redeploy* checklist, tested, and torn down
  the same day. What remains in the account: the Terraform state bucket and the
  `sandbox.myops-lab.cloud` hosted zone.
- Last smoke run before the teardown: **43 pass, 1 fail** of 44. The failure is M5 for
  `eu.anthropic.claude-haiku-5-5` and `eu.anthropic.claude-sonnet-5-5` (403), see step 2.

## 1. Bring the sandbox back (about 30 minutes)

1. Check LiteLLM first: `scripts/litellm-bump.sh` moves to the newest patch on the current
   line and refuses images that fail the digest, signature or provenance checks. Read the
   release notes it lists. Commit the change on a branch.
2. Build `.env`: `cat .env.template envs/sandbox.env > .env`, then set
   `TERRAFORM_S3_BUCKET_NAME` and `ALARM_EMAIL` (both stay out of git).
3. `AWS_PROFILE=sandbox ./deploy.sh`. Off a terminal it stops after each plan with changes and
   keeps it as `tfplan`: review it, `terraform apply tfplan`, rerun `deploy.sh`. A fresh deploy
   is about 110 resources in the main stack and 4 in the log-bucket stack.
4. Confirm the SNS subscription email, then
   `AWS_PROFILE=sandbox ALL_MODELS=1 ./validation/smoke.sh`.

See [`deployment.md`](deployment.md) → *Deploy the sandbox* for detail.

## 2. Decision: the Claude 5.5 models

Bedrock serves `claude-haiku-5-5` and `claude-sonnet-5-5` only after a one-time AWS Marketplace
subscription per account. The gateway's task role can't subscribe (no
`aws-marketplace:Subscribe`), so M5 fails with 403. Either:

- send one prompt to each model from the Bedrock console playground (eu-west-1), which
  subscribes the account, then rerun M5; or
- remove the two models from `config/` for the EU regions.

## 3. Tests not yet run (phase 3)

| # | Test | How | Pass when |
|---|------|-----|-----------|
| 1 | Claude Code through the gateway | `ANTHROPIC_BASE_URL=https://<service-url>`, `ANTHROPIC_AUTH_TOKEN=<virtual key>`, `ANTHROPIC_MODEL=eu.anthropic.claude-sonnet-4-6`, `ANTHROPIC_DEFAULT_HAIKU_MODEL=eu.anthropic.claude-haiku-4-5-20251001-v1:0` | A real session works; spend shows on the key. M7/M7b already cover the API path |
| 2 | Latency overhead (PoC criterion 4) | `scripts/benchmark.py` against the gateway and against Bedrock directly | p95 overhead under 300 ms, non-streaming |
| 3 | Scale-out | Load above the 50% CPU target | The service grows from 1 to 2 tasks and back, with no errors. A few dollars of Haiku |
| 4 | Health alarm | Stop the task | The no-healthy-targets alarm goes to ALARM in CloudWatch, then back to OK |
| 5 | Admin UI by hand | Log in as `admin` with the master key; create a key and a team with a budget | Spend per key and team shows after use |

## 4. Decision: run the PoC

PoC criterion 2 needs 5 engineers on their own keys for 10 working days, so the sandbox has to
stay up for about two weeks (around $75–85/month plus Bedrock tokens). See
[`poc-success-criteria.md`](poc-success-criteria.md).

## 5. Later (not decided)

From [`decisions.md`](decisions.md) → *Open items*:

- **D3**: OIDC (Google) sign-in for `/user/new`.
- **TODO-2**: a scheduled LiteLLM upgrade check.
- A production-profile deploy (`envs/production.env`, own account), with AZ-loss, database
  failover and backup-restore tests.
- Langfuse tracing.
- Contributing fixes upstream to `aws-solutions-library-samples`: issue drafts exist but are
  not filed. Security findings go to AWS vulnerability reporting, not GitHub issues
  (upstream `CONTRIBUTING.md`).
