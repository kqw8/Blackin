#!/usr/bin/env bash
#
# Run the unit tests.
#
# Background: the tests use swift-testing (import Testing), which ships with the Swift
# toolchain (including the Command Line Tools) — so full Xcode is NOT required. But on a
# CLT-only machine, `swift test` can't find Testing.framework by default, so we add its
# framework search path and rpath explicitly. Under full Xcode `swift test` works natively,
# so we skip the patch there.
#
# Usage:
#   scripts/test.sh                  # run all tests
#   scripts/test.sh --filter Foo     # pass through any swift test arguments
#
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="$(xcode-select -p 2>/dev/null || echo /Library/Developer/CommandLineTools)"
FW="$DEV/Library/Developer/Frameworks"
LIB="$DEV/Library/Developer/usr/lib"

EXTRA=()
case "$DEV" in
  *CommandLineTools*)
    if [ -d "$FW/Testing.framework" ]; then
      EXTRA=( -Xswiftc -F -Xswiftc "$FW"
              -Xlinker -F -Xlinker "$FW"
              -Xlinker -rpath -Xlinker "$FW"
              -Xlinker -rpath -Xlinker "$LIB" )
    fi
    ;;
esac

# ${EXTRA[@]+"${EXTRA[@]}"}: on macOS's stock bash 3.2, `set -u` makes expanding an empty
# array throw "unbound variable"; this form is safe for an empty array and passes through
# the elements when non-empty.
exec swift test ${EXTRA[@]+"${EXTRA[@]}"} "$@"
