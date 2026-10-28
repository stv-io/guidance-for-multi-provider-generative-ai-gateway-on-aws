#!/bin/bash
# End-to-end validation of a deployed gateway. Test definitions: validation/README.md
# Usage: AWS_PROFILE=<profile> ./validation/smoke.sh   (env: ALL_MODELS=1, SKIP_PLAN=1)
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2
REPO_ROOT=$(pwd)
MAIN_TF="$REPO_ROOT/litellm-terraform-stack"
LOG_TF="$REPO_ROOT/litellm-s3-log-bucket-terraform"
RESULTS_DIR="$REPO_ROOT/validation/results"
mkdir -p "$RESULTS_DIR"
RESULTS_FILE="$RESULTS_DIR/$(date -u +%Y%m%dT%H%M%SZ).json"
TMP=$(mktemp -d)
trap cleanup EXIT

for bin in aws terraform curl jq yq dig; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin"; exit 2; }
done

set -a; source .env; set +a
MAIN_STACK_NAME="litellm-stack"
DEFAULT_MODEL="${DEFAULT_MODEL:-eu.anthropic.claude-haiku-4-5-20251001-v1:0}"
OTHER_MODEL="${OTHER_MODEL:-eu.amazon.nova-micro-v1:0}"
EMBED_MODEL="${EMBED_MODEL:-amazon.titan-embed-text-v2:0}"

PASSED=0; FAILED=0; SKIPPED=0
echo "[]" > "$RESULTS_FILE"
record() { jq --arg id "$1" --arg s "$2" --arg m "$3" '. += [{id:$id,status:$s,detail:$m}]' "$RESULTS_FILE" > "$TMP/r" && mv "$TMP/r" "$RESULTS_FILE"; }
pass() { PASSED=$((PASSED+1)); printf '  \033[32mPASS\033[0m %-3s %s\n' "$CURRENT" "$1"; record "$CURRENT" pass "$1"; }
fail() { FAILED=$((FAILED+1)); printf '  \033[31mFAIL\033[0m %-3s %s\n' "$CURRENT" "$1"; record "$CURRENT" fail "$1"; }
skip() { SKIPPED=$((SKIPPED+1)); printf '  \033[33mSKIP\033[0m %-3s %s\n' "$CURRENT" "$1"; record "$CURRENT" skip "$1"; }

# req METHOD URL KEY [JSON] -> sets CODE, response body in $TMP/body
req() {
  local auth=()
  [ -n "$3" ] && auth=(-H "Authorization: Bearer $3")
  CODE=$(curl -sS -o "$TMP/body" -w '%{http_code}' -X "$1" "$2" ${auth[@]+"${auth[@]}"} \
    -H 'Content-Type: application/json' ${4:+--data "$4"} --max-time 90) || CODE=000
}
body() { cat "$TMP/body"; }
chat_json() { jq -nc --arg m "$1" --arg p "${2:-Reply with the single word: pong}" '{model:$m,max_tokens:20,messages:[{role:"user",content:$p}]}'; }

TEMP_KEYS=()
TEMP_TEAMS=()
cleanup() {
  for k in "${TEMP_KEYS[@]:-}"; do
    [ -n "$k" ] && curl -sS -o /dev/null -X POST "$BASE/key/delete" -H "Authorization: Bearer $MASTER_KEY" \
      -H 'Content-Type: application/json' --data "$(jq -nc --arg k "$k" '{keys:[$k]}')" --max-time 30 || true
  done
  for t in "${TEMP_TEAMS[@]:-}"; do
    [ -n "$t" ] && curl -sS -o /dev/null -X POST "$BASE/team/delete" -H "Authorization: Bearer $MASTER_KEY" \
      -H 'Content-Type: application/json' --data "$(jq -nc --arg t "$t" '{team_ids:[$t]}')" --max-time 30 || true
  done
  rm -rf "$TMP"
}

gen_key() { # gen_key JSON -> sets GEN_KEY (not via $(...), so TEMP_KEYS survives for cleanup)
  req POST "$BASE/key/generate" "$MASTER_KEY" "$1"
  local k; k=$(body | jq -r '.key // empty' 2>/dev/null)
  [ -n "$k" ] && TEMP_KEYS+=("$k")
  GEN_KEY=$k
}

gen_team() { # gen_team JSON -> sets GEN_TEAM (team_id)
  req POST "$BASE/team/new" "$MASTER_KEY" "$1"
  local t; t=$(body | jq -r '.team_id // empty' 2>/dev/null)
  [ -n "$t" ] && TEMP_TEAMS+=("$t")
  GEN_TEAM=$t
}

# Unique prompt: the response cache answers repeated prompts for free, which would hide spend
fresh_prompt() { echo "Reply with one word. Request $(date +%s)-$RANDOM"; }

