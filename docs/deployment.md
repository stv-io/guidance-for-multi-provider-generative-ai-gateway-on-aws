# Deploying the gateway (MyOps fork)

This fork of the AWS sample deploys a small, cheap sandbox by default. The same
code scales out to a production setup on your own domain by switching to a
different environment profile. Diagrams are in [`docs/diagrams/`](diagrams/README.md).

## What gets deployed

| Layer | Sandbox (`envs/sandbox.env`) | Production (`envs/production.env`) |
|---|---|---|
| Entry | CloudFront on `https://llm.sandbox.myops-lab.cloud` (A + AAAA alias), edge WAF | CloudFront on `RECORD_NAME.HOSTED_ZONE_NAME`, edge WAF |
| Certificates | requested and DNS-validated by the stack: us-east-1 (CloudFront) + eu-west-1 (ALB) | same, or bring your own ARNs |
| CloudFront → ALB | VPC origin to an **internal** ALB over **HTTPS**; traffic stays on the AWS network | same |
| ALB | private subnets, SG admits only the CloudFront origin-facing prefix list, TLS 1.3 policy, forwards only requests with the CloudFront secret header | same |
| WAF | CLOUDFRONT-scope web ACL: AWS common rules, known bad inputs, IP reputation, 2,000 requests / 5 min per IP | same |
| Compute | ECS Fargate ARM64, 1 task × 1 vCPU / 2 GB (autoscale 1–2) | 2–6 tasks × 2 vCPU / 4 GB |
| App | LiteLLM v1.106.5 pinned by digest, cosign- and provenance-verified (:4000), middleware (:3000), both in one task | same |
| Database | RDS PostgreSQL 18, `db.t4g.micro`, single-AZ | `db.t4g.medium`, Multi-AZ, 50 GB |
| Cache | ElastiCache Valkey 9.1, 1 × `cache.t4g.micro` | 2 × `cache.t4g.small`, Multi-AZ with automatic failover |
| Network | new VPC, 2 public + 2 private subnets, 1 NAT gateway, S3 gateway endpoint | same, with one NAT gateway per AZ (`NAT_GATEWAY_PER_AZ=true`) |
| Models | Bedrock only (EU cross-region inference profiles), `INCLUDE_BASE_MODELS=false` | same; add providers by setting their API keys |
| Estimated cost | ~$75–85/month before Bedrock tokens | dominated by Multi-AZ RDS, task count and NAT data |

## Prerequisites

- An AWS account and a CLI profile with admin rights in it. Use a separate
  account per environment; stack names are fixed, so there can only be one
  deployment per account and region.
- Bedrock model access for the models in `config/default-config-<region>.yaml`.
- Docker with BuildKit, `terraform` ≥ 1.6, `yq` v4, `jq`, AWS CLI v2. The images
  are built for the `CPU_ARCHITECTURE` set in the profile (`arm` = Graviton).
- `cosign`, so the build verifies the LiteLLM image signature. Without it the check is
  skipped with a warning. `curl` and `dig` for `validation/smoke.sh`.
- An optional `uv` for the Python tests and tools (see README → *Python tooling*).

## Deploy the sandbox

```bash
cat .env.template envs/sandbox.env > .env     # later lines win
# set TERRAFORM_S3_BUCKET_NAME in .env (globally unique; created if missing)
rm -f config/config.yaml                      # regenerate from the model lists
AWS_PROFILE=sandbox ./deploy.sh               # plans each stack, asks before applying
AWS_PROFILE=sandbox ./validation/smoke.sh     # 44 end-to-end checks
```

`deploy.sh` writes each Terraform plan to a file, shows it, and applies that
exact plan only after you type `y`, or when `AUTO_APPROVE=true` is set (for CI). A plan
with no changes is skipped. Run without a terminal, it stops at the first plan with changes
and keeps it as `tfplan` in that stack's folder: review it with `terraform show tfplan`,
apply it with `terraform apply tfplan`, and rerun `deploy.sh` to continue. The
service URL ends up in `litellm-terraform-stack/resources.txt`.

The master key is stored in Secrets Manager, in the secret whose name starts with
`LiteLLMMasterSalt-` (`LITELLM_MASTER_KEY`). Admin UI: `https://<service-url>/ui/`.
Log in with user `admin` and the master key as the password.

## Redeploy in another account or region

Everything the deployment needs is in this repo except two values in `.env`: the state
bucket name and the alarm email. Terraform state lives in that bucket in the target account,
so a new account starts from empty state.

1. **Target account.**
   - Create an admin CLI profile, with the region set to the stack region. `deploy.sh` takes
     the region from the profile.
   - Turn on Bedrock model access for the models in `config/default-config-<region>.yaml`.
     Anthropic models also need the one-off use-case form.
   - Request quota increases early.
