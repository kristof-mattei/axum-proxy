#!/usr/bin/env bash

# sane defaults
c_compiler="gcc"
cpp_compiler="g++"

rust_flags="-Clink-self-contained=yes -Clinker=rust-lld"

case $TARGET in
    x86_64-unknown-linux-*)
        c_compiler="x86_64-linux-gnu-gcc-12"
        cpp_compiler="x86_64-linux-gnu-g++-12"
        ;;
    aarch64-unknown-linux-*)
        c_compiler="aarch64-linux-gnu-gcc"
        cpp_compiler="aarch64-linux-gnu-g++"
        ;;
    *)
        echo "INVALID CONFIGURATION"
        exit 1
        ;;
esac

# replace - with _ in the Rust target
target_lower=${TARGET//-/_}

target_upper=${target_lower^^}

cc_var=CC_${target_lower}
declare -x "${cc_var}=${c_compiler}"

cxx_var=CXX_${target_lower}
declare -x "${cxx_var}=${cpp_compiler}"

cargo_target_linker_var=CARGO_TARGET_${target_upper}_LINKER
declare -x "${cargo_target_linker_var}=${c_compiler}"

RUSTFLAGS=$rust_flags cargo $@
