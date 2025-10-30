#!/usr/bin/env bash
set -e

build() {
    APPLICATION_NAME=$1
    PLATFORM=$2
    docker buildx \
        build \
        --file Dockerfile . \
        --tag $APPLICATION_NAME:latest \
        --build-arg APPLICATION_NAME=$APPLICATION_NAME \
        --platform $PLATFORM \
        --progress=plain
}

build $(basename ${PWD}) linux/amd64/v3,linux/amd64/v2,linux/amd64,linux/arm64
