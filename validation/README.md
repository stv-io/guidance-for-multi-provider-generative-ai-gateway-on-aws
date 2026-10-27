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
| **I6** | Infra | Egress matches the profile | `NAT_GATEWAY_PER_AZ=true`: 2 available NAT gateways in 2 AZs; otherwise 1 |
| **I7** | Infra | The pinned LiteLLM version is running | `GET /health/readiness/details` (master key) reports `litellm_version` equal to `LITELLM_VERSION` (the build itself refuses an image whose tag no longer matches `LITELLM_IMAGE_DIGEST` or whose cosign signature fails) |
| **E1** | Edge | ALB is locked to CloudFront | VPC origin (default): the ALB scheme is `internal` and it cannot be reached from the internet. Public ALB: a request without the CloudFront secret header gets 403 |
| **E2** | Edge | HTTP is upgraded | `http://<cloudfront>/` redirects (301/302/307/308) to HTTPS |
| **E3** | Edge | LiteLLM is reachable through CloudFront | `GET /health/liveliness` returns 200 |
| **E4** | Edge | Middleware is reachable and can reach LiteLLM | `GET /bedrock/health/liveliness` returns 200 with `"litellm": "connected"` |
| **E5** | Edge | Admin UI is served | `GET /ui/` returns 200 HTML |
| **E6** | Edge | CloudFront → ALB is encrypted | With a custom domain and a VPC origin: the VPC origin's protocol policy is `https-only` |
| **E7** | Edge | Custom domain works | The service URL is `https://RECORD_NAME.HOSTED_ZONE_NAME`, it has A and AAAA records, and `/health/liveliness` returns 200 with certificate verification on |
| **E8** | Edge | Edge WAF is active | The distribution has a CLOUDFRONT-scope web ACL, and a request with a Log4Shell-style header (`${jndi:…}`) gets 403 |
| **E9** | Edge | Unauthenticated API docs are hidden | With `DISABLE_SWAGGER_PAGE=true`: `/redoc` and `/openapi.json` return 404, and `/` no longer serves Swagger UI (401: LiteLLM's authenticated home route) |
| **A1** | Auth | Unauthenticated calls are refused | `GET /v1/models` without a key returns 401 |
| **A2** | Auth | Bogus keys are refused | `GET /v1/models` with `sk-invalid…` returns 401 |
| **A3** | Auth | Model list is Bedrock-only | `GET /v1/models` with the master key lists exactly the models in `config/config.yaml` |
| **M1** | Models | OpenAI-style chat through middleware → LiteLLM → Bedrock | `POST /v1/chat/completions` (default model) returns a non-empty assistant message |
| **M2** | Models | Streaming works end to end through CloudFront | `stream: true` yields `data:` chunks and terminates with `[DONE]` |
| **M3** | Models | Embeddings work | `POST /v1/embeddings` (`amazon.titan-embed-text-v2:0`) returns a 1024-dimension vector |
| **M4** | Models | Bedrock-native API (LiteLLM pass-through) | `POST /bedrock/model/<id>/converse` returns `output.message.content[0].text` |
| **M4b** | Models | Bedrock-native streaming (LiteLLM pass-through) | `POST /bedrock/model/<id>/converse-stream` returns 200 with `contentBlockDelta` and `messageStop` events |
| **M6** | Models | Large (gzip-compressed) responses survive the middleware relay | A ~250-word non-streaming answer returns 200 with > 1000 characters |
| **M7** | Models | Anthropic Messages API, as Claude Code and the Anthropic SDKs call it | `POST /v1/messages` with the key in `x-api-key` and `anthropic-version` returns a `message` with text |
| **M7b** | Models | Anthropic streaming | `/v1/messages` with `stream: true` yields `content_block_delta` events and `message_stop` |
| **M5** | Models | Every configured chat model answers (`ALL_MODELS=1` only) | Each chat model in `config/config.yaml` returns 200 |
| **C1** | Cache | The response cache works and expires | `/cache/ping` reports the TTL from `LITELLM_CACHE_TTL_SECONDS`, and a repeated identical request returns `x-litellm-cache-key` with the same response id |
| **H1** | History | Chat history persists in Postgres | Chat with `enable_history: true` returns a `session_id`; a follow-up with that `session_id` succeeds; `POST /chat-history` returns ≥ 4 messages |
| **H2** | History | History is bound to its owner | `POST /chat-history` for that session using a *different* key returns 401 |
| **K1** | Keys | Virtual keys can be issued | `POST /key/generate` (master key) with `models: [<default model>]` returns an `sk-` key |
| **K2** | Keys | A virtual key can call its allowed model | Chat with the K1 key on the default model returns 200 |
| **K3** | Keys | Model restrictions are enforced | The K1 key on a model outside its list is rejected (401/403) |
| **K4** | Keys | Spend is tracked (Postgres write path) | `GET /key/info` for the K1 key shows `spend > 0` within 90 s |
| **T1** | Teams | Team budgets are enforced | A key in a team with `max_budget: 0.000001` is refused (LiteLLM 1.106 answers 422, "Budget has been exceeded") within 90 s of its first call. LiteLLM refuses only once spend exceeds the budget, so the first call goes through |
| **T2** | Teams | Team spend is tracked | A key in a team with budget left gets 200, and `/team/info` shows `spend > 0` within 90 s |
| **K5** | Keys | Rate limits are enforced (Valkey shared state) | A key with `rpm_limit: 1` gets 429 on its second request within the minute |
| **K7** | Keys | Only admins can mint keys (middleware gate) | `POST /key/generate` with the non-admin K1 key returns 403 (runs before K6) |
| **K6** | Keys | Revocation works on every task | After `POST /key/delete`, four requests in a row with the K1 key all get 401 within `user_api_key_cache_ttl` + 10 s (other tasks keep a cached copy of the key until that TTL) |
| **X1** | Spend | The Bedrock budget sees all Bedrock spend | Budget `<stack>-bedrock-monthly` exists, excludes credits, and its service filter contains every service Cost Explorer billed for Bedrock in the last 60 days (Anthropic models bill as `Claude … (Amazon Bedrock Edition)`) |
| **X2** | Spend | The near-real-time token alarm can reach someone | Alarm `<stack>-bedrock-tokens-per-hour` exists with an SNS action, and the email subscription is confirmed |
| **X3** | Health | Health alarms exist and are quiet | `2 + 4 + 3 + REDIS_NUM_CACHE_CLUSTERS` CloudWatch alarms named `<stack>-…`, none in `ALARM`; they have the SNS action only when `HEALTH_ALARM_NOTIFICATIONS=true` and `ALARM_EMAIL` is set (skipped with `HEALTH_ALARMS=false`) |
| **S1** | Security | Secrets are not logged | The last 30 min of the LiteLLM and middleware CloudWatch log groups contain neither the master key nor the K1 key |

## Adding tests

Each test is a function in `smoke.sh` named after its ID that calls `pass`, `fail`
or `skip`. Keep tests independent where possible; the K-series shares the key from K1.
