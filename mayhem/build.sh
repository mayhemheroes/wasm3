#!/usr/bin/env bash
#
# mayhem/build.sh — build wasm3's fuzz harness + upstream test suite.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# exports the build contract (CC, CXX, LIB_FUZZING_ENGINE, SANITIZER_FLAGS, DEBUG_FLAGS,
# STANDALONE_FUZZ_MAIN, SRC). Builds:
#   1. a sanitized, coverage-instrumented libm3.a and links the upstream libFuzzer harness
#      (platforms/app_fuzz/fuzzer.c) against it -> /mayhem/fuzzer (+ /mayhem/fuzzer-standalone)
#   2. the wasm3 CLI with NORMAL flags (BUILD_WASI=simple: the built-in WASI, no network
#      fetch of uvwasi) at build/wasm3 — where test/run-spec-test.py and test/run-wasi-test.py
#      expect it. mayhem/test.sh only RUNS those suites.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) Sanitized + coverage-instrumented interpreter library for the fuzz build.
#    -fsanitize=fuzzer-no-link instruments libm3 itself so libFuzzer gets edges from the
#    interpreter (the code under test), not just the tiny harness. BUILD_WASI=none avoids
#    any network fetch (uvwasi) — the whole build is air-gapped.
cmake -B build-fuzz \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DBUILD_WASI=none -DBUILD_NATIVE=OFF \
      -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"
cmake --build build-fuzz --target m3 -j"$MAYHEM_JOBS"

# 2) The harness, twice: the libFuzzer binary and the standalone run-once reproducer.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
    platforms/app_fuzz/fuzzer.c -Isource build-fuzz/source/libm3.a -lm \
    -o /mayhem/fuzzer
$CC $SANITIZER_FLAGS $DEBUG_FLAGS "$STANDALONE_FUZZ_MAIN" \
    platforms/app_fuzz/fuzzer.c -Isource build-fuzz/source/libm3.a -lm \
    -o /mayhem/fuzzer-standalone

# 3) Test-suite build: the wasm3 CLI with the project's normal flags. BUILD_WASI=simple is
#    the built-in WASI implementation (upstream CI's *-no-uvwasi configs) — same suites pass,
#    no FetchContent network access. run-spec-test.py / run-wasi-test.py run ../build/wasm3.
cmake -B build \
      -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
      -DBUILD_WASI=simple -DBUILD_NATIVE=OFF \
      -DCMAKE_C_FLAGS="$COVERAGE_FLAGS"
cmake --build build -j"$MAYHEM_JOBS"

echo "build.sh done:"
ls -la /mayhem/fuzzer /mayhem/fuzzer-standalone build/wasm3
