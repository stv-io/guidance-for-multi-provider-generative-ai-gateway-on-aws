# shellcheck shell=bash disable=SC2034  # vars below are consumed by the eval'd deploy.sh exports
# Sourced by smoke.sh: reproduce the TF_VAR_* environment deploy.sh applies with,
# so `terraform plan` can check for drift. The export lines are read from deploy.sh
# itself so the two never diverge. Usage: source validation/tf-vars.sh <log|main>
set -a
source .env
APP_NAME=litellm
MIDDLEWARE_APP_NAME=middleware
LOG_BUCKET_STACK_NAME="log-bucket-stack"
MAIN_STACK_NAME="litellm-stack"
USE_ROUTE53=${USE_ROUTE53:-false}
USE_CLOUDFRONT=${USE_CLOUDFRONT:-true}
CLOUDFRONT_PRICE_CLASS=${CLOUDFRONT_PRICE_CLASS:-PriceClass_100}
if [ -n "$CPU_ARCHITECTURE" ]; then ARCH=$CPU_ARCHITECTURE
else case $(uname -m) in x86_64) ARCH=x86 ;; *) ARCH=arm ;; esac; fi
LOG_BUCKET_ARN=$(terraform -chdir=litellm-s3-log-bucket-terraform output -raw LogBucketArn 2>/dev/null)
set +a

eval "$(grep -E '^export TF_VAR_[a-zA-Z0-9_]+=' deploy.sh)"
[ -n "${LANGFUSE_HOST:-}" ] && export TF_VAR_langfuse_host=$LANGFUSE_HOST

# deploy.sh exports TF_VAR_name twice (log stack first, then main stack)
if [ "${1:-main}" = log ]; then export TF_VAR_name=$LOG_BUCKET_STACK_NAME; else export TF_VAR_name=$MAIN_STACK_NAME; fi
