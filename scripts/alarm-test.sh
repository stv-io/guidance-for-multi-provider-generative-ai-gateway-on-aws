#!/usr/bin/env bash
# Health-alarm test. DISRUPTIVE: the gateway is down for several minutes in part 2.
#
#   1. Crash: stop the running task(s) and time how long ECS takes to bring a replacement back
#      healthy behind the ALB. The no-healthy-targets alarm needs 3 minutes without a healthy
#      target, so a quick replacement may not trip it; the script reports which happened.
#   2. Outage: scale the service to 0 tasks until <name>-litellm-no-healthy-targets goes to
#      ALARM, then restore the desired count and time the return to OK.
#
# The service ignores desired_count in Terraform, so restoring it by hand leaves no drift.
#
#   AWS_PROFILE=sandbox scripts/alarm-test.sh            # both parts
#   AWS_PROFILE=sandbox scripts/alarm-test.sh crash      # part 1 only
set -euo pipefail

cd "$(dirname "$0")/.."
MODE=${1:-all}
NAME=litellm-stack
tfout() { (cd litellm-terraform-stack && terraform output -raw "$1" 2>/dev/null); }
CLUSTER=$(tfout LitellmEcsCluster); SERVICE=$(tfout LitellmEcsTask); BASE=$(tfout ServiceURL)
[ -n "$CLUSTER" ] && [ -n "$SERVICE" ] || { echo "could not read the Terraform outputs (deploy first)" >&2; exit 2; }
ALARM="$NAME-litellm-no-healthy-targets"
START=$(date +%s)

ts() { local s=$(( $(date +%s) - START )); printf '%3d:%02d' $((s / 60)) $((s % 60)); }
say() { echo "$(ts)  $*"; }
alarm_state() { aws cloudwatch describe-alarms --alarm-names "$ALARM" --query 'MetricAlarms[0].StateValue' --output text; }
svc() { aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" --query "services[0].$1" --output text; }
http_code() { curl -s -o /dev/null -w '%{http_code}' "$BASE/health/liveliness" --max-time 5 || true; }
# Healthy targets in the emptiest of the service's target groups (LiteLLM and middleware)
tg_healthy() {
  local tg n min=99
  for tg in $(svc 'loadBalancers[].targetGroupArn'); do
    n=$(aws elbv2 describe-target-health --target-group-arn "$tg" \
      --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" --output text)
    (( n < min )) && min=$n
  done
  echo "$min"
}
# wait_for <timeout s> <description> <command...>: poll every 10 s until the command succeeds
wait_for() {
  local timeout=$1 what=$2 t0; shift 2; t0=$(date +%s)
  until "$@"; do
    if (( $(date +%s) - t0 > timeout )); then say "timed out waiting for $what"; return 1; fi
    sleep 10
  done
  say "$what after $(( $(date +%s) - t0 )) s"
}
is_alarm() { [ "$(alarm_state)" = ALARM ]; }
is_ok() { [ "$(alarm_state)" = OK ]; }
healthy() { [ "$(tg_healthy)" -ge 1 ] && [ "$(http_code)" = 200 ]; }
unhealthy() { [ "$(http_code)" != 200 ]; }

DESIRED=$(svc desiredCount)
say "service $SERVICE: desired $DESIRED, running $(svc runningCount); $ALARM is $(alarm_state); $BASE/health/liveliness -> $(http_code)"
[ "$(alarm_state)" = OK ] || { echo "the alarm must start in OK" >&2; exit 1; }
CRASH_RESULT="" OUTAGE_RESULT=""

if [ "$MODE" = all ] || [ "$MODE" = crash ]; then
  echo; say "== Part 1: stop the running task (simulated crash)"
  tasks=$(aws ecs list-tasks --cluster "$CLUSTER" --service-name "$SERVICE" --desired-status RUNNING --query 'taskArns' --output text)
  for t in $tasks; do aws ecs stop-task --cluster "$CLUSTER" --task "$t" --reason "alarm-test.sh: simulated crash" >/dev/null; done
  say "stopped $(wc -w <<<"$tasks" | tr -d ' ') task(s)"
  t0=$(date +%s)
  wait_for 120 "gateway stopped answering" unhealthy || true
  # Watch for up to 10 minutes: healthy again, and whether the alarm fired meanwhile
  fired=no
  until healthy; do
    is_alarm && [ $fired = no ] && { fired=yes; say "alarm went to ALARM"; }
    (( $(date +%s) - t0 > 600 )) && { say "no healthy replacement after 10 minutes"; exit 1; }
    sleep 10
  done
  recovery=$(( $(date +%s) - t0 ))
  say "replacement task healthy and serving, $recovery s after the stop (alarm fired: $fired)"
  if [ $fired = yes ]; then wait_for 600 "alarm back to OK" is_ok; else
    # The alarm evaluates 1-minute periods, so give it time to catch a late breach
    sleep 60; is_alarm && say "alarm went to ALARM late" && wait_for 600 "alarm back to OK" is_ok || true
  fi
  CRASH_RESULT="recovered in ${recovery} s, alarm fired: $fired"
fi

if [ "$MODE" = all ] || [ "$MODE" = outage ]; then
  echo; say "== Part 2: outage (service scaled to 0 tasks)"
  wait_for 600 "alarm OK before the outage" is_ok
  aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count 0 >/dev/null
  trap 'aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count "$DESIRED" >/dev/null; echo "restored desired count $DESIRED"' EXIT
  say "desired count set to 0"
  t0=$(date +%s)
  wait_for 300 "gateway stopped answering" unhealthy
  wait_for 900 "alarm went to ALARM" is_alarm
  to_alarm=$(( $(date +%s) - t0 ))
  aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count "$DESIRED" >/dev/null
  trap - EXIT
  say "desired count restored to $DESIRED"
  t1=$(date +%s)
  wait_for 600 "gateway serving again" healthy
  wait_for 600 "alarm back to OK" is_ok
  to_ok=$(( $(date +%s) - t1 ))
  OUTAGE_RESULT="ALARM ${to_alarm} s after the outage began; OK ${to_ok} s after restoring"
fi

echo
say "== Summary"
[ -n "$CRASH_RESULT" ] && echo "  crash:  $CRASH_RESULT"
[ -n "$OUTAGE_RESULT" ] && echo "  outage: $OUTAGE_RESULT"
echo "  alarm actions (email) are off unless HEALTH_ALARM_NOTIFICATIONS=true"