2. **Region.** `config/default-config-<region>.yaml` must exist; there are files for 17
   regions. EU regions use `eu.*` cross-region inference profiles, US regions `us.*`, and so
   on. Check that the list matches what the account has access to.
3. **Domain.** Create or delegate a public Route 53 hosted zone in the target account. The
   stack issues and DNS-validates both certificates in it.
4. **Profile.** Copy the closest profile, e.g. `cp envs/production.env envs/<name>.env`. Set
   `STACK_ENV`, `HOSTED_ZONE_NAME`, `RECORD_NAME` and the sizing. Then build `.env`:
   ```bash
   cat .env.template envs/<name>.env > .env
   # add TERRAFORM_S3_BUCKET_NAME (globally unique; created if missing)
   # add ALARM_EMAIL (kept out of git: this repo is public)
   rm -f config/config.yaml        # regenerated for the new region
   ```
5. **Deploy and test.**
   ```bash
   AWS_PROFILE=<profile> ./deploy.sh
   AWS_PROFILE=<profile> ./validation/smoke.sh
   ```
   Click the *AWS Notification – Subscription Confirmation* email, or test X2 fails. On a
   new account X1 can also fail until Cost Explorer has data (up to 24 h after first use).
6. **Hand over.**
   - The service URL is in `litellm-terraform-stack/resources.txt`.
   - The master key is in the Secrets Manager secret `LiteLLMMasterSalt-*`, field
     `LITELLM_MASTER_KEY`.
   - Admin UI: `https://<service-url>/ui/`, user `admin`, the master key as the password.
     API reference: hidden by default (`DISABLE_SWAGGER_PAGE`); see LiteLLM's hosted docs.

When reusing a checkout, `terraform plan` can fail with *cached package … does not match
the checksums in the lock file*. Run `terraform init -backend-config=backend.hcl` in both
stack folders. Delete `backend.hcl` and the stacks' `.terraform/` folders before pointing a
checkout at another account.

## Deploy production on your own domain

1. Create, or delegate, a public Route53 hosted zone in the production account, e.g.
   `genai.example.com`.
2. Certificates: leave `CERTIFICATE_ARN` and `CLOUDFRONT_CERTIFICATE_ARN` empty and the
   stack requests both for `<record>.<zone>` and validates them through the zone. To
   bring your own instead, set both: one in **us-east-1** for CloudFront and one in the
   **stack region** for the ALB, covering the same name.
3. Request Bedrock quota increases early; new accounts start low, and increases take days.
4. Build `.env` and fill in the blanks:
   ```bash
   cat .env.template envs/production.env > .env
   # HOSTED_ZONE_NAME, RECORD_NAME, TERRAFORM_S3_BUCKET_NAME
   AWS_PROFILE=<prod-profile> ./deploy.sh
   AWS_PROFILE=<prod-profile> ./validation/smoke.sh
   ```

With a custom domain the CloudFront → ALB hop is HTTPS. CloudFront reaches the internal
ALB through the VPC origin and forwards the `Host` header, so TLS is negotiated for
`<record>.<zone>` against the ALB's regional certificate. The ALB needs no DNS record of
its own.

`STACK_ENV` prefixes the Terraform state keys (`<env>/terraform-unified.tfstate`),
so the environments never share state even if they share a bucket.

## Settings that matter

