#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

# EDIT: RUN the test runner that mayhem/build.sh produced, then map its output to counts.
#   ctest:        (cd build-tests && ctest) ; parse "<P> tests passed, <F> failed out of <T>"
#   gtest binary: ./build-tests/<prog> ; parse "[==========] N ... ran." / "[  PASSED  ] P" / "[ SKIPPED ] S"
#   make/minunit: ./out/<runner> ; parse its pass/fail/total
# Do NOT compile here — if the runner is absent, fail (build.sh should have produced it).

# Run the upstream Catch2 unit-test suite (built by mayhem/build.sh into build-tests/) via ctest.
[ -d "$SRC/build-tests" ] || { echo "build-tests/ missing — mayhem/build.sh must build the suite" >&2; emit_ctrf "cmake-ctest" 0 1 0; exit 1; }

# NO test is excluded — every assertion in the suite runs, but NOT concurrently. At this frozen,
# pre-2023 revision tests/unit/CMakeLists.txt calls catch_discover_tests() with no
# WORKING_DIRECTORY, so every Catch2 TEST_CASE becomes its own ctest test, all sharing one cwd — and
# dozens of them open the SAME hardcoded filename ("test.h5" in tests_high_five_easy.cpp alone backs
# 20+ TEST_CASEs; tests_high_five_base.cpp has its own repeat offenders like "h5_group_test.h5" and
# "h5tutr_dset.h5"). `ctest -j` runs them as concurrent PROCESSES, so two tests opening the same file
# race on HDF5's flock: one dies in the File(...) constructor with "Unable to lock file" (or "Not an
# HDF5 file" when HDF5_USE_FILE_LOCKING=FALSE). It is a working-directory race, not a bad assertion —
# every one of these tests passes run alone, and the full suite passes 264/264 at -j1. Trying to
# enumerate every colliding filename for a parallel+serial split (as later revisions of this file do,
# once upstream narrowed the collision to exactly two tests) is fragile at this revision; run the
# whole suite serially instead — 264 tests take ~2s, so there's no speed reason to parallelize.
out="$( (cd "$SRC/build-tests" && ctest --output-on-failure -j1 2>&1) || true )"
echo "$out" | tail -20

# ctest summary: "100% tests passed, 0 tests failed out of 264" — parse it.
# parse_ctest <output>  ->  "<failed> <total> <skipped>"; non-zero if no summary line.
parse_ctest() {
  local o="$1" s f t sk
  s="$(echo "$o" | grep -E '% tests passed, [0-9]+ tests failed out of [0-9]+' | tail -1)"
  [ -n "$s" ] || return 1
  f="$(echo "$s" | sed -E 's/.*% tests passed, ([0-9]+) tests failed out of ([0-9]+).*/\1/')"
  t="$(echo "$s" | sed -E 's/.*% tests passed, ([0-9]+) tests failed out of ([0-9]+).*/\2/')"
  sk="$(echo "$o" | grep -cE '\*\*\*Skipped' || true)"
  echo "$f $t $sk"
}
counts="$(parse_ctest "$out")" || { echo "could not parse ctest summary" >&2; emit_ctrf "cmake-ctest" 0 1 0; exit 1; }
read -r failed total skipped <<<"$counts"
passed=$(( total - failed - skipped ))

# Behavioral guard: ctest only checks exit codes, so additionally require each Catch2 runner to
# print its "All tests passed (N assertions in M test cases)" banner with a non-zero assertion
# count — a neutered binary that exits 0 silently fails this.
if [ "$failed" -eq 0 ]; then
  workdir="$(mktemp -d)"
  for bin in "$SRC"/build-tests/tests/unit/tests_high_five_base \
             "$SRC"/build-tests/tests/unit/tests_high_five_easy \
             "$SRC"/build-tests/tests/unit/tests_high_five_multi_dims \
             "$SRC"/build-tests/tests/unit/test_all_types; do
    [ -x "$bin" ] || { echo "behavioral guard: $bin missing" >&2; failed=1; break; }
    # No Catch2 filter: one binary runs its test cases SEQUENTIALLY in a single process, so the
    # filename collisions that force the serial ctest run above cannot occur here.
    if ! (cd "$workdir" && "$bin" 2>&1 | grep -qE 'All tests passed \([1-9][0-9]* assertions in [1-9][0-9]* test cases?\)'); then
      echo "behavioral guard FAILED: $bin did not report passing assertions" >&2
      failed=1
      break
    fi
  done
  rm -rf "$workdir"
fi

emit_ctrf "cmake-ctest" "$passed" "$failed" "$skipped"
