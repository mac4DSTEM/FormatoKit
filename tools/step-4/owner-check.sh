#!/bin/zsh
# The owner's Velox spectrum image against RosettaSciIO (registration step 4 §2): $MACEM_DATA/stem-edx/*.emd (default
# ../data), read by RosettaSciIO (`tools/step-4/pins.py --owner`, with O1, O4 and first_frame 100 / last_frame 200, into
# .build/owner-step4, never committed) and by VeloxSpectrumImageSignals (SpectrumImagePinsTests.testOwnerSpectrumImages),
# compared as the public pins are. Never part of the gate; its numbers are cited with this log in docs/status.md, and the
# file read has a line in ../data/README.md.
set -euo pipefail
cd "${0:A:h}/../.."
data=${MACEM_DATA:-../data}
out=$PWD/.build/owner-step4
mkdir -p $out
f=$(find $data/stem-edx -iname '*.emd' -type f | sort | head -1)
[[ -n $f ]] || { print -u2 "owner-check: no .emd under $data/stem-edx"; exit 1 }
print -r -- "${f:A}" > $out/file.txt
print "owner-check step 4: ${f:t}"
if [[ ! -s $out/owner-pins.json || ${OWNER_REUSE_PINS:-0} == 0 ]]; then
  /usr/bin/time -p References/rsciio-venv/bin/python -I -B tools/step-4/pins.py --owner "${f:A}" --out $out/owner-pins.json --options O1,O4,O11 2>&1 | grep -v WARNING
fi
export FORMATO_OWNER_SI_PINS=$out/owner-pins.json FORMATO_OWNER_SI_FILE=${f:A}
export MAC4DSTEM_HDF5_PATH=${MAC4DSTEM_HDF5_PATH:-$PWD/Sources/FormatoHDF5/Resources/hdf5/libhdf5.dylib}
swift test -c release --filter SpectrumImagePinsTests.testOwnerSpectrumImages 2>&1 | tee $out/owner-check.log | grep -E "OwnerSI:|error|issue|passed after|failed after" | tail -8