| Variable | Default | Effect |
|---|---|---|
| `CLOUDFRONT_VPC_ORIGIN` | `true` | Internal ALB behind a CloudFront VPC origin. `false` restores the upstream design: public ALB, plain HTTP from CloudFront over the internet, guarded only by a secret header |
| `USE_ROUTE53`, `HOSTED_ZONE_NAME`, `RECORD_NAME` | sandbox: `llm` in `sandbox.myops-lab.cloud` | Custom domain; also switches the CloudFront → ALB hop to HTTPS |
| `CLOUDFRONT_WAF`, `CLOUDFRONT_WAF_RATE_LIMIT` | `true`, `2000` | Edge web ACL and its per-IP limit (requests per 5 minutes). Behind a VPC origin it replaces the regional ACL on the ALB |
| `NAT_GATEWAY_PER_AZ` | `false` (production `true`) | One NAT gateway per AZ, about $35/month more per extra NAT plus data |
| `LITELLM_VERSION`, `LITELLM_IMAGE_DIGEST` | `v1.106.5`, its index digest | The build refuses an image whose tag has moved, whose cosign signature fails against `config/litellm-cosign.pub`, or whose provenance isn't `BerriAI/litellm` at the tag's commit. Change them with `scripts/litellm-bump.sh` (see *Upgrading LiteLLM*) |
| `RDS_MULTI_AZ` | `true` (sandbox `false`) | RDS standby in a second AZ |
| `REDIS_NUM_CACHE_CLUSTERS` | `2` (sandbox `1`) | >1 turns on Multi-AZ and automatic failover |
| `INCLUDE_BASE_MODELS` | `true` (profiles `false`) | `false` loads only the region's Bedrock models, not the ~90 third-party entries in `default-config-base.yaml` |
| `ECS_VCPUS`, `DESIRED/MIN/MAX_CAPACITY` | 2 / 2 / 2 / 4 | Task size and autoscaling range |
| `ECS_CPU_TARGET_UTILIZATION_PERCENTAGE` | `50` | Autoscaling target on average CPU |
| `HEALTH_ALARMS`, `HEALTH_ALARM_NOTIFICATIONS`, `ALB_5XX_ALARM_COUNT`, `RDS_CONNECTIONS_ALARM` | `true`, `false`, `10`, `60` (production `300`) | Health alarms: ALB 5xx, no healthy or some unhealthy targets, RDS CPU, free storage and connections, Valkey memory. They only change state in CloudWatch unless `HEALTH_ALARM_NOTIFICATIONS=true`, which emails them (and their return to OK) to `ALARM_EMAIL` |
| `ECS_MEMORY_TARGET_UTILIZATION_PERCENTAGE` | `0` (off) | Optional second target on memory. LiteLLM idles at about 45% of a 2 GB task and its memory doesn't follow load, while target tracking assumes it does, so any memory target keeps an extra task running. Leave it off unless memory pressure is the real limit |
| `DISABLE_SWAGGER_PAGE` | `true` | Hides the unauthenticated API docs: Swagger UI at `/`, `/redoc` and `/openapi.json`. The Admin UI's API reference view needs `/openapi.json` and stops working; the rest of the UI doesn't use it |
| `STACK_ENV` | empty | State key prefix; empty keeps the upstream state keys |
| `AUTO_APPROVE` | `false` | Apply plans without the prompt |

## APIs

| Path | Served by | Notes |
|---|---|---|
| `/v1/chat/completions`, `/chat/completions` | middleware → LiteLLM | OpenAI-compatible; optional server-side chat history (`enable_history`, `session_id`) |
| `/v1/*` (models, embeddings, …), `/key/*`, `/ui/` | LiteLLM | `/key/generate` passes through the middleware's admin check |
| `/bedrock/model/{model}/converse`, `/converse-stream`, `/invoke` | LiteLLM (native Bedrock pass-through) | For boto3/Bedrock-SDK clients: set `endpoint_url` to `https://<service-url>/bedrock` and send a LiteLLM key as `Authorization: Bearer`. `{model}` is a `model_name` from `config/config.yaml`. Spend is tracked on the key |

The upstream sample implemented the Bedrock paths in the middleware (a Converse-to-OpenAI
translation layer with chat history and Bedrock Prompt Management ARNs). This fork removed it
(decision D1b) in favour of LiteLLM's native pass-through, so Bedrock-native calls have no
server-side chat history and do not accept prompt ARNs. The OpenAI path still has both.

## Access and identity

- **Machines and engineers** use LiteLLM virtual keys (`sk-…`). Only admins
  (the master key, or users with the `proxy_admin` role) can create keys through
  `/key/generate`; the middleware enforces this and returns 403 for anyone else.
- **Admin UI SSO** (Google Workspace, Entra ID, Okta, generic OIDC) is built into
  LiteLLM. To enable it, add `GOOGLE_CLIENT_ID` / `GOOGLE_CLIENT_SECRET` (or the
  `GENERIC_*` equivalents) and `PROXY_BASE_URL` to the LiteLLM container in
  `modules/ecs/ecs.tf`, put the secret in Secrets Manager, and register
  `https://<service-url>/sso/callback` as the OAuth redirect URI. Check LiteLLM's
  current licence terms: SSO beyond a small number of users has required an
  Enterprise licence.
- The middleware's `/user/new` self-service path verifies **Okta** JWTs only. To use
  Google or another IdP for it, the verification needs replacing with a generic
  OIDC/JWKS check. That isn't done yet.

## Upgrading LiteLLM

LiteLLM ships patch releases on several minor lines at once (for example 1.103.x to 1.106.x) and
backports fixes to each. The image is pinned by version and digest, so nothing changes until you
move the pin:

```bash
scripts/litellm-bump.sh             # newest patch on the current line, e.g. v1.106.2 -> v1.106.4
scripts/litellm-bump.sh --latest    # newest stable release on any line
scripts/litellm-bump.sh v1.105.5    # a specific release
```

It lists the release notes to read, then runs `scripts/litellm-verify-image.sh`, which checks
three things:
- The tag resolves to the digest.
- The image is signed with `config/litellm-cosign.pub`.
- Every platform's build provenance names `https://github.com/BerriAI/litellm` at the commit the
  release tag points to.

