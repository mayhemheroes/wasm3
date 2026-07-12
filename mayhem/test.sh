#!/usr/bin/env bash
#
# mayhem/test.sh — RUN wasm3's upstream test suites (built by mayhem/build.sh; nothing is
# compiled here). Mirrors upstream CI (.github/workflows/tests.yml):
#   * test/run-spec-test.py               — WebAssembly core spec conformance (opam-1.1.1)
#   * test/run-spec-test.py --spec=v1.1   — spec conformance against the v1.1 suite
#   * test/run-wasi-test.py               — WASI functional apps (known-answer sha1/pattern checks)
# All three assert behavior (expected values / traps / output hashes), so a neutered
# exit(0) binary fails them. Emits a CTRF summary; exits non-zero iff failed>0.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

W3=build/wasm3
if [ ! -x "$W3" ]; then
  echo "FATAL: $W3 missing — mayhem/build.sh must build the test binary" >&2
  emit_ctrf wasm3-upstream-tests 0 1; exit 1
fi
# Behavioral precheck: the interpreter must identify itself (a no-op binary prints nothing).
if ! "$W3" --version 2>/dev/null | grep -q '^Wasm3 v'; then
  echo "FATAL: $W3 --version does not report a Wasm3 version — binary is broken/neutered" >&2
  emit_ctrf wasm3-upstream-tests 0 1; exit 1
fi

TP=0; TF=0; TS=0
run_suite() {  # run_suite <label> <cmd...>; parses the suite's stats dict for counts
  local label="$1"; shift
  local log rc=0
  log="$(mktemp)"
  echo "== running $label =="
  ( cd test && timeout 2400 "$@" ) >"$log" 2>&1 || rc=$?
  tail -12 "$log"
  local counts
  counts="$(python3 - "$log" "$rc" <<'PY'
import re, sys
t = open(sys.argv[1], errors="replace").read()
rc = int(sys.argv[2])
d = {k: int(v) for k, v in re.findall(r"'(\w+)':\s*(\d+)", t)}
if "success" in d:   # run-spec-test.py stats
    p, f, s = d["success"], d.get("failed", 0), d.get("skipped", 0)
else:                # run-wasi-test.py stats
    f = d.get("failed", 0) + d.get("crashed", 0) + d.get("timeout", 0)
    p = d.get("total_run", 0) - f
    s = 0
if rc != 0 and f == 0:
    f = 1          # suite errored without reporting (timeout/crash) — count as a failure
if rc == 0 and p == 0:
    p, f = 0, 1    # ran "clean" but 0 tests executed — not a pass
print(p, f, s)
PY
)"
  local p f s
  read -r p f s <<<"$counts"
  echo "$label: passed=$p failed=$f skipped=$s (rc=$rc)"
  TP=$((TP+p)); TF=$((TF+f)); TS=$((TS+s))
}

run_suite "spec-opam-1.1.1" python3 run-spec-test.py
run_suite "spec-v1.1"       python3 run-spec-test.py --spec=v1.1
run_suite "wasi"            python3 run-wasi-test.py

emit_ctrf wasm3-upstream-tests "$TP" "$TF" "$TS"
