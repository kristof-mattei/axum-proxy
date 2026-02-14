# syntax=docker/dockerfile:1@sha256:b6afd42430b15f2d2a4c5a02b919e98a525b785b1aaff16747d2f623364e39b6
# check=skip=SecretsUsedInArgOrEnv,error=true

# Rust toolchain setup
FROM --platform=${BUILDPLATFORM} rust:1.93.1-slim-trixie@sha256:9663b80a1621253d30b146454f903de48f0af925c967be48c84745537cd35d8b AS rust-base

ARG APPLICATION_NAME
ARG DEBIAN_FRONTEND=noninteractive

RUN rm -f /etc/apt/apt.conf.d/docker-clean \
    && echo 'Binary::apt::APT::Keep-Downloaded-Packages "true";' > /etc/apt/apt.conf.d/keep-cache

# borrowed (Ba Dum Tss!) from
# https://github.com/pablodeymo/rust-musl-builder/blob/7a7ea3e909b1ef00c177d9eeac32d8c9d7d6a08c/Dockerfile#L48-L49
RUN --mount=type=cache,id=apt-cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lib,target=/var/lib/apt,sharing=locked \
    apt-get update \
    && apt-get upgrade --yes \
    && apt-get install --no-install-recommends --yes \
        build-essential \
        musl-dev

FROM rust-base AS rust-linux-amd64
ARG TARGET=x86_64-unknown-linux-musl

FROM rust-base AS rust-linux-arm64
ARG TARGET=aarch64-unknown-linux-musl

FROM rust-linux-${TARGETARCH} AS rust-cargo-build

# amd64 or arm64
ARG TARGETARCH
# linux or ...
ARG TARGETOS
# used by `build.sh`, v2, v3 or empty
ARG TARGETVARIANT
# like TARGETPLATFORM, but with dashes
ARG TARGETPLATFORMDASH="${TARGETOS}-${TARGETARCH}-${TARGETVARIANT:-base}"
ARG CARGO_TARGET_DIR=/build/target/${TARGETPLATFORMDASH}

COPY ./build-scripts /build-scripts

RUN --mount=type=cache,id=apt-cache-${TARGET},from=rust-base,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,id=apt-lib-${TARGET},from=rust-base,target=/var/lib/apt,sharing=locked \
    /build-scripts/setup-env.sh

RUN rustup target add ${TARGET}

# The following block
# creates an empty app, and we copy in Cargo.toml and Cargo.lock as they represent our dependencies
# This allows us to copy in the source in a different layer which in turn allows us to leverage Docker's layer caching
# That means that if our dependencies don't change rebuilding is much faster
WORKDIR /build
COPY ./.cargo ./.cargo
COPY ./Cargo.toml ./Cargo.lock ./

# main crate
WORKDIR /build/crates/
RUN cargo new --bin --vcs none ${APPLICATION_NAME}
COPY ./crates/${APPLICATION_NAME}/Cargo.toml ./${APPLICATION_NAME}/Cargo.toml
RUN echo "fn main() {}" > ./${APPLICATION_NAME}/src/build.rs

# repeat this for each crate
WORKDIR /build/crates/
RUN cargo new --lib --vcs none shared
COPY ./crates/shared/Cargo.toml ./shared/Cargo.toml

WORKDIR /build

# We use `fetch` to pre-download the files to the cache
# 1. Notice `sharing=locked` to avoid 2 processes concurrently writing and corrupting the cache, as `cp` is non-atomic
# 2. We do the copy back-and-forth, as we do need the files in the image for the next layer.
# 3.
RUN --mount=type=cache,id=cargo-git,target=/tmp/cache/git/db,sharing=locked \
    --mount=type=cache,id=cargo-registry-index,target=/tmp/cache/registry/index,sharing=locked \
    --mount=type=cache,id=cargo-registry-cache,target=/tmp/cache/registry/cache,sharing=locked \
    \
    # Copy in from cache
    mkdir -p /usr/local/cargo/git/db \
             /usr/local/cargo/registry/index \
             /usr/local/cargo/registry/cache && \
    cp -rp /tmp/cache/git/db/. /usr/local/cargo/git/db/ || true && \
    cp -rp /tmp/cache/registry/index/. /usr/local/cargo/registry/index/ || true && \
    cp -rp /tmp/cache/registry/cache/. /usr/local/cargo/registry/cache/ || true && \
    \
    cargo fetch --locked && \
    \
    # copy out
    cp -rp /usr/local/cargo/git/db/. /tmp/cache/git/db/ && \
    cp -rp /usr/local/cargo/registry/index/. /tmp/cache/registry/index/ && \
    cp -rp /usr/local/cargo/registry/cache/. /tmp/cache/registry/cache/

RUN --mount=type=cache,id=target-${TARGETPLATFORMDASH},target=${CARGO_TARGET_DIR},sharing=locked \
    /build-scripts/build.sh build --frozen --release

# Rust full build
FROM rust-cargo-build AS rust-build

WORKDIR /build

# now we copy in the source which is more prone to changes and build it
COPY ./crates ./crates

# ensure cargo picks up on the fact that we copied in our code
RUN find ./crates -type f -name '*.rs' -exec touch {} +

ENV PATH="/output/bin:$PATH"

# --release not needed, it is implied with install
RUN --mount=type=cache,id=target-${TARGETPLATFORMDASH},target=${CARGO_TARGET_DIR},sharing=locked \
    /build-scripts/build.sh install --frozen --path "./crates/${APPLICATION_NAME}/" --root /output

# Container user setup
FROM --platform=${BUILDPLATFORM} alpine:3.23.3@sha256:25109184c71bdad752c8312a8623239686a9a2071e8825f20acb8f2198c3f659 AS passwd-build

# setting `--system` prevents prompting for a password
RUN addgroup --gid 900 appgroup \
    && adduser --ingroup appgroup --uid 900 --system --shell /bin/false appuser

RUN cat /etc/group | grep appuser > /tmp/group_appuser
RUN cat /etc/passwd | grep appuser > /tmp/passwd_appuser

# Final stage, no `BUILDPLATFORM`, this one is run where it is deployed
FROM scratch

ARG APPLICATION_NAME

COPY --from=passwd-build /tmp/group_appuser /etc/group
COPY --from=passwd-build /tmp/passwd_appuser /etc/passwd

COPY --from=rust-build /output/bin/${APPLICATION_NAME} /app/entrypoint

USER appuser

ENV RUST_BACKTRACE=full

WORKDIR /app

ENTRYPOINT ["/app/entrypoint"]
