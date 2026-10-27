#!/usr/bin/env bash
# Move the pinned LiteLLM image to a new release: resolves the tag's digest, verifies its cosign
# signature, and rewrites LITELLM_VERSION and LITELLM_IMAGE_DIGEST in .env.template (and .env if
# present). It does not build or deploy; run ./deploy.sh and validation/smoke.sh afterwards.
#
#   scripts/litellm-bump.sh             newest patch on the current minor line (v1.106.2 -> v1.106.4)
#   scripts/litellm-bump.sh --latest    newest stable release on any line
#   scripts/litellm-bump.sh v1.105.5    a specific release
#
# LiteLLM publishes several minor lines in parallel and backports fixes to each, so staying on a
# line picks up security fixes without taking new features. Needs gh, git, docker (buildx), cosign.
set -euo pipefail

cd "$(dirname "$0")/.."
UPSTREAM=ghcr.io/berriai/litellm
REPO=BerriAI/litellm

current=$(sed -n 's/^LITELLM_VERSION="\(.*\)"/\1/p' .env.template)
[ -n "$current" ] || { echo "LITELLM_VERSION not found in .env.template" >&2; exit 1; }

# Stable releases only: plain vX.Y.Z tags, not drafts or pre-releases
releases=$(gh api --paginate "repos/$REPO/releases?per_page=100" \
  --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name' |
  grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V)

case "${1:-}" in
  "")       line=${current%.*}; target=$(grep -F "$line." <<<"$releases" | tail -1) ;;
  --latest) target=$(tail -1 <<<"$releases") ;;
  v*)       target=$1; grep -qxF "$target" <<<"$releases" || { echo "$target is not a stable release" >&2; exit 1; } ;;
  *)        echo "usage: $0 [--latest | vX.Y.Z]" >&2; exit 2 ;;
esac

if [ "$target" = "$current" ]; then
  echo "Already on $current (newest for this choice)"
  exit 0
fi

echo "LiteLLM $current -> $target"
echo "Release notes to read before deploying:"
# Every release on the target's line after the current one (or up to the target, when changing line)
awk -v cur="$current" -v tgt="$target" '
  function key(v,  a) { split(substr(v, 2), a, "."); return sprintf("%05d%05d%05d", a[1], a[2], a[3]) }
  key($0) > key(cur) && key($0) <= key(tgt)' <<<"$releases" |
  grep -F "${target%.*}." | sed "s|^|  https://github.com/$REPO/releases/tag/|"

digest=$(docker buildx imagetools inspect "$UPSTREAM:$target" | awk '/^Digest:/ {print $2; exit}')
[[ "$digest" == sha256:* ]] || { echo "Could not resolve the digest of $UPSTREAM:$target" >&2; exit 1; }
# Signature and build provenance; nothing is written unless both pass
scripts/litellm-verify-image.sh "$target" "$digest"

for f in .env.template .env; do
  [ -f "$f" ] || continue
  sed -i.bak -e "s|^LITELLM_VERSION=\".*\"|LITELLM_VERSION=\"$target\"|" \
    -e "s|^LITELLM_IMAGE_DIGEST=\".*\"|LITELLM_IMAGE_DIGEST=\"$digest\"|" "$f"
  rm -f "$f.bak"
  echo "Updated $f"
done

cat <<EOF

Next:
  1. Read the release notes above (breaking changes, config renames, DB migrations).
  2. ./deploy.sh, then validation/smoke.sh. I7 checks the running version is $target.
  3. Commit .env.template on a branch and open a PR with the smoke results.
EOF