echo "== Discovering deployment"
tfout() { terraform -chdir="$MAIN_TF" output -raw "$1" 2>/dev/null; }
BASE=$(tfout ServiceURL); ALB=$(tfout alb_dns_name); VPC_ID=$(tfout vpc_id)
CLUSTER=$(tfout LitellmEcsCluster); SERVICE=$(tfout LitellmEcsTask)
CF_DOMAIN=$(tfout cloudfront_domain_name); CF_ID=$(tfout cloudfront_distribution_id)
FQDN=""; [ "${USE_ROUTE53:-false}" = true ] && [ -n "${RECORD_NAME:-}" ] && FQDN="$RECORD_NAME.$HOSTED_ZONE_NAME"
[ -n "$BASE" ] || { echo "could not read terraform outputs (run deploy.sh first)"; exit 2; }
SECRET_ARN=$(aws secretsmanager list-secrets --filters Key=name,Values=LiteLLMMasterSalt- --query 'SecretList[0].ARN' --output text)
MASTER_KEY=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --query SecretString --output text | jq -r .LITELLM_MASTER_KEY)
[ -n "$MASTER_KEY" ] || { echo "could not read the master key"; exit 2; }
echo "  endpoint: $BASE"
echo "  alb:      $ALB"

# ---------------------------------------------------------------- Infra
echo "== Infra"
CURRENT=I1
if [ "${SKIP_PLAN:-0}" = 1 ]; then skip "SKIP_PLAN=1"; else
  drift=""
  for stack in log main; do
    d=$([ $stack = log ] && echo "$LOG_TF" || echo "$MAIN_TF")
    out="$RESULTS_DIR/plan-$stack.txt"
    terraform -chdir="$d" init -backend-config=backend.hcl -input=false >/dev/null 2>&1
    # deploy.sh passes configuration via TF_VAR_*; re-export the same values
    ( source "$REPO_ROOT/validation/tf-vars.sh" $stack; terraform -chdir="$d" plan -detailed-exitcode -input=false -lock=false -no-color >"$out" 2>&1 )
    rc=$?; [ $rc -eq 0 ] || drift="$drift $stack(rc=$rc, ${out#$REPO_ROOT/})"
  done
  [ -z "$drift" ] && pass "no changes in either stack" || fail "plan not clean:$drift"
fi

CURRENT=I2
rds=$(aws rds describe-db-instances --db-instance-identifier "${MAIN_STACK_NAME}-litellm-db" \
  --query 'DBInstances[0].[Engine,EngineVersion,DBInstanceClass,MultiAZ,StorageEncrypted]' --output json 2>/dev/null)
want_pg=$(sed -n 's/^ *engine_version *= *"\([0-9]*\).*/\1/p' "$MAIN_TF/modules/base/rds.tf")
want_maz=$([ "${RDS_MULTI_AZ:-true}" = true ] && echo true || echo false)
if [ "$(jq -r '.[0]' <<<"$rds")" = postgres ] && [[ "$(jq -r '.[1]' <<<"$rds")" == "$want_pg".* ]] \
   && [ "$(jq -r '.[2]' <<<"$rds")" = "$RDS_INSTANCE_CLASS" ] && [ "$(jq -r '.[3]' <<<"$rds")" = "$want_maz" ] \
   && [ "$(jq -r '.[4]' <<<"$rds")" = true ]; then pass "$(jq -rc . <<<"$rds")"; else fail "got $(jq -rc . <<<"$rds" 2>/dev/null || echo none), want postgres $want_pg.x $RDS_INSTANCE_CLASS multiAZ=$want_maz encrypted"; fi

CURRENT=I3
ec=$(aws elasticache describe-replication-groups --replication-group-id "${MAIN_STACK_NAME}-redis" \
  --query 'ReplicationGroups[0].[Engine,CacheNodeType,TransitEncryptionEnabled,AtRestEncryptionEnabled]' --output json 2>/dev/null)
if [ "$(jq -r '.[0]' <<<"$ec")" = valkey ] && [ "$(jq -r '.[1]' <<<"$ec")" = "$REDIS_NODE_TYPE" ] \
   && [ "$(jq -r '.[2]' <<<"$ec")" = true ] && [ "$(jq -r '.[3]' <<<"$ec")" = true ]; then pass "$(jq -rc . <<<"$ec")"; else fail "got $(jq -rc . <<<"$ec" 2>/dev/null || echo none)"; fi

CURRENT=I4
svc=$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query 'services[0].[runningCount,desiredCount]' --output json 2>/dev/null)
task=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --desired-status RUNNING --query 'taskArns[0]' --output text 2>/dev/null)
tinfo=$(aws ecs describe-tasks --cluster "$CLUSTER" --tasks "$task" --query 'tasks[0]' --output json 2>/dev/null)
tdef_arch=$(aws ecs describe-task-definition --task-definition "$(jq -r .taskDefinitionArn <<<"$tinfo")" --query 'taskDefinition.runtimePlatform.cpuArchitecture' --output text 2>/dev/null)
unhealthy=$(jq -r '[.containers[] | select(.healthStatus != "HEALTHY") | .name] | join(",")' <<<"$tinfo" 2>/dev/null)
if [ "$(jq -r '.[0]' <<<"$svc")" = "$(jq -r '.[1]' <<<"$svc")" ] && [ "$(jq -r '.[0]' <<<"$svc")" -ge 1 ] 2>/dev/null \
   && [ "$tdef_arch" = ARM64 ] && [ -z "$unhealthy" ]; then pass "running/desired=$(jq -rc . <<<"$svc") arch=$tdef_arch all containers HEALTHY"
