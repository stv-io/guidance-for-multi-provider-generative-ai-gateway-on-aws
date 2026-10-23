ARG LITELLM_VERSION=v1.106.2
# "@sha256:..." pins the exact image; the tag is then informative only (set by docker-build-and-deploy.sh)
ARG LITELLM_DIGEST=""
FROM ghcr.io/berriai/litellm:${LITELLM_VERSION}${LITELLM_DIGEST}
