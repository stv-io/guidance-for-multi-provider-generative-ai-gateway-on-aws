#!/usr/bin/env bash
# Verify a LiteLLM image before it is built on or deployed:
#   1. the tag still resolves to the pinned digest
#   2. the image is signed with config/litellm-cosign.pub
#   3. its build provenance names https://github.com/BerriAI/litellm as the source, at the commit
#      the release tag points to, for every platform
#
# Check 3 exists because of the 2026-10-21 incident (BerriAI/litellm#47826): the malicious v1.107.0
# went through LiteLLM's own release workflow, so it was signed with the real key and passed check 2.
# It was built from the lookalike repo Berri-AI/litellm, which check 3 rejects.
#
#   scripts/litellm-verify-image.sh v1.106.2 sha256:7294...
set -euo pipefail

version=$1
digest=$2
cd "$(dirname "$0")/.."
UPSTREAM=ghcr.io/berriai/litellm
SOURCE=https://github.com/BerriAI/litellm

tag_digest=$(docker buildx imagetools inspect "$UPSTREAM:$version" | awk '/^Digest:/ {print $2; exit}')
if [ "$tag_digest" != "$digest" ]; then
  echo "Error: $UPSTREAM:$version resolves to $tag_digest, not the pinned $digest" >&2
  exit 1
fi

if ! out=$(cosign verify --key config/litellm-cosign.pub "$UPSTREAM@$digest" 2>&1 >/dev/null); then
  echo "$out" | grep -m1 -i error >&2
  echo "Error: $UPSTREAM@$digest is not signed with config/litellm-cosign.pub" >&2
  exit 1
fi
echo "Verified cosign signature for $UPSTREAM@$digest"

# The commit the release tag points to (^{} peels an annotated tag)
refs=$(git ls-remote "$SOURCE" "refs/tags/$version" "refs/tags/$version^{}")
tag_commit=$(awk '$2 ~ /\^\{\}$/ {print $1}' <<<"$refs")
[ -n "$tag_commit" ] || tag_commit=$(awk '{print $1}' <<<"$refs" | head -1)
[ -n "$tag_commit" ] || { echo "Error: tag $version not found in $SOURCE" >&2; exit 1; }

docker buildx imagetools inspect "$UPSTREAM@$digest" --format '{{json .Provenance}}' |
  python3 -c '
import json, sys

want_source, want_commit = sys.argv[1], sys.argv[2]

def find(node, key):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == key and isinstance(v, str):
                yield v
            yield from find(v, key)
    elif isinstance(node, list):
        for v in node:
            yield from find(v, key)

provenance = json.load(sys.stdin)
if not provenance:
    sys.exit("Error: the image has no build provenance")
for platform, p in provenance.items():
    sources, commits = set(find(p, "vcs:source")), set(find(p, "vcs:revision"))
    if sources != {want_source} or commits != {want_commit}:
        sys.exit(f"Error: {platform} was built from {sorted(sources)} at {sorted(commits)}, "
                 f"expected {want_source} at {want_commit}")
    print(f"Verified provenance for {platform}: {want_source} at {want_commit[:12]}")
' "$SOURCE" "$tag_commit"
