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

for bin in aws terraform curl jq yq; do
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
  CODE=$(curl -sS -o "$TMP/body" -w '%{http_code}' -X "$1" "$2" "${auth[@]}" \
    -H 'Content-Type: application/json' ${4:+--data "$4"} --max-time 90) || CODE=000
}
body() { cat "$TMP/body"; }
chat_json() { jq -nc --arg m "$1" --arg p "${2:-Reply with the single word: pong}" '{model:$m,max_tokens:20,messages:[{role:"user",content:$p}]}'; }

TEMP_KEYS=()
cleanup() {
  for k in "${TEMP_KEYS[@]:-}"; do
    [ -n "$k" ] && curl -sS -o /dev/null -X POST "$BASE/key/delete" -H "Authorization: Bearer $MASTER_KEY" \
      -H 'Content-Type: application/json' --data "$(jq -nc --arg k "$k" '{keys:[$k]}')" --max-time 30 || true
  done
  rm -rf "$TMP"
}

gen_key() { # gen_key JSON -> echoes key
  req POST "$BASE/key/generate" "$MASTER_KEY" "$1"
  local k; k=$(body | jq -r '.key // empty' 2>/dev/null)
  [ -n "$k" ] && TEMP_KEYS+=("$k")
  echo "$k"
}

echo "== Discovering deployment"
tfout() { terraform -chdir="$MAIN_TF" output -raw "$1" 2>/dev/null; }
BASE=$(tfout ServiceURL); ALB=$(tfout alb_dns_name); VPC_ID=$(tfout vpc_id)
CLUSTER=$(tfout LitellmEcsCluster); SERVICE=$(tfout LitellmEcsTask)
CF_DOMAIN=$(tfout cloudfront_domain_name)
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

# ---------------------------------------------------------------- Edge
echo "== Edge"
CURRENT=E1
if [ -n "$CF_DOMAIN" ]; then
  CODE=$(curl -sk -o /dev/null -w '%{http_code}' "https://$ALB/v1/models" -H "Authorization: Bearer $MASTER_KEY" --max-time 20)
  [ "$CODE" = 403 ] && pass "direct ALB request -> 403" || fail "direct ALB request -> $CODE (want 403)"
else skip "CloudFront not in use"; fi

CURRENT=E2
if [ -n "$CF_DOMAIN" ]; then
  CODE=$(curl -s -o /dev/null -w '%{http_code}' "http://$CF_DOMAIN/health/liveliness" --max-time 20)
  [[ "$CODE" =~ ^30[1278]$ ]] && pass "http -> $CODE redirect" || fail "http -> $CODE"
else skip "CloudFront not in use"; fi

CURRENT=E3; req GET "$BASE/health/liveliness" ""
[ "$CODE" = 200 ] && pass "/health/liveliness 200" || fail "/health/liveliness $CODE $(body | head -c 200)"

CURRENT=E4; req GET "$BASE/bedrock/health/liveliness" ""
[ "$CODE" = 200 ] && [ "$(body | jq -r .litellm 2>/dev/null)" = connected ] && pass "middleware healthy, litellm connected" || fail "$CODE $(body | head -c 200)"

CURRENT=E5; CODE=$(curl -sL -o "$TMP/body" -w '%{http_code}' "$BASE/ui/" --max-time 30)
[ "$CODE" = 200 ] && grep -qi '<html' "$TMP/body" && pass "/ui/ 200 html" || fail "/ui/ $CODE"

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

CURRENT=M3; req POST "$BASE/v1/embeddings" "$MASTER_KEY" "$(jq -nc --arg m "$EMBED_MODEL" '{model:$m,input:"hello gateway"}')"
dim=$(body | jq '.data[0].embedding | length' 2>/dev/null)
[ "$CODE" = 200 ] && [ "$dim" = 1024 ] && pass "$EMBED_MODEL dim=$dim" || fail "$CODE dim=$dim $(body | head -c 200)"

CURRENT=M4
req POST "$BASE/bedrock/model/$DEFAULT_MODEL/converse" "$MASTER_KEY" \
  '{"messages":[{"role":"user","content":[{"text":"Reply with the single word: pong"}]}],"inferenceConfig":{"maxTokens":20}}'
