FROM mcr.microsoft.com/devcontainers/rust:2-1-trixie@sha256:fb71ea387adcb6452f37854dfa47d8585bc12a2f6d513da261019b47764da6b0

RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get --yes install --no-install-recommends mold
