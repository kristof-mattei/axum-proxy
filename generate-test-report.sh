#!/bin/bash

BASE_RUSTFLAGS=""
CARGO_FEATURES=""

export RUSTFLAGS="${BASE_RUSTFLAGS} --allow=warnings -Cinstrument-coverage"
# build-* ones are not parsed by grcov
export LLVM_PROFILE_FILE="profiling/build-%p-%m.profraw"

cargo build ${CARGO_FEATURES} --all-targets --locked --workspace --verbose

# different
LLVM_PROFILE_FILE="profiling/profile-%p-%m.profraw"
cargo nextest run --profile ci --no-fail-fast ${CARGO_FEATURES} --all-targets --workspace

grcov $(find . -name "profile-*.profraw" -print) \
    --binary-path ./target/debug/ \
    --branch \
    --ignore-not-existing \
    --keep-only "src/**" \
    --llvm \
    --output-type html \
    --output-path ./reports/ \
    --source-dir .
