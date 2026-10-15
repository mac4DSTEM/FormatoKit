#!/bin/zsh
# FormatoKit consumer checks (gate H1 and the public-API guard; then the README's own snippets): build tools/consumer-check (a separate package depending on
# FormatoKit by path) in DEBUG, as a consumer's Debug build does, with 0 warnings, and run it with FORMATO_HDF5_PATH
# UNSET: its Velox reads then go through the libhdf5 FormatoKit ships. Exit 0 only if every check passed.
set -euo pipefail
here=${0:A:h}
root=${here:h:h}
cd $here
unset FORMATO_HDF5_PATH
mkdir -p .build
log=.build/consumer-check-build.log
swift build -c debug > $log 2>&1 || { grep -E "error" $log | head -20 >&2; print -u2 "consumer-check: BUILD FAILED ($here/$log)"; exit 1 }
warnings=$(grep -c "warning:" $log || true)
(( warnings == 0 )) || { grep "warning:" $log | head >&2; print -u2 "consumer-check: $warnings warning(s)"; exit 1 }
bin=$(swift build -c debug --show-bin-path)
$bin/consumer-check $root/Tests

# The second consumer: the README's own Swift blocks, pasted verbatim (every non-empty line of a ```swift block must still be in
# readme/Sources/readme-check/main.swift), built in Debug with 0 warnings and run on the planted fixtures it names.
readme=$here/readme
main=$readme/Sources/readme-check/main.swift
missing=0
while IFS= read -r line; do
    [[ -z ${line//[[:space:]]/} ]] && continue
    grep -qxF -- "$line" $main || { print -u2 "consumer-check: README line not in readme-check: $line"; missing=1 }
done < <(awk '/^```swift$/{on=1; next} /^```$/{on=0} on' $root/README.md)
(( missing == 0 )) || { print -u2 "consumer-check: readme-check no longer matches README.md"; exit 1 }
cd $readme
mkdir -p .build
rlog=.build/readme-check-build.log
swift build -c debug -j 2 > $rlog 2>&1 || { grep -E "error" $rlog | head -20 >&2; print -u2 "consumer-check: README BUILD FAILED ($readme/$rlog)"; exit 1 }
rwarnings=$(grep -c "warning:" $rlog || true)
(( rwarnings == 0 )) || { grep "warning:" $rlog | head >&2; print -u2 "consumer-check: README check: $rwarnings warning(s)"; exit 1 }
$(swift build -c debug --show-bin-path)/readme-check $root/Tests
print "consumer-check: README snippets built verbatim and ran on the planted fixtures, Debug build, no warnings, libhdf5 from the package"

print "consumer-check: all passed through the public API only, Debug build, no warnings, libhdf5 from the package (FormatoKit $(git -C $root rev-parse --short HEAD))"
