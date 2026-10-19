#!/bin/zsh
# The owner's files against RosettaSciIO (registration §2): every *.dm3, *.dm4 and *.emd under $MACEM_DATA/{eels,tem,stem-edx}
# (default ../data), read by RosettaSciIO (`pins.py --owner`, into .build/owner, never committed) and by FormatoKit's
# adapters (PinsTests.testOwnerFilesAgreeWithRosettaSciIO), compared exactly as the public pins are. Never part of the gate;
# its numbers are cited with this log in docs/status.md, and every file read has a line in ../data/README.md.
#   owner-check.sh      prints the files read, the result line, exit 0 when every signal agrees.
set -euo pipefail
# The suite's memory rule (../CLAUDE.md, 2026-10-15): the oracle runs under ../tools/memcap.sh (8 GB over its process tree),
# with tools/step-1/pins.py's own watchdog as a second line (macOS refuses setrlimit); the owner's inputs are under 2 GB, and the Swift
# side's arrays are sized from them (the SI's dense array is 1.6 GB).
cd "${0:A:h}/../.."
data=${MACEM_DATA:-../data}
out=$PWD/.build/owner
mkdir -p $out
find $data/eels $data/tem $data/stem-edx \( -iname '*.dm3' -o -iname '*.dm4' -o -iname '*.emd' \) -type f | sort > $out/files.txt
while IFS= read -r f; do print -r -- "${f:A}"; done < $out/files.txt > $out/files-abs.txt
print "owner-check: $(wc -l < $out/files-abs.txt | tr -d ' ') files"
if [[ ! -s $out/owner-pins.json || $out/owner-pins.json -ot $out/files-abs.txt && ${OWNER_REUSE_PINS:-0} == 0 ]]; then
  tr '\n' '\0' < $out/files-abs.txt | xargs -0 ../tools/memcap.sh -- References/rsciio-venv/bin/python -I -B tools/step-1/pins.py --work $out --out $out/owner-pins.json --owner
fi
export FORMATO_OWNER_PINS=$out/owner-pins.json FORMATO_OWNER_FILES=$out/files-abs.txt
[[ -d dist/xcframeworks/FormatoLibHDF5.xcframework ]] || tools/xcframework/build.sh --local > /dev/null 2>&1
export FORMATO_LOCAL_XCFRAMEWORKS=1
export FORMATO_HDF5_PATH=${FORMATO_HDF5_PATH:-$PWD/dist/xcframeworks/FormatoLibHDF5.xcframework/macos-arm64/FormatoLibHDF5.framework/Versions/A/FormatoLibHDF5}
swift test -c release --filter PinsTests.testOwnerFilesAgreeWithRosettaSciIO 2>&1 | tee $out/owner-check.log | grep -E "OwnerPins:|error|Executed .* tests" | tail -8
