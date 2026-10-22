# Deploying the gateway (MyOps fork)

This fork of the AWS sample deploys a small, cheap sandbox by default. The same
code scales out to a production setup on your own domain by switching to a
different environment profile. Diagrams are in [`docs/diagrams/`](diagrams/README.md).

## What gets deployed

| Layer | Sandbox (`envs/sandbox.env`) | Production (`envs/production.env`) |
|---|---|---|
| Entry | CloudFront `*.cloudfront.net` | CloudFront on `RECORD_NAME.HOSTED_ZONE_NAME` (Route53 alias), ACM certificate in us-east-1 |
| CloudFront → ALB | VPC origin to an **internal** ALB; traffic stays on the AWS network | same |
| ALB | private subnets, SG admits only the CloudFront origin-facing prefix list, regional WAF, TLS 1.3 policy | same, plus the regional ACM certificate on :443 |
| Compute | ECS Fargate ARM64, 1 task × 1 vCPU / 2 GB (autoscale 1–2) | 2–6 tasks × 2 vCPU / 4 GB |
| App | LiteLLM v1.106.2 (:4000) and middleware (:3000), both in one task | same |
| Database | RDS PostgreSQL 18, `db.t4g.micro`, single-AZ | `db.t4g.medium`, Multi-AZ, 50 GB |
| Cache | ElastiCache Valkey 9.1, 1 × `cache.t4g.micro` | 2 × `cache.t4g.small`, Multi-AZ with automatic failover |
| Network | new VPC, 2 public + 2 private subnets, 1 NAT gateway, S3 gateway endpoint | same (one NAT: a single-AZ egress point; see below) |
| Models | Bedrock only (EU cross-region inference profiles), `INCLUDE_BASE_MODELS=false` | same; add providers by setting their API keys |
| Estimated cost | ~$75–85/month before Bedrock tokens | dominated by Multi-AZ RDS, task count and NAT data |

## Prerequisites

- An AWS account and a CLI profile with admin rights in it. Use a separate
  account per environment; stack names are fixed, so there can only be one
  deployment per account and region.
- Bedrock model access for the models in `config/default-config-<region>.yaml`.
- Docker with BuildKit, `terraform` ≥ 1.6, `yq` v4, `jq`, AWS CLI v2. The images
  are built for the `CPU_ARCHITECTURE` set in the profile (`arm` = Graviton).
- An optional `uv` for the Python tests and tools (see README → *Python tooling*).

## Deploy the sandbox

```bash
cat .env.template envs/sandbox.env > .env     # later lines win
# set TERRAFORM_S3_BUCKET_NAME in .env (globally unique; created if missing)
rm -f config/config.yaml                      # regenerate from the model lists
AWS_PROFILE=sandbox ./deploy.sh               # plans each stack, asks before applying
AWS_PROFILE=sandbox ./validation/smoke.sh     # 30 end-to-end checks
```

`deploy.sh` writes each Terraform plan to a file, shows it, and applies that
exact plan only after you type `y`, or when `AUTO_APPROVE=true` is set (for CI). The
service URL ends up in `litellm-terraform-stack/resources.txt`.

The master key is stored in Secrets Manager, in the secret whose name starts with
`LiteLLMMasterSalt-` (`LITELLM_MASTER_KEY`). Admin UI: `https://<service-url>/ui/`.
Log in with user `admin` and the master key as the password.

## Deploy production on your own domain

1. Create, or delegate, a public Route53 hosted zone in the production account, e.g.
   `genai.example.com`.
2. Request two ACM certificates for `<record>.<zone>` (e.g. `api.genai.example.com`),
   both DNS-validated in that zone:
   - in **us-east-1**, for CloudFront → `CLOUDFRONT_CERTIFICATE_ARN`
   - in the **stack region**, for the ALB → `CERTIFICATE_ARN`
3. Request Bedrock quota increases early; new accounts start low, and increases take days.
4. Build `.env` and fill in the blanks:
   ```bash
   cat .env.template envs/production.env > .env
   # HOSTED_ZONE_NAME, RECORD_NAME, CERTIFICATE_ARN, CLOUDFRONT_CERTIFICATE_ARN,
   # TERRAFORM_S3_BUCKET_NAME
   AWS_PROFILE=<prod-profile> ./deploy.sh
   AWS_PROFILE=<prod-profile> ./validation/smoke.sh
   ```

`STACK_ENV` prefixes the Terraform state keys (`<env>/terraform-unified.tfstate`),
so the environments never share state even if they share a bucket.

## Settings that matter

| Variable | Default | Effect |
|---|---|---|
| `CLOUDFRONT_VPC_ORIGIN` | `true` | Internal ALB behind a CloudFront VPC origin. `false` restores the upstream design: public ALB, plain HTTP from CloudFront over the internet, guarded only by a secret header |
| `RDS_MULTI_AZ` | `true` (sandbox `false`) | RDS standby in a second AZ |
| `REDIS_NUM_CACHE_CLUSTERS` | `2` (sandbox `1`) | >1 turns on Multi-AZ and automatic failover |
| `INCLUDE_BASE_MODELS` | `true` (profiles `false`) | `false` loads only the region's Bedrock models, not the ~90 third-party entries in `default-config-base.yaml` |
| `ECS_VCPUS`, `DESIRED/MIN/MAX_CAPACITY` | 2 / 2 / 2 / 4 | Task size and autoscaling range |
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

## Tear down

```bash
AWS_PROFILE=sandbox ./undeploy.sh
```

## Known limits and before-production items

- The module creates **one NAT gateway**, so Bedrock and other AWS API egress
  depend on one AZ.
- The CloudFront → ALB hop over the VPC origin is HTTP inside the AWS network.
  End-to-end TLS needs an ALB certificate that matches the origin name. That is
  not validated yet.
- The regional WAF protects the ALB. CloudFront itself has no web ACL; that would
  need a `CLOUDFRONT`-scope ACL in us-east-1.
- See [`poc-success-criteria.md`](poc-success-criteria.md) for the PoC exit
  criteria and the items that block a customer pilot.
