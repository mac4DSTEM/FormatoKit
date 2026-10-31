#!/bin/zsh
# FormatoKit test gate: `swift test -c release`, warning-checked.
#
# Release, as the sibling kits' gates: the manifest carries no Debug `-O` (a versioned dependency cannot carry
# unsafe flags) and Debug at -Onone is many times slower on the stream decode; a consumer builds the kit optimised itself.
#
# libhdf5: the package ships it as three binary targets (FormatoLibHDF5, FormatoLibSZ, FormatoLibAEC; tools/xcframework/build.sh). The
# release asset may not exist yet, so the gate builds them into dist/xcframeworks when missing and sets FORMATO_LOCAL_XCFRAMEWORKS
# (Package.swift then takes the local build). FORMATO_HDF5_PATH is still exported, to that framework's binary, unless already set: the
# quit-barrier probe asks the loaded image for H5atclose by that path (RTLD_NOLOAD). The consumer check proves the shipped copy is
# found with it unset.
#
# Warnings: the build must have none, with ONE named exception: in release, Swift Build reports "not stripping binary
# because it is signed" for the shipped frameworks it copies (FormatoLibHDF5, FormatoLibSZ, FormatoLibAEC; they are ad-hoc signed and
# Xcode re-signs them in an app). Only those lines are allowed; any other warning fails the gate.
#
set -euo pipefail
cd "${0:A:h}/.."
[[ -d dist/xcframeworks/FormatoLibHDF5.xcframework ]] || tools/xcframework/build.sh --local > /dev/null 2>&1
export FORMATO_LOCAL_XCFRAMEWORKS=1
export FORMATO_HDF5_PATH=${FORMATO_HDF5_PATH:-$PWD/dist/xcframeworks/FormatoLibHDF5.xcframework/macos-arm64/FormatoLibHDF5.framework/Versions/A/FormatoLibHDF5}
print -u2 "tools/test.sh: libhdf5 = $FORMATO_HDF5_PATH"
mkdir -p .build
# The public RosettaSciIO zips the pins read: each checked against the pinned clone's registry.txt, then
# unzipped into its own fresh folder under .build/rsciio-unzipped. Without References/ the pins test runs on the committed
# copy only.
refs=References/rosettasciio-049e7d70/rsciio/tests
if [[ -d $refs/data ]]; then
  rm -rf .build/rsciio-unzipped; mkdir -p .build/rsciio-unzipped/emd
  for zip in fei_emd_files.zip velox_EELS_EDS.zip velox_emd_v11_elementSelection.zip velox_emd_version11.zip; do
    want=$(sed -n "s|^'emd/$zip' \([0-9a-f]\{64\}\)\$|\1|p" $refs/registry.txt)
    have=$(shasum -a 256 $refs/data/emd/$zip | cut -d' ' -f1)
    [[ -n $want && $have == $want ]] || { print -u2 "tools/test.sh: $zip is not the registry's ($have vs $want)"; exit 1 }
    mkdir .build/rsciio-unzipped/emd/$zip && unzip -q $refs/data/emd/$zip -d .build/rsciio-unzipped/emd/$zip
  done
fi
# The public TIFF test data the TIFF pins read: each .zip and .gz checked against registry.txt,
# unpacked into .build/rsciio-tiff/tiff/<zip>/ (a .gz into a file of its own name, the name the pins use).
if [[ -d $refs/data/tiff ]]; then
  rm -rf .build/rsciio-tiff; mkdir -p .build/rsciio-tiff/tiff
  for f in $refs/data/tiff/*.zip $refs/data/tiff/*.gz; do
    b=${f:t}
    want=$(sed -n "s|^'tiff/$b' \([0-9a-f]\{64\}\)\$|\1|p" $refs/registry.txt)
    have=$(shasum -a 256 $f | cut -d' ' -f1)
    [[ -n $want && $have == $want ]] || { print -u2 "tools/test.sh: $b is not the registry's"; exit 1 }
    if [[ $b == *.zip ]]; then mkdir .build/rsciio-tiff/tiff/$b && unzip -q $f -d .build/rsciio-tiff/tiff/$b
    else gunzip -c $f > .build/rsciio-tiff/tiff/$b; fi
  done
fi
log=.build/test.log
set +e
swift test -c release "$@" 2>&1 | tee $log
rc=${pipestatus[1]}
set -e
(( rc == 0 )) || { print -u2 "tools/test.sh: swift test failed (exit $rc)"; exit $rc }
other=$(grep "warning:" $log | grep -vE "warning: not stripping binary because it is signed: .*/FormatoLib(HDF5|SZ|AEC)\.framework" || true)
if [[ -n $other ]]; then print -u2 "tools/test.sh: green, but the build warned:"; print -u2 -r -- "$other"; exit 1; fi
