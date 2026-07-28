FROM mcr.microsoft.com/devcontainers/rust:2-1-trixie@sha256:1707e2a8007968925f110c0961811200e9bb10e0ec055e2734857c59189a8b13

RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get --yes install --no-install-recommends mold
