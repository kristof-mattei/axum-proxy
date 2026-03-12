FROM mcr.microsoft.com/devcontainers/rust:2-1-trixie@sha256:9813ab046899db62589dd40e43ce6b8fa20b3cc20407288b4dd647e95bb22526

RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get --yes install --no-install-recommends mold
