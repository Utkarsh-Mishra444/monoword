#!/bin/sh
# Runs the MonowordCore unit tests (swift-testing).
# With full Xcode installed, plain `swift test` works. With only the Command Line Tools,
# the Testing framework lives in the CLT frameworks directory, which SwiftPM does not search,
# and the generated test runner then compiles to a no-op that exits 0 with zero tests run.
# These flags put that directory on the search and rpath for every module, including the runner.
set -e
cd "$(dirname "$0")/.."
# Uncommitted local extensions (Sources/*/Local, gitignored) are switched on only when present.
if [ -d Sources/MonowordApp/Local ]; then set -- -Xswiftc -DLOCAL_EXTENSIONS "$@"; fi
CLT=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
if [ -d "$CLT/Testing.framework" ] && ! xcode-select -p | grep -q Xcode.app; then
  exec swift test \
    -Xswiftc -F -Xswiftc "$CLT" \
    -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
    -Xlinker -rpath -Xlinker "$CLT" "$@"
else
  exec swift test "$@"
fi
