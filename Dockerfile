# Rust toolchain setup
FROM --platform=${BUILDPLATFORM} rust:1.92.0-slim-trixie@sha256:bf3368a992915f128293ac76917ab6e561e4dda883273c8f5c9f6f8ea37a378e AS rust-base

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

FROM rust-linux-${TARGETARCH//\//-} AS rust-cargo-build

ARG DEBIAN_FRONTEND=noninteractive
# expose into `build.sh`
ARG TARGETVARIANT

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

RUN cargo init --name ${APPLICATION_NAME}

COPY ./.cargo ./Cargo.toml ./Cargo.lock ./

RUN echo "fn main() {}" > ./src/build.rs

# We use `fetch` to pre-download the files to the cache
# Notice we do this in the target arch specific branch
# We do this because we want to do it after `setup-env.sh`,
# as the env is less likely to change than the code
# We do lock the cache, to avoid corruption when building it for
# both target platforms. It doesn't matter, as after unlocking the other one
# just validates, but doesn't need to download anything
RUN --mount=type=cache,id=cargo-git,target=/usr/local/cargo/git/db,sharing=locked \
    --mount=type=cache,id=cargo-registry-index,target=/usr/local/cargo/registry/index,sharing=locked \
    --mount=type=cache,id=cargo-registry-cache,target=/usr/local/cargo/registry/cache,sharing=locked \
    cargo fetch

RUN --mount=type=cache,target=/build/target/${TARGET},sharing=locked \
    --mount=type=cache,id=cargo-git,target=/usr/local/cargo/git/db \
    --mount=type=cache,id=cargo-registry-index,target=/usr/local/cargo/registry/index \
    --mount=type=cache,id=cargo-registry-cache,target=/usr/local/cargo/registry/cache \
    /build-scripts/build.sh build --release --target-dir ./target/${TARGET}

# Rust full build
FROM rust-cargo-build AS rust-build

# to expose into `build.sh`
ARG TARGETVARIANT

WORKDIR /build

# now we copy in the source which is more prone to changes and build it
COPY ./src ./src

# ensure cargo picks up on the fact that we copied in our code
RUN touch ./src/main.rs ./src/build.rs

ENV PATH="/output/bin:$PATH"

# --release not needed, it is implied with install
RUN --mount=type=cache,target=/build/target/${TARGET},sharing=locked \
    --mount=type=cache,id=cargo-git,target=/usr/local/cargo/git/db \
    --mount=type=cache,id=cargo-registry-index,target=/usr/local/cargo/registry/index \
    --mount=type=cache,id=cargo-registry-cache,target=/usr/local/cargo/registry/cache \
    /build-scripts/build.sh install --path . --locked --target-dir ./target/${TARGET} --root /output

# Container user setup
FROM --platform=${BUILDPLATFORM} alpine:3.23.2@sha256:865b95f46d98cf867a156fe4a135ad3fe50d2056aa3f25ed31662dff6da4eb62 AS passwd-build

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