else fail "running/desired=$(jq -rc . <<<"$svc" 2>/dev/null) arch=$tdef_arch unhealthy=[$unhealthy]"; fi

CURRENT=I5
eps=$(aws ec2 describe-vpc-endpoints --filters Name=vpc-id,Values="$VPC_ID" --query 'VpcEndpoints[].[VpcEndpointType,ServiceName]' --output json)
n_if=$(jq '[.[] | select(.[0]=="Interface")] | length' <<<"$eps"); n_s3=$(jq '[.[] | select(.[0]=="Gateway" and (.[1]|endswith(".s3")))] | length' <<<"$eps")
if [ "${DISABLE_OUTBOUND_NETWORK_ACCESS}" = true ]; then skip "outbound disabled: interface endpoints expected"
elif [ "$n_if" -eq 0 ] && [ "$n_s3" -eq 1 ]; then pass "0 interface endpoints, S3 gateway present"
else fail "interface=$n_if s3_gateway=$n_s3"; fi

CURRENT=I6
nats=$(aws ec2 describe-nat-gateways --filter Name=vpc-id,Values="$VPC_ID" Name=state,Values=available \
  --query 'NatGateways[].SubnetId' --output json 2>/dev/null)
n_nat=$(jq length <<<"$nats")
nat_azs=$(aws ec2 describe-subnets --subnet-ids $(jq -r '.[]' <<<"$nats") --query 'Subnets[].AvailabilityZone' --output text 2>/dev/null | tr '\t' '\n' | sort -u | wc -l | tr -d ' ')
want_nat=$([ "${NAT_GATEWAY_PER_AZ:-false}" = true ] && echo 2 || echo 1)
if [ "${DISABLE_OUTBOUND_NETWORK_ACCESS}" = true ]; then skip "outbound disabled: no NAT expected"
elif [ "$n_nat" = "$want_nat" ] && [ "$nat_azs" = "$want_nat" ]; then pass "$n_nat NAT gateway(s) in $nat_azs AZ(s) (NAT_GATEWAY_PER_AZ=${NAT_GATEWAY_PER_AZ:-false})"
else fail "NAT gateways=$n_nat in $nat_azs AZs, want $want_nat"; fi

CURRENT=I7
# The authenticated readiness details report the running version (the public /health/readiness doesn't)
req GET "$BASE/health/readiness/details" "$MASTER_KEY"
running=$(body | jq -r '.litellm_version // empty' 2>/dev/null)
if [ "$CODE" = 200 ] && [ "v$running" = "$LITELLM_VERSION" ]; then pass "LiteLLM $running (pinned ${LITELLM_IMAGE_DIGEST:0:19}…)"
else fail "$CODE running=v$running want $LITELLM_VERSION"; fi

# ---------------------------------------------------------------- Edge
echo "== Edge"
CURRENT=E1
scheme=$(aws elbv2 describe-load-balancers --names "${MAIN_STACK_NAME}-alb" --query 'LoadBalancers[0].Scheme' --output text 2>/dev/null)
if [ "$scheme" = internal ]; then
  # VPC origin: the ALB has no public address; its name must not resolve to anything reachable from here
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://$ALB/v1/models" --max-time 10) || CODE=000
  [ "$CODE" = 000 ] && pass "ALB is internal and unreachable from the internet" || fail "internal ALB answered from outside: $CODE"
elif [ -n "$CF_DOMAIN" ]; then
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://$ALB/v1/models" --max-time 20)
  [ "$CODE" = 403 ] && pass "public ALB without CloudFront header -> 403" || fail "direct ALB request -> $CODE (want 403)"
else skip "CloudFront not in use and ALB is public"; fi

CURRENT=E2
if [ -n "$CF_DOMAIN" ]; then
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://${BASE#https://}/health/liveliness" --max-time 20)
  [[ "$CODE" =~ ^30[1278]$ ]] && pass "http -> $CODE redirect" || fail "http -> $CODE"
else skip "CloudFront not in use"; fi

CURRENT=E3; req GET "$BASE/health/liveliness" ""
[ "$CODE" = 200 ] && pass "/health/liveliness 200" || fail "/health/liveliness $CODE $(body | head -c 200)"

CURRENT=E4; req GET "$BASE/bedrock/health/liveliness" ""
[ "$CODE" = 200 ] && [ "$(body | jq -r .litellm 2>/dev/null)" = connected ] && pass "middleware healthy, litellm connected" || fail "$CODE $(body | head -c 200)"

CURRENT=E5; CODE=$(curl -sL -o "$TMP/body" -w '%{http_code}' "$BASE/ui/" --max-time 30)
[ "$CODE" = 200 ] && grep -qi '<html' "$TMP/body" && pass "/ui/ 200 html" || fail "/ui/ $CODE"

