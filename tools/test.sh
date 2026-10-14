#!/bin/zsh
# FormatoKit test gate: `swift test -c release`, warning-checked, with the last-green stamp.
#
# Release, as SpectroKit's and DiffractoKit's gates: the manifest carries no Debug `-O` (a versioned dependency cannot carry
# unsafe flags) and Debug at -Onone is many times slower on the stream decode; a consumer builds the kit optimised itself.
#
# libhdf5: the package ships it (Sources/FormatoHDF5/Resources/hdf5, docs/registration-step-1.md §5), so no setup is needed.
# MAC4DSTEM_HDF5_PATH is still exported, to that shipped copy, unless already set: the quit-barrier probe asks the loaded
# image for H5atclose by that path (RTLD_NOLOAD). The consumer check proves the shipped copy is found with it unset (gate H1).
#
# Warnings: the build must have none, with ONE named exception: in release, Swift Build reports "not stripping binary
# because it is signed" for each of the three shipped dylibs it copies (named by their source path, or, on a fresh build,
# by their place in the built FormatoKit_FormatoHDF5.bundle; Gate B F6) (they are ad-hoc signed and must stay byte-identical
# to mac4DSTEM's vendored files). Exactly those three lines are allowed; any other warning fails the gate.
#
# Stamp: a full run (no arguments) that passes, on a tree whose Sources/, Tests/, Package.swift and Package.resolved are
# clean and hold no untracked file, writes .build/last-green (HEAD sha, UTC time, libhdf5). Any argument or a dirty tree writes nothing and says why.
set -euo pipefail
cd "${0:A:h}/.."
export MAC4DSTEM_HDF5_PATH=${MAC4DSTEM_HDF5_PATH:-$PWD/Sources/FormatoHDF5/Resources/hdf5/libhdf5.dylib}
print -u2 "tools/test.sh: libhdf5 = $MAC4DSTEM_HDF5_PATH"
mkdir -p .build
# The public RosettaSciIO zips the pins read (registration §2): each checked against the pinned clone's registry.txt, then
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
# The public TIFF test data the step-2 pins read (registration step 2 §2): each .zip and .gz checked against registry.txt,
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
other=$(grep "warning:" $log | grep -vE "warning: not stripping binary because it is signed: .*(/Sources/FormatoHDF5/Resources/hdf5|/FormatoKit_FormatoHDF5\.bundle/Contents/Resources/hdf5)/(libhdf5\.dylib|libsz\.2\.dylib|libaec\.0\.dylib)" || true)
if [[ -n $other ]]; then print -u2 "tools/test.sh: green, but the build warned:"; print -u2 -r -- "$other"; exit 1; fi
if (( $# > 0 )); then
  print -u2 "tools/test.sh: green, but arguments were given (not a full run): no stamp"
elif [[ -n $(git status --porcelain --untracked-files=no -- Sources Tests Package.swift Package.resolved) ]]; then
  print -u2 "tools/test.sh: green, but Sources/Tests/Package files are not clean: no stamp"
elif [[ -n $(git ls-files --others --exclude-standard -- Sources Tests Package.swift Package.resolved) ]]; then
  # An untracked source or test file ran but is in no commit: the stamp would name a commit without it (CuboKit's rule).
  print -u2 "tools/test.sh: green, but untracked files under Sources/Tests ran: no stamp"
else
  print -r -- "commit $(git rev-parse HEAD)
time $(date -u +%Y-%m-%dT%H:%M:%SZ)
libhdf5 $MAC4DSTEM_HDF5_PATH" > .build/last-green
  print -u2 "tools/test.sh: stamped .build/last-green at $(git rev-parse --short HEAD)"
fi
