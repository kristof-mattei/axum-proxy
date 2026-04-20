FROM mcr.microsoft.com/devcontainers/rust:2-1-trixie@sha256:354a0f58f13d93fb6f24e694124fd2d24e6e5306102c7bb3bb1cb26fa4951d46

RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get --yes install --no-install-recommends mold