CURRENT=E6
if [ -n "$FQDN" ] && [ "$scheme" = internal ]; then
  vo_id=$(aws cloudfront get-distribution-config --id "$CF_ID" --query 'DistributionConfig.Origins.Items[0].VpcOriginConfig.VpcOriginId' --output text 2>/dev/null)
  policy=$(aws cloudfront get-vpc-origin --id "$vo_id" --query 'VpcOrigin.VpcOriginEndpointConfig.OriginProtocolPolicy' --output text 2>/dev/null)
  [ "$policy" = https-only ] && pass "CloudFront -> ALB over HTTPS (VPC origin $policy)" || fail "VPC origin protocol policy: $policy"
else skip "no custom domain: the CloudFront -> ALB hop is HTTP inside the AWS network"; fi

CURRENT=E7
if [ -n "$FQDN" ]; then
  a=$(dig +short A "$FQDN" | head -1); aaaa=$(dig +short AAAA "$FQDN" | head -1)
  # no -k: the certificate must verify for the custom name
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "https://$FQDN/health/liveliness" --max-time 20) || CODE=000
  [ "$BASE" = "https://$FQDN" ] && [ -n "$a" ] && [ -n "$aaaa" ] && [ "$CODE" = 200 ] \
    && pass "$FQDN: A+AAAA, valid certificate, 200" || fail "base=$BASE A=${a:-none} AAAA=${aaaa:-none} https=$CODE"
else skip "no custom domain"; fi

