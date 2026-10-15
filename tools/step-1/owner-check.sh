#!/bin/zsh
# The owner's files against RosettaSciIO (registration §2): every *.dm3, *.dm4 and *.emd under $MACEM_DATA/{eels,tem,stem-edx}
# (default ../data), read by RosettaSciIO (`pins.py --owner`, into .build/owner, never committed) and by FormatoKit's
# adapters (PinsTests.testOwnerFilesAgreeWithRosettaSciIO), compared exactly as the public pins are. Never part of the gate;
# its numbers are cited with this log in docs/status.md, and every file read has a line in ../data/README.md.
#   owner-check.sh      prints the files read, the result line, exit 0 when every signal agrees.
set -euo pipefail
# The suite's memory rule (../CLAUDE.md, 2026-10-15): the Python oracle stops itself past 8 GB resident (tools/step-1/pins.py
# cap_memory, a watchdog: macOS refuses setrlimit on RLIMIT_AS / RLIMIT_DATA); the owner's inputs are under 2 GB, and the Swift
# side's arrays are sized from them (the SI's dense array is 1.6 GB).
cd "${0:A:h}/../.."
data=${MACEM_DATA:-../data}
out=$PWD/.build/owner
mkdir -p $out
find $data/eels $data/tem $data/stem-edx \( -iname '*.dm3' -o -iname '*.dm4' -o -iname '*.emd' \) -type f | sort > $out/files.txt
while IFS= read -r f; do print -r -- "${f:A}"; done < $out/files.txt > $out/files-abs.txt
print "owner-check: $(wc -l < $out/files-abs.txt | tr -d ' ') files"
if [[ ! -s $out/owner-pins.json || $out/owner-pins.json -ot $out/files-abs.txt && ${OWNER_REUSE_PINS:-0} == 0 ]]; then
  tr '\n' '\0' < $out/files-abs.txt | xargs -0 References/rsciio-venv/bin/python -I -B tools/step-1/pins.py --work $out --out $out/owner-pins.json --owner
fi
export FORMATO_OWNER_PINS=$out/owner-pins.json FORMATO_OWNER_FILES=$out/files-abs.txt
export MAC4DSTEM_HDF5_PATH=${MAC4DSTEM_HDF5_PATH:-$PWD/Sources/FormatoHDF5/Resources/hdf5/libhdf5.dylib}
swift test -c release --filter PinsTests.testOwnerFilesAgreeWithRosettaSciIO 2>&1 | tee $out/owner-check.log | grep -E "OwnerPins:|error|Executed .* tests" | tail -8
