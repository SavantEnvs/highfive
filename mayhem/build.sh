#!/usr/bin/env bash
#
# mayhem/build.sh — build this repo's fuzz harness(es). EDIT per repo.
#
# Runs inside the commit image (mayhem/Dockerfile) as `mayhem` in /mayhem. The base image
# (ghcr.io/savantenvs/base) already exports the build contract — use these, don't redefine:
#   CC, CXX             stock clang / clang++
#   LIB_FUZZING_ENGINE  -fsanitize=fuzzer   (link into each harness that has a LLVMFuzzer entry)
#   SANITIZER_FLAGS     -fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer
#                       (ASan + UBSan, both set to HALT — so Mayhem catches memory AND UB defects)
#   DEBUG_FLAGS         -g -gdwarf-3   (DWARF debug info — always on for fuzz/standalone builds,
#                       independent of the sanitizer off-switch; DWARF version must be < 4)
#   RUST_DEBUG_FLAGS    -C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3
#                       (thread through RUSTFLAGS on every cargo-fuzz build)
#   GO_DEBUG_FLAGS      -gcflags=all=-N -l
#                       (thread through go build / go-fuzz-build so the linked ELF keeps symbols)
#   SRC                 /mayhem (the repo source)
#
# Contract: build EVERYTHING here — one runnable binary per fuzz harness, AND the project's test
# suite (so mayhem/test.sh only has to RUN it, never compile). Keep it ADDITIVE (build upstream as
# upstream documents; don't edit upstream files). IMPORTANT: build the PROJECT ITSELF with
# $SANITIZER_FLAGS and $DEBUG_FLAGS (not just the harness) so the fuzzed code is instrumented
# AND carries DWARF < 4 symbols — otherwise ASan/UBSan only see the harness, not the library
# you're trying to find bugs in, and backtraces won't resolve project source lines. Build the TEST
# suite with the project's NORMAL flags (a clean, independent build) so test.sh stays an honest
# functional oracle and won't false-fail on benign UB. Leave the test binary/runner where test.sh
# expects it.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs come from the ENVIRONMENT (overridable), with sane defaults — no if-statements,
# just parameter-expansion fallbacks. Default sanitizers are the base's ASan+UBSan (halting); override
# per build via the Dockerfile's `--build-arg SANITIZER_FLAGS="..."`.
# NB: SANITIZER_FLAGS uses `=` (no colon) on purpose — `=` only fills when the var is UNSET, so an
# explicit EMPTY value (`--build-arg SANITIZER_FLAGS=`) is honored and builds with NO sanitizers
# (useful when you want the program's natural crash / full backtrace, not an ASan report). The other
# knobs use `:=` (default on empty too). MAYHEM_JOBS sets build parallelism (falls back to nproc).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS carries DWARF debug info INDEPENDENTLY of the sanitizer off-switch (so an empty
# SANITIZER_FLAGS still yields DWARF symbols). DWARF MUST be < 4 (Mayhem triage can't read >=4); clang-19's
# plain `-g` emits DWARF-5, so `-gdwarf-3` is explicit. Apply $DEBUG_FLAGS to the fuzz/harness/standalone
# builds (NOT the test/oracle build). Rust/Go carry the same intent via their language flags below.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -C force-frame-pointers=yes -C llvm-args=-gdwarf-3}"
: "${GO_DEBUG_FLAGS:=-gcflags=all=-N -l}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
# COVERAGE_FLAGS: empty by default → no effect on the normal oracle build. Set it via the Dockerfile's
# `--build-arg COVERAGE_FLAGS="-fprofile-instr-generate -fcoverage-mapping"` to instrument the TEST
# build for source-coverage measurement (how much of the project the test suite actually exercises —
# a quality signal for the oracle; complements the anti-reward-hack sabotage check). APPEND it to the
# test build's compile+link flags in step 3 (NOT the fuzz build); after `test.sh` runs, merge with
# `llvm-profdata` and report with `llvm-cov`. Empty value is honored (`=`, not `:=`).
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS RUST_DEBUG_FLAGS GO_DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

# 1) Build upstream (EDIT: the project's real build). Apply $DEBUG_FLAGS alongside $SANITIZER_FLAGS so
#    the project carries DWARF < 4 symbols (put $DEBUG_FLAGS AFTER $SANITIZER_FLAGS — its -gdwarf-3 then
#    wins over any -g the base may carry).
#    cmake:  cmake -B build -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
#                  -DCMAKE_C_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
#                  -DCMAKE_CXX_FLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" \
#            && cmake --build build -j"$MAYHEM_JOBS"
#    autotools:  ./configure CC="$CC" CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" && make -j"$MAYHEM_JOBS"
#    Rust (cargo-fuzz):  RUSTFLAGS="${RUSTFLAGS:-} $RUST_DEBUG_FLAGS -Zsanitizer=address" \
#            cargo fuzz build --release <target> --fuzz-dir mayhem/fuzz
#    Go (go-fuzz/libFuzzer):  go build $GO_DEBUG_FLAGS -tags gofuzz ...  (do NOT pass -ldflags=-s -w)