Only when all three pass does it write the new `LITELLM_VERSION` and `LITELLM_IMAGE_DIGEST` into
`.env.template` and `.env`. Then deploy, run `validation/smoke.sh` (I7 checks the running version)
and open a PR.

The signature alone isn't enough. On 2026-10-21 a malicious v1.107.0 was published through
LiteLLM's own release workflow with stolen maintainer tokens
([BerriAI/litellm#47826](https://github.com/BerriAI/litellm/issues/47826)). It carried a valid
signature but was built from the lookalike repo `Berri-AI/litellm`, which the provenance check
rejects. The digest pin kept this deployment on v1.106.2 throughout.

LiteLLM rotated its signing key on 2026-10-23 (commit `e82a3c6`, PR #48103). `config/litellm-cosign.pub`
holds the new key, fetched from that commit and checked against the SHA-256 in the v1.106.3 release
notes (`e3fe3e08c44b16407fe0b37c43b4f8b603b3a0f4ee74c29e647bc022d762c2c0`). Releases before v1.103.8,
v1.104.6, v1.105.4 and v1.106.3 were signed with the old key and no longer verify.

## Tear down

```bash
AWS_PROFILE=sandbox ./undeploy.sh
```

## Known limits and before-production items

- The sandbox keeps **one NAT gateway** (single-AZ egress) to save cost; production
  sets `NAT_GATEWAY_PER_AZ=true`.
- Without a custom domain (plain `*.cloudfront.net`) the CloudFront → ALB hop stays
  HTTP inside the AWS network, because there is no name to issue the ALB a certificate for.
- Adding a custom domain to an existing deployment switches the CloudFront VPC origin
  from HTTP to HTTPS. CloudFront won't update or delete an origin while a distribution
  uses it, and Terraform tries to delete the old origin before the distribution moves
  off it. On a fresh deploy none of this applies. For a switch on a live stack:
  1. Apply. The new `https-only` origin is created, then the apply fails deleting the old one.
  2. `terraform state rm 'module.ecs_cluster.aws_cloudfront_vpc_origin.alb["http-only"]'`
  3. Plan and apply again. This moves the distribution to the new origin.
  4. Delete the old origin (`<name>-alb`) in the CloudFront console, or with `aws cloudfront delete-vpc-origin`.

  Expect errors from the first apply until the distribution update completes; in the sandbox that took about 13 minutes.
- LiteLLM's Redis response cache is shared by all keys. An identical request (same model,
  messages and parameters) is answered from cache at no cost for `LITELLM_CACHE_TTL_SECONDS`
  (1 h). A client opts out per request with `"cache": {"no-cache": true}` (decision D6).
- Revoking or changing a key takes effect on the other tasks within
  `general_settings.user_api_key_cache_ttl` (10 s here; the upstream default is 60 s), because
  LiteLLM evicts the cached key only on the task that handled the change.
- Spend alarms (`ALARM_EMAIL`): an AWS Budgets budget on Bedrock cost, which excludes credits and
  lags by hours, and a CloudWatch alarm on Bedrock tokens per hour, sent by email through SNS.
  Both count all Bedrock use in the account and region, not only the gateway's. The SNS
  subscription needs its confirmation email clicked once.
- **Capacity (measured 2026-10-28, `scripts/load-test.py`).** One 1-vCPU task serves about
  27 requests a second before requests queue (p95 latency rose to ~4.5 s). LiteLLM's own work
  was measured with `mock_response`, so real model calls add their own time but not much CPU.
  A second task doubled throughput to ~53 requests a second. Scale-out took 275 s from the start
  of the load (3 minutes for the alarm, then the task start), and scale-in took ~17 minutes
  after it. Size `MAX_CAPACITY` and the minimum for peaks you can't absorb for five minutes.
- **A single task means a crash is an outage.** In the sandbox (1 task) a stopped task left the
  gateway down for ~90 s until ECS replaced it, which is shorter than the 3 minutes the
  no-healthy-targets alarm waits, so it is not alerted. Production runs at least 2 tasks.
- **Rate limits count per calendar minute**, not over a rolling 60 s, so a key can send up to
  twice its `rpm_limit` across a minute boundary.
- **Admin UI sign-in uses the master key.** LiteLLM warns that this is a shared static secret
  ("environment-credential login"). Before anyone else has admin access: create named admin
  users (or SSO), then set `general_settings.disable_env_credential_login: true`.
- **Keys created in the Admin UI as "AI APIs" keys** can call model routes only, not
  `/key/info`, so an engineer can't look up their own spend with that key; the admin sees it in
  the UI.
- Decisions taken on this fork and why: [`decisions.md`](decisions.md).
- See [`poc-success-criteria.md`](poc-success-criteria.md) for the PoC exit
  criteria and the items that block a customer pilot.
