#!/usr/bin/env bash
set -e

build() {
    application_name=$1
    platform=$2
    docker buildx \
        build \
        --file Dockerfile . \
        --tag $application_name:latest \
        --build-arg APPLICATION_NAME=$application_name \
        --platform $platform \
        --progress=plain
}

build $(basename ${PWD}) linux/amd64/v3,linux/amd64/v2,linux/amd64,linux/arm64
