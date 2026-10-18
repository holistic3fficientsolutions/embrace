#!/bin/bash
# Embrace's non-GUI spec group (CI's `crystal spec spec/*.cr spec/table/*.cr`), compiled for the web flavour and run
# under Node's WASI: the domain behaves in the browser as on the desktop. The same toolchain as web/build.sh
# (lib/crymble-ui/bin/crymble-web setup). Run from the repository root.
#   EXPECTED   the group's example count without EXCLUDED - the run must report exactly this many, all passing (a
#              spec dropped from the build would otherwise pass unnoticed). Re-derive it with the native command.
#   control    a planted failure built the same way must be reported as one failure, or this script fails.
set -euo pipefail

EXPECTED=233
# Not domain: a lint over the repository's source files, which the WASI sandbox does not hold.
EXCLUDED=(spec/context_stack_guard_spec.cr)
CUI=lib/crymble-ui
HOME_DIR=${CRYMBLE_WASM_HOME:-$HOME/.cache/crymble-wasm}
SDK=$HOME_DIR/wasi-sdk
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail() { echo "spec-wasm.sh: FAIL - $*" >&2; exit 1; }
[ -x "$HOME_DIR/crystal/.build/crystal" ] || fail "no toolchain - run $CUI/bin/crymble-web setup"

# build NAME SPEC-FILE...: one command program running these specs -> $WORK/NAME.out.wasm
build() {
  local name=$1
  shift
  # The collector stays off, as in the page during a tick: wasm keeps locals where Boehm cannot see them, so a
  # collection mid-call frees live objects (crymble-ui's src/web/entry.cr). The group fits in memory without one.
  {
    echo "GC.disable"
    for f in "$@"; do echo "require \"./$(realpath --relative-to="$WORK" "$f")\""; done # (Crystal requires relative paths)
  } > "$WORK/$name.cr"
  local line
  line=$(env -u CRYSTAL_LIBRARY_PATH -u LIBXML_VERSION PATH="$CUI/tools/wasm/shims:$PATH" CRYSTAL_PATH="lib:$HOME_DIR/crystal/src" \
    "$HOME_DIR/crystal/.build/crystal" build --cross-compile --target wasm32-unknown-wasi -Dwithout_mt \
    "$WORK/$name.cr" -o "$WORK/$name") || fail "$name: the compile failed"
  # shellcheck disable=SC2046
  "$SDK/bin/wasm-ld" "$WORK/$name.wasm" "$HOME_DIR/lib/cpp_tag.o" -o "$WORK/$name.out.wasm" -L"$HOME_DIR/lib" \
    -L"$SDK/share/wasi-sysroot/lib/wasm32-wasi" $(echo "$line" | tr ' ' '\n' | grep -x -- '-l.*' | grep -vx -- '-lc' | sort -u) \
    -lc -lwasi-emulated-process-clocks -lwasi-emulated-mman -lwasi-emulated-signal \
    -z stack-size=8388608 --stack-first --fatal-warnings || fail "$name: the link failed"
}
run() { node --no-warnings "$CUI/tools/wasm/spec/run.mjs" command "$WORK/$1.out.wasm" 2>&1 || true; }

# shellcheck disable=SC2046
build group $(ls spec/*_spec.cr spec/table/*_spec.cr | grep -vxF "${EXCLUDED[@]/#/-e}")
out=$(run group)
echo "$out" | grep -E 'examples, |^\s+[0-9]+\) ' || echo "$out" | grep -v '^    at ' | tail -8
echo "$out" | grep -qx "$EXPECTED examples, 0 failures, 0 errors, 0 pending" ||
  fail "expected $EXPECTED examples, 0 failures (the native group's count)"

cat > "$WORK/planted_spec.cr" <<'EOF'
require "spec"
describe "the control" do
  it "fails on purpose" { (1 + 1).should eq 3 }
end
EOF
build control "$WORK/planted_spec.cr"
out=$(run control)
echo "$out" | grep -qx "1 examples, 1 failures, 0 errors, 0 pending" || fail "the planted failure was not reported"
echo "spec-wasm.sh: PASS ($EXPECTED examples in the web flavour; the planted failure reported)"
