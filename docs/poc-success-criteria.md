# Sandbox PoC: success and exit criteria

> **Status: proposal.** Drafted from the design review; MyOps to confirm the
> audience, numbers and dates before the PoC clock starts.

## Who it is for

MyOps engineers, initially. They reach Bedrock models through one OpenAI- and
Anthropic-compatible endpoint, using SDKs, Claude Code, Cursor and similar tools,
with a virtual key each. Customer hand-over is out of scope for the PoC. If it
succeeds, it is the next decision.

## The PoC succeeds if, within 30 days of the first deploy

| # | Criterion | Measured by |
|---|-----------|-------------|
| 1 | Every check in `validation/smoke.sh` passes after each deploy | Script exit code and `validation/results/*.json` |
| 2 | At least 5 engineers use their own virtual key on at least 10 working days | LiteLLM spend logs per key |
| 3 | Per-key and per-team spend and budgets are visible and enforced | Admin UI; K4/K5 tests |
| 4 | The gateway adds less than 300 ms p95 latency over calling Bedrock directly, for non-streaming requests | `scripts/benchmark.py`, run against both |
| 5 | Infrastructure cost stays under $100/month, excluding Bedrock tokens | Cost Explorer filtered by tag `project=llmgateway` |
| 6 | No secrets in logs and no unauthenticated access paths | S1, E1, A1/A2 tests; review of the CloudFront → ALB path |

## Exit criteria: when to stop using LiteLLM

Revisit the choice of gateway at day 30. Move to Bedrock-native access (Bedrock API
keys or IAM, application inference profiles for cost allocation, Bedrock
invocation logging) if any of these hold:

- Nobody uses per-key budgets, rate limits or team spend reporting. These are
  the main thing LiteLLM adds over Bedrock-native access while the model list
  is Bedrock-only.
- No non-Bedrock provider is planned within the next quarter.
- Keeping up with upstream changes (LiteLLM releases, rebasing this fork on the
  AWS sample) costs more than about 1 day a month.

## Before anyone outside MyOps gets a key

These block a customer pilot, not the internal PoC:

- ~~Only admins can create keys through `/key/generate`.~~ Done: middleware gate, test K7.
- ~~CloudFront reaches the ALB over a private path, not plain HTTP on the internet.~~
  Done: VPC origin with an internal ALB (`CLOUDFRONT_VPC_ORIGIN=true`), test E1.
  HTTPS on that hop (ALB certificate that matches the origin name) is still to validate.
- The deployment runs in its own account, on its own domain, with ACM
  certificates in the stack region (ALB) and in us-east-1 (CloudFront).
- Chat-history retention, data-processing terms and Bedrock invocation logging
  are agreed.
