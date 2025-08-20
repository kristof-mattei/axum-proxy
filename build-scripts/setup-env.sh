#!/usr/bin/env bash

dpkg_add_arch() {
    # are we cross compiling?
    if ! dpkg-architecture --equal "$1"; then
        dpkg --add-architecture $1
    fi
    apt-get update
    apt-get --no-install-recommends install --yes \
        musl-tools:$1
}

case $TARGET in
    x86_64-unknown-linux-*)
        dpkg_add_arch "amd64" "x86-64"
        ;;
    aarch64-unknown-linux-*)
        dpkg_add_arch "arm64" "aarch64"
        ;;
    *)
        echo "INVALID CONFIGURATION"
        exit 1
        ;;
esac
