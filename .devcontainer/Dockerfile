FROM mcr.microsoft.com/devcontainers/rust:2-1-trixie@sha256:e0511e459bc13c6e54cee5a18709ba9d772ff68c996fceacb81381f9acc67fb8

RUN apt-get update && export DEBIAN_FRONTEND=noninteractive \
    && apt-get --yes install --no-install-recommends mold
