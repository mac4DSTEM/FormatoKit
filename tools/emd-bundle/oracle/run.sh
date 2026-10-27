#!/bin/zsh
# Runs the first consumer's own EMD writers offline and writes Fixtures/emd-bundle/app-*.h5 (the oracle the kit's writers are
# pinned to). Nothing in the app repo is touched or built: its Core/ is exported with `git archive` at the revision below,
# beside the kits at the tags the app pins, into a scratch folder, and built there as a package of its own.
#
#   tools/emd-bundle/oracle/run.sh <scratch-dir> [<output-dir>]
#
# app: mac4DSTEM c47a2b7a (Core/ only); kits: SpectroKit 0.6.0, FormatoKit 0.3.0, DiffractoKit 0.4.0, CuboKit 0.3.0, ImagoKit 0.2.0
# (the app's Package.swift pins). SwiftPM warns that the kits' own dependency URLs conflict with the local copies: expected.
# Takes about two minutes (a release build of the app's Core and the kits). The output folder defaults to the kit's fixtures.
set -euo pipefail
# MEMORY_CAP: the command prefix that caps the run's memory (a wrapper that stops the process tree past its limit, with its
# argument separator), as an absolute path; MEMORY_CAP=none runs without a cap.
: ${MEMORY_CAP:?set MEMORY_CAP to a memory-cap command prefix, or none}
cap=(); [[ $MEMORY_CAP == none ]] || cap=(${=MEMORY_CAP})
here=${0:A:h}; suite=${here:h:h:h:h}
scratch=${1:?scratch dir}; out=${2:-${here:h:h:h}/Tests/FormatoHDF5Tests/Fixtures/emd-bundle}
mkdir -p $scratch/kits $scratch/Sources/oracle
for pin in SpectroKit:0.6.0 FormatoKit:0.3.0 DiffractoKit:0.4.0 CuboKit:0.3.0 ImagoKit:0.2.0; do
  name=${pin%%:*}; tag=${pin##*:}; mkdir -p $scratch/kits/$name
  git -C $suite/$name archive $tag | tar -x -C $scratch/kits/$name
done
mkdir -p $scratch/export && git -C $suite/mac4DSTEM archive c47a2b7a mac4DSTEM/Core | tar -x -C $scratch/export
rm -rf $scratch/Sources/DSTEMCore && mv $scratch/export/mac4DSTEM/Core $scratch/Sources/DSTEMCore
cp $here/Package.swift $scratch/Package.swift; cp $here/main.swift $scratch/Sources/oracle/main.swift
cd $scratch && swift build -c release --jobs 4
$cap .build/release/oracle $out
