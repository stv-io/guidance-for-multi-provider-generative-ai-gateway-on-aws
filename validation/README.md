# Deployment validation

`validation/smoke.sh` checks a deployed gateway end to end. Run it after every
`deploy.sh`. It reads the endpoints from Terraform outputs and the master key
from Secrets Manager, so the only input is an AWS profile.

```bash
AWS_PROFILE=sandbox ./validation/smoke.sh            # all tests
AWS_PROFILE=sandbox ALL_MODELS=1 ./validation/smoke.sh  # also call every configured chat model once
AWS_PROFILE=sandbox SKIP_PLAN=1 ./validation/smoke.sh   # skip the terraform drift check
```

Requirements: `aws` CLI v2, `terraform`, `curl`, `jq`. It must be run from the repo
root after `deploy.sh` has written the backend config (`backend.hcl`) for both stacks.

Each test prints `PASS` / `FAIL` / `SKIP` with its ID; the script exits non-zero if
any test fails. A JSON copy of the results is written to `validation/results/`
(gitignored).

The script creates temporary virtual keys and deletes them again before it exits.
Bedrock calls use short prompts (`max_tokens` of 5–20), so a full run costs a fraction
of a cent; `ALL_MODELS=1` costs a few cents.

## Tests

| ID | Area | What it proves | Pass criterion |
|----|------|----------------|----------------|
| **I1** | Infra | Terraform state matches the code | `terraform plan -detailed-exitcode` returns 0 (no changes) for the log-bucket and main stacks |
| **I2** | Infra | Database is the intended size and version | RDS instance: engine `postgres` with the major version from `rds.tf`, class from `.env`, `MultiAZ` matches `RDS_MULTI_AZ`, storage encrypted |
| **I3** | Infra | Cache is the intended engine and size | ElastiCache replication group: engine `valkey`, node type from `.env`, transit and at-rest encryption on |
| **I4** | Infra | Service is healthy on Graviton | ECS service `runningCount == desiredCount`, task `cpuArchitecture == ARM64`, every container `HEALTHY` |
| **I5** | Infra | Cost profile: no interface endpoints | The stack VPC has no `Interface` VPC endpoints when outbound access is enabled, and does have the S3 `Gateway` endpoint |
| **E1** | Edge | ALB is locked to CloudFront | A request straight to the ALB without the CloudFront secret header is rejected (403) |
| **E2** | Edge | HTTP is upgraded | `http://<cloudfront>/` redirects (301/302/307/308) to HTTPS |
| **E3** | Edge | LiteLLM is reachable through CloudFront | `GET /health/liveliness` returns 200 |
| **E4** | Edge | Middleware is reachable and can reach LiteLLM | `GET /bedrock/health/liveliness` returns 200 with `"litellm": "connected"` |
| **E5** | Edge | Admin UI is served | `GET /ui/` returns 200 HTML |
| **A1** | Auth | Unauthenticated calls are refused | `GET /v1/models` without a key returns 401 |
| **A2** | Auth | Bogus keys are refused | `GET /v1/models` with `sk-invalid…` returns 401 |
| **A3** | Auth | Model list is Bedrock-only | `GET /v1/models` with the master key lists exactly the models in `config/config.yaml` |
| **M1** | Models | OpenAI-style chat through middleware → LiteLLM → Bedrock | `POST /v1/chat/completions` (default model) returns a non-empty assistant message |
| **M2** | Models | Streaming works end to end through CloudFront | `stream: true` yields `data:` chunks and terminates with `[DONE]` |
| **M3** | Models | Embeddings work | `POST /v1/embeddings` (`amazon.titan-embed-text-v2:0`) returns a 1024-dimension vector |
| **M4** | Models | Bedrock-native API (middleware) | `POST /bedrock/model/<id>/converse` returns `output.message.content[0].text` |
| **M5** | Models | Every configured chat model answers (`ALL_MODELS=1` only) | Each chat model in `config/config.yaml` returns 200 |
| **H1** | History | Chat history persists in Postgres | Chat with `enable_history: true` returns a `session_id`; a follow-up with that `session_id` succeeds; `POST /chat-history` returns ≥ 4 messages |
| **H2** | History | History is bound to its owner | `POST /chat-history` for that session using a *different* key returns 401 |
| **K1** | Keys | Virtual keys can be issued | `POST /key/generate` (master key) with `models: [<default model>]` returns an `sk-` key |
| **K2** | Keys | A virtual key can call its allowed model | Chat with the K1 key on the default model returns 200 |
| **K3** | Keys | Model restrictions are enforced | The K1 key on a model outside its list is rejected (401/403) |
| **K4** | Keys | Spend is tracked (Postgres write path) | `GET /key/info` for the K1 key shows `spend > 0` within 90 s |
| **K5** | Keys | Rate limits are enforced (Valkey shared state) | A key with `rpm_limit: 1` gets 429 on its second request within the minute |
| **K7** | Keys | Only admins can mint keys (middleware gate) | `POST /key/generate` with the non-admin K1 key returns 403 (runs before K6) |
| **K6** | Keys | Revocation works | After `POST /key/delete`, the K1 key is rejected (401) |
| **S1** | Security | Secrets are not logged | The last 30 min of the LiteLLM and middleware CloudWatch log groups contain neither the master key nor the K1 key |

## Adding tests

Each test is a function in `smoke.sh` named after its ID that calls `pass`, `fail`
or `skip`. Keep tests independent where possible; the K-series shares the key from K1.