# 2) Compile each harness in mayhem/ TWICE (EDIT): once linking the fuzzing engine (the fuzzer
#    binary), once linking the standalone driver $STANDALONE_FUZZ_MAIN (a NON-fuzzer run-once
#    reproducer: takes an input file, runs LLVMFuzzerTestOneInput once, crashes naturally — no
#    libFuzzer runtime). Both respect $SANITIZER_FLAGS and $DEBUG_FLAGS (so the empty sanitizer
#    off-switch still keeps DWARF symbols).
#    $CC  $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
#        "$SRC/mayhem/fuzz_example.c" -I"$SRC/include" "$SRC/build/libexample.a" \
#        -o /mayhem/fuzz_example
#    $CC  $SANITIZER_FLAGS $DEBUG_FLAGS "$STANDALONE_FUZZ_MAIN" \
#        "$SRC/mayhem/fuzz_example.c" -I"$SRC/include" "$SRC/build/libexample.a" \
#        -o /mayhem/fuzz_example-standalone
#    (If the project ships its own file-input driver — e.g. fio's onefile.c, built when
#     LIB_FUZZING_ENGINE is unset — use that instead of $STANDALONE_FUZZ_MAIN.)
#    C++ HARNESS: compile the driver as C first so its LLVMFuzzerTestOneInput ref keeps C linkage
#    (clang++ would mangle it and miss the harness's extern "C" def):
#       $CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
#       $CXX $SANITIZER_FLAGS $DEBUG_FLAGS <c++flags> harness.cpp /tmp/standalone_main.o lib.a -o /mayhem/fuzz_example-standalone

# 3) Build the project's TEST suite too, with NORMAL flags (independent of the sanitized build above)
#    so mayhem/test.sh only RUNS it. Put the runner where test.sh looks (EDIT). Examples:
#    cmake:    cmake -B build-tests -DCMAKE_BUILD_TYPE=Release <enable-tests> -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS" && cmake --build build-tests -j"$MAYHEM_JOBS" --target <test-target>
#    autotools/make: (env -u CFLAGS -u LDFLAGS) ./configure CFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS" && make -j"$MAYHEM_JOBS" <test-binary>
#    single-file: $CC -O2 $COVERAGE_FLAGS -o /mayhem/<name>_selftest "$SRC/mayhem/<selftest>.c"
#    Append $COVERAGE_FLAGS (empty by default) so a coverage build instruments the suite; no effect otherwise.
#    If the repo has NO tests meaningful for RL, build nothing here and ship no mayhem/test.sh.

# HighFive is a header-only C++ HDF5 wrapper; the harness TU carries all HighFive code, so
# instrumenting the harness build instruments the library. System libhdf5 provides the C layer.
[ -f deps/catch2/CMakeLists.txt ] || { echo "deps/catch2 submodule missing — init it before building" >&2; exit 1; }

HDF5_CFLAGS="$(pkg-config --cflags hdf5-serial 2>/dev/null || echo -I/usr/include/hdf5/serial)"
HDF5_LIBS="$(pkg-config --libs hdf5-serial 2>/dev/null || echo '-L/usr/lib/x86_64-linux-gnu/hdf5/serial -lhdf5')"

# 1) Configure + build the upstream unit-test suite with NORMAL flags (the functional oracle for
#    test.sh). This configure step also generates include/highfive/H5Version.hpp.
cmake -B build-tests \
      -DCMAKE_BUILD_TYPE=Release \
      -DHIGHFIVE_UNIT_TESTS=On \
      -DHIGHFIVE_EXAMPLES=Off \
      -DHIGHFIVE_BUILD_DOCS=Off \
      -DHIGHFIVE_TEST_BOOST=On \
      -DCMAKE_CXX_FLAGS="$COVERAGE_FLAGS"
cmake --build build-tests -j"$MAYHEM_JOBS"

# 2) Fuzz harness (libFuzzer) — sanitized + instrumented, DWARF-3.
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE -std=c++14 \
    -I"$SRC/include" $HDF5_CFLAGS \
    "$SRC/mayhem/fuzz_parse.cpp" $HDF5_LIBS \
    -o /mayhem/fuzz_highfive

# 3) Standalone run-once reproducer (no libFuzzer runtime). Compile the driver as C first so
#    its LLVMFuzzerTestOneInput reference keeps C linkage.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -std=c++14 \
    -I"$SRC/include" $HDF5_CFLAGS \
    "$SRC/mayhem/fuzz_parse.cpp" /tmp/standalone_main.o $HDF5_LIBS \
    -o /mayhem/fuzz_highfive-standalone
