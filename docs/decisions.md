# Decisions on this fork

Decisions taken while turning the AWS sample into a small, production-capable gateway
(October 2026). Each entry says what was decided, why, and where it shows up in the code
or tests. Test IDs refer to [`validation/README.md`](../validation/README.md).

| ID | Decision | Why | Where |
|----|----------|-----|-------|
| D1a | Drop the EKS deployment path; ECS Fargate only | Never deployed or tested here, and it doubled the Terraform and scripts to maintain | Removed `modules/eks`; a `moved` block keeps the ECS state addresses |
| D1b | Serve Bedrock-native calls (`/bedrock/model/*/converse`, `/converse-stream`, `/invoke`) through LiteLLM's pass-through instead of the middleware's Converse-to-OpenAI shim | LiteLLM handles them natively and tracks spend on the key; the shim was about 480 lines of translation with no tests | `alb.tf` routes, `middleware/app.py`; tests M4, M4b |
| D2 | Production hardening: HTTPS from CloudFront to the internal ALB, edge WAF on CloudFront, optional NAT per AZ, LiteLLM pinned by digest and cosign-verified | Close the plain-HTTP hop, block abuse before it reaches the VPC, survive an AZ loss, and run only a known image | `cloudfront.tf`, `waf.tf`, `certificates.tf`, `NAT_GATEWAY_PER_AZ`, `LITELLM_IMAGE_DIGEST`; tests E6, E7, E8, I6, I7 |
| DOM | The stack requests and DNS-validates its own ACM certificates (us-east-1 for CloudFront, the stack region for the ALB) and creates A/AAAA aliases | A new environment needs only a hosted zone, with no manual certificate work | `certificates.tf`, `route53.tf`; test E7 |
| D4 | Spend alarms by email: an AWS Budgets budget on Bedrock cost, excluding credits, and a CloudWatch alarm on Bedrock tokens per hour through SNS | Budgets lag by hours; the token alarm fires within the hour. Credits are excluded so the budget still fires on credit-funded accounts | `alarms.tf`, `ALARM_EMAIL` (in `.env` only); tests X1, X2 |
| D5 | Autoscale on CPU only; the memory policy is optional and off | LiteLLM idles at about 45% of a 2 GB task, and target tracking assumes memory falls when a task is removed, so any memory target kept an extra task running | `ECS_MEMORY_TARGET_UTILIZATION_PERCENTAGE=0`, `alb.tf` |
| D6 | Keep the shared response cache, with a 1-hour TTL; LiteLLM debug logging off | Without a TTL, `volatile-lru` can't evict cache entries and they crowd out the rate-limit state. Debug logging can write prompts to the logs. Clients opt out per request with `"cache": {"no-cache": true}` | `config/default-config-base.yaml`, `LITELLM_CACHE_TTL_SECONDS`; test C1 |
| — | Key cache TTL 10 s (`general_settings.user_api_key_cache_ttl`) | LiteLLM evicts a deleted key only on the task that handled the delete, so other tasks accepted it for up to 60 s | `default-config-base.yaml`; test K6 |

## Open items (not decided)

Recorded so they aren't lost. Nothing has been chosen for any of them.

| ID | Item | Why it matters | Options to weigh |
|----|------|----------------|------------------|
| D3 | Google (or any OIDC) sign-in for `/user/new` | The middleware verifies Okta JWTs only, so self-service user creation doesn't work with Google Workspace or Entra ID | A generic OIDC/JWKS check (issuer, audience, JWKS URL as settings); LiteLLM's own SSO for the Admin UI instead; or drop `/user/new` and issue keys centrally |
| TODO-1 | Health alarms | The only alarms watch spend; an outage or a full database would go unnoticed | ALB 5xx rate and unhealthy targets, ECS running tasks below desired, RDS CPU, free storage and connections, Valkey memory; all to the existing SNS topic |
| TODO-2 | LiteLLM upgrade routine | LiteLLM releases almost daily, and the build refuses an image unless `LITELLM_VERSION` and `LITELLM_IMAGE_DIGEST` match and the cosign signature verifies | A monthly manual bump (version + digest, deploy, `smoke.sh`); a Renovate or Dependabot PR that updates both; how far behind latest to stay; who reviews the release notes |

## Bugs fixed (all present upstream)

- The middleware returned 200 for LiteLLM's 401/403/429 on `/v1/chat/completions`, so key
  model limits, rate limits and revocation looked like successes; streams became an empty 200.
  Tests K3, K5, K6.
- Non-admin keys could mint new keys through `/key/generate`; the middleware now requires the
  master key or `proxy_admin`. Test K7.
- Large responses through CloudFront were corrupted by a stale `Content-Encoding: gzip`
  header, and streams were missing the `data: [DONE]` terminator. Tests M2, M6.
- Secrets (master key, request headers, raw JWT) were printed to the logs. Test S1.
- A module-level `depends_on` made every plan show spurious IAM and task-definition changes.
  Test I1.
- Upstream, the HTTPS listener's catch-all secret-header rule shadowed every middleware path.

## Lessons for the next deployment

- Switching a live stack's CloudFront VPC origin from HTTP to HTTPS needs a `state rm`
  sequence and caused a 13-minute outage in the sandbox. A fresh deploy is not affected. See
  [`deployment.md`](deployment.md) → *Known limits*.
- A linked account can't activate cost-allocation tags, so measure infrastructure cost by
  service in Cost Explorer.
