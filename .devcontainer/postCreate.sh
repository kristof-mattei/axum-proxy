#!/usr/bin/env bash

rustc --version

rustup toolchain add nightly
rustup component add --toolchain nightly rustfmt
