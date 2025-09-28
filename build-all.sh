#!/usr/bin/env bash
set -e

build() {
    APPLICATION_NAME=$1
    PLATFORM=$2
    docker build \
        --file Dockerfile . \
        --tag $APPLICATION_NAME:latest-${2//\//-} \
        --build-arg APPLICATION_NAME=$APPLICATION_NAME \
        --platform $PLATFORM \
        --progress=plain
}

name=$(basename ${PWD})

build $name linux/amd64/v3
build $name linux/amd64/v2
build $name linux/amd64
build $name linux/arm64
