#!/bin/zsh
# FormatoKit consumer check (gate H1 and the public-API guard): build tools/consumer-check (a separate package depending on
# FormatoKit by path) in DEBUG, as a consumer's Debug build does, with 0 warnings, and run it with MAC4DSTEM_HDF5_PATH
# UNSET: its Velox reads then go through the libhdf5 FormatoKit ships. Exit 0 only if every check passed.
set -euo pipefail
here=${0:A:h}
root=${here:h:h}
cd $here
unset MAC4DSTEM_HDF5_PATH
mkdir -p .build
log=.build/consumer-check-build.log
swift build -c debug > $log 2>&1 || { grep -E "error" $log | head -20 >&2; print -u2 "consumer-check: BUILD FAILED ($here/$log)"; exit 1 }
warnings=$(grep -c "warning:" $log || true)
(( warnings == 0 )) || { grep "warning:" $log | head >&2; print -u2 "consumer-check: $warnings warning(s)"; exit 1 }
bin=$(swift build -c debug --show-bin-path)
$bin/consumer-check $root/Tests
print "consumer-check: all passed through the public API only, Debug build, no warnings, libhdf5 from the package (FormatoKit $(git -C $root rev-parse --short HEAD))"