txt=$(body | jq -r '.output.message.content[0].text // empty' 2>/dev/null)
[ "$CODE" = 200 ] && [ -n "$txt" ] && pass "converse: \"${txt:0:40}\"" || fail "$CODE $(body | head -c 300)"

CURRENT=M5
if [ "${ALL_MODELS:-0}" = 1 ]; then
  bad=""; n=0
  for m in $(yq -r '.model_list[] | select(.model_name | test("embed|rerank") | not) | .model_name' config/config.yaml); do
    n=$((n+1)); req POST "$BASE/v1/chat/completions" "$MASTER_KEY" "$(chat_json "$m")"
    [ "$CODE" = 200 ] || bad="$bad $m($CODE)"
  done
  [ -z "$bad" ] && pass "$n chat models answered" || fail "failing:$bad"
else skip "set ALL_MODELS=1"; fi

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
KEY=$(gen_key "$(jq -nc --arg m "$DEFAULT_MODEL" '{models:[$m],max_budget:1,key_alias:("smoke-"+(now|tostring)),metadata:{purpose:"validation/smoke.sh"}}')")
[[ "$KEY" == sk-* ]] && pass "virtual key issued (restricted to $DEFAULT_MODEL)" || fail "$CODE $(body | head -c 200)"

CURRENT=H2
if [ -n "${SID:-}" ] && [ -n "$KEY" ]; then
  req POST "$BASE/chat-history" "$KEY" "$(jq -nc --arg s "$SID" '{session_id:$s}')"
  [ "$CODE" = 401 ] && pass "other key -> 401" || fail "other key -> $CODE"
else skip "needs H1 session and K1 key"; fi

CURRENT=K2
if [ -n "$KEY" ]; then req POST "$BASE/v1/chat/completions" "$KEY" "$(chat_json "$DEFAULT_MODEL")"
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

CURRENT=K5
RKEY=$(gen_key "$(jq -nc --arg m "$DEFAULT_MODEL" '{models:[$m],rpm_limit:1,key_alias:("smoke-rpm-"+(now|tostring))}')")
if [ -n "$RKEY" ]; then
  req POST "$BASE/v1/chat/completions" "$RKEY" "$(chat_json "$DEFAULT_MODEL")"; c1=$CODE
  req POST "$BASE/v1/chat/completions" "$RKEY" "$(chat_json "$DEFAULT_MODEL")"; c2=$CODE
  [ "$c1" = 200 ] && [ "$c2" = 429 ] && pass "1st=200 2nd=429" || fail "1st=$c1 2nd=$c2"
else fail "could not create rpm-limited key"; fi

CURRENT=K6
if [ -n "$KEY" ]; then
  req POST "$BASE/key/delete" "$MASTER_KEY" "$(jq -nc --arg k "$KEY" '{keys:[$k]}')"; cdel=$CODE
  sleep 2; req POST "$BASE/v1/chat/completions" "$KEY" "$(chat_json "$DEFAULT_MODEL")"
  [ "$cdel" = 200 ] && [ "$CODE" = 401 ] && pass "deleted key -> 401" || fail "delete=$cdel then use=$CODE"
else skip "no K1 key"; fi

# ---------------------------------------------------------------- Security
echo "== Security"
CURRENT=S1
since=$(( ($(date +%s) - 1800) * 1000 )); leaks=""
for lg in "/ecs/${MAIN_STACK_NAME}-litellm" "/ecs/${MAIN_STACK_NAME}-middleware"; do
  for secret in "$MASTER_KEY" ${KEY:+"$KEY"}; do
    hits=$(aws logs filter-log-events --log-group-name "$lg" --start-time "$since" --filter-pattern "\"$secret\"" \
      --query 'length(events)' --output text 2>/dev/null || echo err)
    [ "$hits" = 0 ] || leaks="$leaks $lg($hits)"
  done
done
[ -z "$leaks" ] && pass "no master/virtual key in the last 30 min of logs" || fail "found in:$leaks"

echo
echo "== $PASSED passed, $FAILED failed, $SKIPPED skipped  (results: ${RESULTS_FILE#$REPO_ROOT/})"
[ "$FAILED" -eq 0 ]