CURRENT=E8
if [ -n "$CF_ID" ]; then
  acl=$(aws cloudfront get-distribution-config --id "$CF_ID" --query 'DistributionConfig.WebACLId' --output text 2>/dev/null)
  # Log4Shell-style header: blocked at the edge by AWSManagedRulesKnownBadInputsRuleSet
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "$BASE/health/liveliness" -H 'X-Smoke: ${jndi:ldap://example.invalid/a}' --max-time 20)
  regional=$(aws wafv2 get-web-acl-for-resource --resource-arn "$(aws elbv2 describe-load-balancers --names "${MAIN_STACK_NAME}-alb" --query 'LoadBalancers[0].LoadBalancerArn' --output text)" --query 'WebACL.Name' --output text 2>/dev/null)
  if [ "${CLOUDFRONT_WAF:-true}" != true ]; then skip "CLOUDFRONT_WAF=false"
  elif [[ "$acl" == arn:aws:wafv2:us-east-1:*:global/webacl/* ]] && [ "$CODE" = 403 ]; then
    pass "edge ACL attached, malicious header -> 403 (regional ALB ACL: ${regional:-none})"
  else fail "WebACLId=${acl:-none} malicious header -> $CODE"; fi
else skip "CloudFront not in use"; fi

CURRENT=E9
docs=""; for p in /redoc /openapi.json; do
  docs+="$p=$(curl -s -o /dev/null -w '%{http_code}' "$BASE$p" --max-time 20) "
done
# With the docs off, / falls through to LiteLLM's public home route ("LiteLLM: RUNNING")
curl -s -o "$TMP/body" "$BASE/" --max-time 20 || true
grep -qi swagger "$TMP/body" && root=swagger || root=no-swagger
if [ "${DISABLE_SWAGGER_PAGE:-false}" != true ]; then skip "DISABLE_SWAGGER_PAGE=false: /=$root ${docs% }"
elif [ "$root $docs" = "no-swagger /redoc=404 /openapi.json=404 " ]; then pass "API docs hidden: /=$root ${docs% }"
else fail "API docs still served: /=$root ${docs% }"; fi

# ---------------------------------------------------------------- Auth
echo "== Auth"
CURRENT=A1; req GET "$BASE/v1/models" ""
[ "$CODE" = 401 ] && pass "no key -> 401" || fail "no key -> $CODE"

CURRENT=A2; req GET "$BASE/v1/models" "sk-invalid-$(date +%s)"
[ "$CODE" = 401 ] && pass "bogus key -> 401" || fail "bogus key -> $CODE"

CURRENT=A3; req GET "$BASE/v1/models" "$MASTER_KEY"
got=$(body | jq -r '[.data[].id] | sort | join(",")' 2>/dev/null)
want=$(yq -r '[.model_list[].model_name] | unique | sort | join(",")' config/config.yaml)
[ "$CODE" = 200 ] && [ "$got" = "$want" ] && pass "$(body | jq '.data | length') models, matches config.yaml" \
  || fail "$CODE; got [$got] want [$want]"

# ---------------------------------------------------------------- Models
echo "== Models"
CURRENT=M1; req POST "$BASE/v1/chat/completions" "$MASTER_KEY" "$(chat_json "$DEFAULT_MODEL")"
msg=$(body | jq -r '.choices[0].message.content // empty' 2>/dev/null)
[ "$CODE" = 200 ] && [ -n "$msg" ] && pass "$DEFAULT_MODEL: \"${msg:0:40}\"" || fail "$CODE $(body | head -c 300)"

CURRENT=M2
curl -sS -N -o "$TMP/stream" -X POST "$BASE/v1/chat/completions" -H "Authorization: Bearer $MASTER_KEY" \
  -H 'Content-Type: application/json' --max-time 90 --data "$(chat_json "$DEFAULT_MODEL" 'Count from 1 to 5.' | jq -c '.stream=true')"
chunks=$(grep -c '^data: {' "$TMP/stream" || true)
[ "$chunks" -ge 2 ] && grep -q '^data: \[DONE\]' "$TMP/stream" && pass "$chunks chunks + [DONE]" || fail "chunks=$chunks $(head -c 300 "$TMP/stream")"

# Claude Code and the Anthropic SDKs: ANTHROPIC_BASE_URL=<service url>, the key sent as x-api-key
CURRENT=M7
CODE=$(curl -sS -o "$TMP/body" -w '%{http_code}' -X POST "$BASE/v1/messages" -H "x-api-key: $MASTER_KEY" \
  -H 'anthropic-version: 2023-06-01' -H 'Content-Type: application/json' --max-time 90 \
  --data "$(jq -nc --arg m "$DEFAULT_MODEL" '{model:$m,max_tokens:20,messages:[{role:"user",content:"Reply with the single word: pong"}]}')") || CODE=000
text=$(body | jq -r 'select(.type == "message") | .content[0].text // empty' 2>/dev/null)
[ "$CODE" = 200 ] && [ -n "$text" ] && pass "Anthropic Messages API: \"$text\"" || fail "/v1/messages -> $CODE $(body | head -c 200)"

CURRENT=M7b
curl -sS -N -o "$TMP/stream" -X POST "$BASE/v1/messages" -H "x-api-key: $MASTER_KEY" \
  -H 'anthropic-version: 2023-06-01' -H 'Content-Type: application/json' --max-time 90 \
  --data "$(jq -nc --arg m "$DEFAULT_MODEL" '{model:$m,max_tokens:40,stream:true,messages:[{role:"user",content:"Count from 1 to 5."}]}')"
deltas=$(grep -c '^event: content_block_delta' "$TMP/stream" || true)
[ "$deltas" -ge 1 ] && grep -q '^event: message_stop' "$TMP/stream" && pass "$deltas content_block_delta events + message_stop" || fail "deltas=$deltas $(head -c 300 "$TMP/stream")"

CURRENT=M3; req POST "$BASE/v1/embeddings" "$MASTER_KEY" "$(jq -nc --arg m "$EMBED_MODEL" '{model:$m,input:"hello gateway"}')"
dim=$(body | jq '.data[0].embedding | length' 2>/dev/null)
[ "$CODE" = 200 ] && [ "$dim" = 1024 ] && pass "$EMBED_MODEL dim=$dim" || fail "$CODE dim=$dim $(body | head -c 200)"

CURRENT=M4
req POST "$BASE/bedrock/model/$DEFAULT_MODEL/converse" "$MASTER_KEY" \
  '{"messages":[{"role":"user","content":[{"text":"Reply with the single word: pong"}]}],"inferenceConfig":{"maxTokens":20}}'
txt=$(body | jq -r '.output.message.content[0].text // empty' 2>/dev/null)
[ "$CODE" = 200 ] && [ -n "$txt" ] && pass "converse: \"${txt:0:40}\"" || fail "$CODE $(body | head -c 300)"

CURRENT=M4b
# converse-stream answers in the AWS event-stream binary framing, so check for the event types
req POST "$BASE/bedrock/model/$DEFAULT_MODEL/converse-stream" "$MASTER_KEY" \
  '{"messages":[{"role":"user","content":[{"text":"Count from 1 to 5"}]}],"inferenceConfig":{"maxTokens":30}}'
if [ "$CODE" = 200 ] && LC_ALL=C grep -aq contentBlockDelta "$TMP/body" && LC_ALL=C grep -aq messageStop "$TMP/body"; then
  pass "event stream with contentBlockDelta + messageStop"
else
  fail "$CODE $(LC_ALL=C tr -cd '[:print:]' <"$TMP/body" | head -c 300)"
fi

CURRENT=M6
# Responses over ~1 KB are gzip-compressed by LiteLLM; the middleware must not relay a stale
# Content-Encoding/Content-Length for the body it has already decompressed
req POST "$BASE/v1/chat/completions" "$MASTER_KEY" \
  "$(chat_json "$DEFAULT_MODEL" 'Write about 250 words on why clouds form.' | jq -c '.max_tokens=600')"
len=$(body | jq -r '.choices[0].message.content | length' 2>/dev/null)
[ "$CODE" = 200 ] && [ "${len:-0}" -gt 1000 ] && pass "long answer relayed intact ($len chars)" || fail "$CODE len=$len"

CURRENT=M5
if [ "${ALL_MODELS:-0}" = 1 ]; then
  bad=""; n=0
  for m in $(yq -r '.model_list[] | select(.model_name | test("embed|rerank") | not) | .model_name' config/config.yaml); do
    n=$((n+1)); req POST "$BASE/v1/chat/completions" "$MASTER_KEY" "$(chat_json "$m")"
    [ "$CODE" = 200 ] || bad="$bad $m($CODE)"
  done
  [ -z "$bad" ] && pass "$n chat models answered" || fail "failing:$bad"
else skip "set ALL_MODELS=1"; fi

CURRENT=C1
# Response cache: an identical request is answered from Valkey, and entries carry the TTL
req GET "$BASE/cache/ping" "$MASTER_KEY"
ttl=$(body | jq -r '.litellm_cache_params // "" | tostring | capture("ttl.{0,4}?(?<v>[0-9]+)").v // empty' 2>/dev/null)
p="cache check $(date +%s)-$RANDOM: reply with one word"
for i in 1 2; do
  curl -sS -D "$TMP/ch$i" -o "$TMP/cb$i" -X POST "$BASE/v1/chat/completions" -H "Authorization: Bearer $MASTER_KEY" \
    -H 'Content-Type: application/json' -d "$(chat_json "$OTHER_MODEL" "$p")" --max-time 60
done
hit=$(grep -i '^x-litellm-cache-key:' "$TMP/ch2" | head -1)
same_id=$([ "$(jq -r .id "$TMP/cb1")" = "$(jq -r .id "$TMP/cb2")" ] && echo yes)
want_ttl=${LITELLM_CACHE_TTL_SECONDS:-3600}
if [ "$ttl" = "$want_ttl" ] && [ -n "$hit" ] && [ "$same_id" = yes ]; then pass "repeat served from cache, ttl=${ttl}s"
else fail "ttl=${ttl:-none} (want $want_ttl) cache_hit=${hit:+yes} same_id=${same_id:-no}"; fi

# ---------------------------------------------------------------- History
echo "== History"
CURRENT=H1
req POST "$BASE/v1/chat/completions" "$MASTER_KEY" "$(chat_json "$DEFAULT_MODEL" 'Remember the number 42.' | jq -c '.enable_history=true')"
SID=$(body | jq -r '.session_id // empty' 2>/dev/null)
if [ -n "$SID" ]; then
  req POST "$BASE/v1/chat/completions" "$MASTER_KEY" "$(chat_json "$DEFAULT_MODEL" 'What number did I ask you to remember?' | jq -c --arg s "$SID" '.session_id=$s')"
  c2=$CODE; req POST "$BASE/chat-history" "$MASTER_KEY" "$(jq -nc --arg s "$SID" '{session_id:$s}')"
  n=$(body | jq '.messages | length' 2>/dev/null)
  [ "$c2" = 200 ] && [ "${n:-0}" -ge 4 ] && pass "session $SID: $n messages stored" || fail "follow-up=$c2 history=$CODE messages=$n"
else fail "no session_id returned ($CODE $(body | head -c 200))"; fi

# ---------------------------------------------------------------- Keys
echo "== Keys"
CURRENT=K1
gen_key "$(jq -nc --arg m "$DEFAULT_MODEL" '{models:[$m],max_budget:1,key_alias:("smoke-"+(now|tostring)),metadata:{purpose:"validation/smoke.sh"}}')"; KEY=$GEN_KEY
[[ "$KEY" == sk-* ]] && pass "virtual key issued (restricted to $DEFAULT_MODEL)" || fail "$CODE $(body | head -c 200)"

CURRENT=H2
if [ -n "${SID:-}" ] && [ -n "$KEY" ]; then
  req POST "$BASE/chat-history" "$KEY" "$(jq -nc --arg s "$SID" '{session_id:$s}')"
  [ "$CODE" = 401 ] && pass "other key -> 401" || fail "other key -> $CODE"
else skip "needs H1 session and K1 key"; fi

CURRENT=K2
# A unique prompt: LiteLLM's response cache answers repeated prompts at zero cost, and K4 needs real spend
if [ -n "$KEY" ]; then req POST "$BASE/v1/chat/completions" "$KEY" "$(chat_json "$DEFAULT_MODEL" "Reply with one word. Run $(date +%s)-$RANDOM")"
  [ "$CODE" = 200 ] && pass "allowed model -> 200" || fail "allowed model -> $CODE $(body | head -c 200)"
else skip "no K1 key"; fi

CURRENT=K3
if [ -n "$KEY" ]; then req POST "$BASE/v1/chat/completions" "$KEY" "$(chat_json "$OTHER_MODEL")"
  [[ "$CODE" =~ ^40[13]$ ]] && pass "disallowed model -> $CODE" || fail "disallowed model -> $CODE"
else skip "no K1 key"; fi

CURRENT=K4
if [ -n "$KEY" ]; then
  spend=0
  for _ in $(seq 1 18); do
    req GET "$BASE/key/info?key=$KEY" "$MASTER_KEY"
    spend=$(body | jq -r '.info.spend // 0' 2>/dev/null)
    awk "BEGIN{exit !($spend > 0)}" && break; sleep 5
  done
  awk "BEGIN{exit !($spend > 0)}" && pass "spend recorded: \$$spend" || fail "spend still $spend after 90s"
else skip "no K1 key"; fi

CURRENT=T1
# LiteLLM rejects once spend > max_budget (strictly), so the first call goes through and spends; a
# later one must be refused once that spend reaches the team's counter (Redis, shared by all tasks)
gen_team '{"team_alias":"smoke-t1-tiny-budget","max_budget":0.000001}'
if [ -n "$GEN_TEAM" ]; then
  gen_key "$(jq -nc --arg t "$GEN_TEAM" --arg m "$DEFAULT_MODEL" '{team_id:$t,models:[$m]}')"
  if [ -n "$GEN_KEY" ]; then
    codes=""; t0=$(date +%s)
    for _ in $(seq 1 18); do
      req POST "$BASE/v1/chat/completions" "$GEN_KEY" "$(chat_json "$DEFAULT_MODEL" "$(fresh_prompt)")"; codes="$codes$CODE "
      [[ "$CODE" =~ ^4[0-9][0-9]$ ]] && body | grep -qi "budget has been exceeded" && break; sleep 5
    done
    [[ "$CODE" =~ ^4[0-9][0-9]$ ]] && body | grep -qi "budget has been exceeded" && pass "team over budget refused with $CODE after $(( $(date +%s) - t0 ))s (codes: $codes)" ||
      fail "team over budget still served after 90s (codes: $codes) $(body | head -c 150)"
  else fail "could not create a key in the team"; fi
else fail "could not create team: $CODE $(body | head -c 200)"; fi

CURRENT=T2
gen_team '{"team_alias":"smoke-t2-spend","max_budget":10}'
if [ -n "$GEN_TEAM" ]; then
  gen_key "$(jq -nc --arg t "$GEN_TEAM" --arg m "$DEFAULT_MODEL" '{team_id:$t,models:[$m]}')"
  req POST "$BASE/v1/chat/completions" "$GEN_KEY" "$(chat_json "$DEFAULT_MODEL" "$(fresh_prompt)")"; c=$CODE
  spend=0
  for _ in $(seq 1 18); do
    req GET "$BASE/team/info?team_id=$GEN_TEAM" "$MASTER_KEY"
    spend=$(body | jq -r '.team_info.spend // 0' 2>/dev/null)
    awk "BEGIN{exit !($spend > 0)}" && break; sleep 5
  done
  [ "$c" = 200 ] && awk "BEGIN{exit !($spend > 0)}" && pass "team key allowed under budget; team spend \$$spend" || fail "call -> $c, team spend $spend after 90s"
else fail "could not create team: $CODE $(body | head -c 200)"; fi

CURRENT=K5
gen_key "$(jq -nc --arg m "$DEFAULT_MODEL" '{models:[$m],rpm_limit:1,key_alias:("smoke-rpm-"+(now|tostring))}')"; RKEY=$GEN_KEY
if [ -n "$RKEY" ]; then
  req POST "$BASE/v1/chat/completions" "$RKEY" "$(chat_json "$DEFAULT_MODEL")"; c1=$CODE
  req POST "$BASE/v1/chat/completions" "$RKEY" "$(chat_json "$DEFAULT_MODEL")"; c2=$CODE
  [ "$c1" = 200 ] && [ "$c2" = 429 ] && pass "1st=200 2nd=429" || fail "1st=$c1 2nd=$c2"
else fail "could not create rpm-limited key"; fi

CURRENT=K7
if [ -n "$KEY" ]; then req POST "$BASE/key/generate" "$KEY" '{"models":[]}'
  [ "$CODE" = 403 ] && pass "non-admin key cannot mint keys -> 403" || fail "non-admin /key/generate -> $CODE $(body | head -c 200)"
else skip "no K1 key"; fi

CURRENT=K6
if [ -n "$KEY" ]; then
  req POST "$BASE/key/delete" "$MASTER_KEY" "$(jq -nc --arg k "$KEY" '{keys:[$k]}')"; cdel=$CODE
  # Other tasks keep the key until general_settings.user_api_key_cache_ttl expires, so poll: revoked
  # means 4 requests in a row (spread across tasks by the ALB) all get 401, within the TTL + 10 s
  limit=$(( $(yq -r '.general_settings.user_api_key_cache_ttl // 60' config/config.yaml) + 10 )); t0=$(date +%s); revoked=""
  while [ $(( $(date +%s) - t0 )) -le "$limit" ]; do
    codes=""; for _ in 1 2 3 4; do req GET "$BASE/v1/models" "$KEY"; codes="$codes$CODE "; done
    [ "$codes" = "401 401 401 401 " ] && { revoked=$(( $(date +%s) - t0 )); break; }; sleep 2
  done
  [ "$cdel" = 200 ] && [ -n "$revoked" ] && pass "deleted key -> 401 on every task within ${revoked}s" \
    || fail "delete=$cdel; still accepted ${limit}s later ($codes)"
else skip "no K1 key"; fi

# ---------------------------------------------------------------- Security
echo "== Security"
CURRENT=S1
since=$(( ($(date +%s) - 1800) * 1000 )); leaks=""
for lg in "/ecs/${MAIN_STACK_NAME}-litellm" "/ecs/${MAIN_STACK_NAME}-middleware"; do
  for secret in "$MASTER_KEY" ${KEY:+"$KEY"}; do
    hits=$(aws logs filter-log-events --log-group-name "$lg" --start-time "$since" --filter-pattern "\"$secret\"" \
      --query 'length(events)' --output text 2>/dev/null | awk '{s+=$1} END{print s+0}' || echo err)
    [ "$hits" = 0 ] || leaks="$leaks $lg($hits)"
  done
done
[ -z "$leaks" ] && pass "no master/virtual key in the last 30 min of logs" || fail "found in:$leaks"

# ---------------------------------------------------------------- Spend alarms
echo "== Spend alarms"
CURRENT=X1
if [ -z "${ALARM_EMAIL:-}" ]; then skip "ALARM_EMAIL not set"; else
  acct=$(aws sts get-caller-identity --query Account --output text)
  budget=$(aws budgets describe-budget --account-id "$acct" --budget-name "${MAIN_STACK_NAME}-bedrock-monthly" --query Budget --output json 2>/dev/null)
  covered=$(jq -r '.CostFilters.Service // [] | .[]' <<<"$budget" 2>/dev/null | sort)
  # Every service Cost Explorer has billed for Bedrock in the last 60 days must be in the budget filter
  billed=$(aws ce get-dimension-values --region us-east-1 --dimension SERVICE \
    --time-period "Start=$(date -u -v-60d +%F 2>/dev/null || date -u -d '-60 days' +%F),End=$(date -u +%F)" \
    --query 'DimensionValues[].Value' --output json 2>/dev/null | jq -r '.[] | select(test("Bedrock"))' | sort)
  missing=$(comm -13 <(echo "$covered") <(echo "$billed") | paste -sd, -)
  credit=$(jq -r '.CostTypes.IncludeCredit' <<<"$budget" 2>/dev/null)
  if [ -z "$budget" ]; then fail "budget ${MAIN_STACK_NAME}-bedrock-monthly not found"
  elif [ -n "$missing" ]; then fail "Bedrock-billed services missing from the budget filter: $missing"
  elif [ "$credit" != false ]; then fail "budget includes credits (IncludeCredit=$credit)"
  else pass "\$$(jq -r .BudgetLimit.Amount <<<"$budget") budget, credits excluded, covers all $(echo "$billed" | grep -c .) Bedrock-billed services"; fi
fi

CURRENT=X2
if [ -z "${ALARM_EMAIL:-}" ]; then skip "ALARM_EMAIL not set"; else
  alarm=$(aws cloudwatch describe-alarms --alarm-names "${MAIN_STACK_NAME}-bedrock-tokens-per-hour" --query 'MetricAlarms[0]' --output json 2>/dev/null)
  topic=$(jq -r '.AlarmActions[0] // empty' <<<"$alarm")
  sub=$([ -n "$topic" ] && aws sns list-subscriptions-by-topic --topic-arn "$topic" --query "Subscriptions[?Protocol=='email'].SubscriptionArn | [0]" --output text 2>/dev/null)
  if [ -z "$topic" ]; then fail "tokens-per-hour alarm or its SNS action not found"
  elif [ "$sub" = PendingConfirmation ]; then fail "alarm $(jq -r .StateValue <<<"$alarm"), but the email subscription is unconfirmed: click the link in the AWS Notifications email"
  elif [[ "$sub" == arn:aws:sns:* ]]; then pass "alarm $(jq -r .StateValue <<<"$alarm") at $(jq -r .Threshold <<<"$alarm" | cut -d. -f1) tokens/h, email subscription confirmed"
  else fail "no email subscription on $topic"; fi
fi

CURRENT=X3
if [ "${HEALTH_ALARMS:-true}" != true ]; then skip "HEALTH_ALARMS off"; else
  # 2 ALB 5xx + 2 per target group (litellm, middleware) + 3 RDS + 1 per Valkey node
  want=$((2 + 4 + 3 + ${REDIS_NUM_CACHE_CLUSTERS:-1}))
  notify=$([ "${HEALTH_ALARM_NOTIFICATIONS:-false}" = true ] && [ -n "${ALARM_EMAIL:-}" ] && echo true || echo false)
  alarms=$(aws cloudwatch describe-alarms --alarm-name-prefix "${MAIN_STACK_NAME}-" --output json 2>/dev/null |
    jq -c '[.MetricAlarms[] | select((.AlarmName | endswith("-bedrock-tokens-per-hour")) | not)]')
  n=$(jq length <<<"$alarms")
  wired=$(jq '[.[] | select((.AlarmActions | length) > 0)] | length' <<<"$alarms")
  bad=$(jq -r '[.[] | select(.StateValue == "ALARM") | .AlarmName] | join(", ")' <<<"$alarms")
  if [ "$n" -ne "$want" ]; then fail "$n health alarms, expected $want"
  elif [ "$notify" = true ] && [ "$wired" -ne "$n" ]; then fail "only $wired of $n health alarms notify SNS"
  elif [ "$notify" = false ] && [ "$wired" -ne 0 ]; then fail "$wired health alarms notify SNS although HEALTH_ALARM_NOTIFICATIONS is off"
  elif [ -n "$bad" ]; then fail "in ALARM: $bad"
  else pass "$n health alarms, none in ALARM, email $([ "$notify" = true ] && echo on || echo off)"; fi
fi

echo
echo "== $PASSED passed, $FAILED failed, $SKIPPED skipped  (results: ${RESULTS_FILE#$REPO_ROOT/})"
[ "$FAILED" -eq 0 ]
