#!/bin/zsh
# The owner's Velox spectrum image against RosettaSciIO: $MACEM_DATA/stem-edx/*.emd (default
# ../data), read by RosettaSciIO (`tools/velox-spectrum-image/pins.py --owner`, with O1, O4 and first_frame 100 / last_frame 200, into
# .build/owner-spectrum-image, never committed) and by VeloxSpectrumImageSignals (SpectrumImagePinsTests.testOwnerSpectrumImages),
# compared as the public pins are. Never part of the gate; its numbers are cited with this log in docs/status.md, and the
# file read has a line in ../data/README.md.
set -euo pipefail
# The memory rule (2026-10-15): the oracle runs under a memory cap (8 GB over its process tree, MEMORY_CAP below),
# with tools/dm-velox-pins/pins.py's own watchdog as a second line (macOS refuses setrlimit); the owner's inputs are under 2 GB, and the Swift
# side's arrays are sized from them (the SI's dense array is 1.6 GB).
# MEMORY_CAP: the command prefix that caps the run's memory (a wrapper that stops the process tree past its limit, with its
# argument separator), as an absolute path; MEMORY_CAP=none runs without a cap.
: ${MEMORY_CAP:?set MEMORY_CAP to a memory-cap command prefix, or none}
cap=(); [[ $MEMORY_CAP == none ]] || cap=(${=MEMORY_CAP})
cd "${0:A:h}/../.."
data=${MACEM_DATA:-../data}
out=$PWD/.build/owner-spectrum-image
mkdir -p $out
f=$(find $data/stem-edx -iname '*.emd' -type f | sort | head -1)
[[ -n $f ]] || { print -u2 "owner-check: no .emd under $data/stem-edx"; exit 1 }
print -r -- "${f:A}" > $out/file.txt
print "owner-check spectrum image: ${f:t}"
if [[ ! -s $out/owner-pins.json || ${OWNER_REUSE_PINS:-0} == 0 ]]; then
  /usr/bin/time -p $cap References/venv/bin/python -I -B tools/velox-spectrum-image/pins.py --owner "${f:A}" --out $out/owner-pins.json --options O1,O4,O11 2>&1 | grep -v WARNING
fi
export FORMATO_OWNER_SI_PINS=$out/owner-pins.json FORMATO_OWNER_SI_FILE=${f:A}
[[ -d dist/xcframeworks/FormatoLibHDF5.xcframework ]] || tools/xcframework/build.sh --local > /dev/null 2>&1
export FORMATO_LOCAL_XCFRAMEWORKS=1
export FORMATO_HDF5_PATH=${FORMATO_HDF5_PATH:-$PWD/dist/xcframeworks/FormatoLibHDF5.xcframework/macos-arm64/FormatoLibHDF5.framework/Versions/A/FormatoLibHDF5}
swift test -c release --filter SpectrumImagePinsTests.testOwnerSpectrumImages 2>&1 | tee $out/owner-check.log | grep -E "OwnerSI:|error|issue|passed after|failed after" | tail -8
