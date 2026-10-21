#!/bin/zsh
# The owner's Ceta TIFFs against RosettaSciIO and tifffile (registration step 2, sections 2 and 5): every `*Ceta.tif` under
# $MACEM_DATA/tem (default ../data), read by RosettaSciIO (`pins.py --owner`, into .build/owner-tiff, never committed) and by
# FormatoTIFF (FormatoTIFFPinsTests, the owner test), compared exactly as the public pins are. Never part of the gate; its numbers
# are cited with this log in docs/status.md, and every file read has a line in ../data/README.md.
#   owner-check.sh      prints the files read, the result line, exit 0 when every signal agrees.
# The Swift side (Tests/FormatoKitParityTests/TIFF/FormatoTIFFPinsTests.swift) reads FORMATO_OWNER_TIFF_PINS (the JSON) and
# FORMATO_OWNER_TIFF_FILES (one absolute path per line); it does not exist until step 2's Swift lane lands.
set -euo pipefail
cd "${0:A:h}/../.."
data=${MACEM_DATA:-../data}
out=$PWD/.build/owner-tiff
mkdir -p $out
find $data/tem -name '*Ceta.tif' -type f | sort > $out/files.txt
while IFS= read -r f; do print -r -- "${f:A}"; done < $out/files.txt > $out/files-abs.txt
n=$(wc -l < $out/files-abs.txt | tr -d ' ')
print "owner-check: $n files"
[[ $n -gt 0 ]] || { print "owner-check: no *Ceta.tif under $data/tem"; exit 1; }
if [[ ! -s $out/owner-pins.json || $out/owner-pins.json -ot $out/files-abs.txt && ${OWNER_REUSE_PINS:-0} == 0 ]]; then
  tr '\n' '\0' < $out/files-abs.txt | xargs -0 References/rsciio-venv/bin/python -I -B tools/step-2/pins.py --work $out --out $out/owner-pins.json --owner
fi
export FORMATO_OWNER_TIFF_PINS=$out/owner-pins.json FORMATO_OWNER_TIFF_FILES=$out/files-abs.txt
swift test -c release --filter FormatoTIFFPinsTests 2>&1 | tee $out/owner-check.log | grep -E "OwnerTIFFPins:|error|Executed .* tests" | tail -8
