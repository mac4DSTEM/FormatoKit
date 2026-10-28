#!/bin/zsh
# Move parity: See README.md.
#
#   tools/step-1/move-parity/run.sh [--owner] [--scratch DIR] [--jobs N] [--reuse]
#
# Builds the same dump program (dump.swift) against SpectroKit 0.3.0 and against FormatoKit's committed HEAD, runs both on
# every file of the list, and compares the dumps byte for byte. Prints `move-parity: N files, all byte-identical` and exits 0,
# or the first differing lines of each differing file and exits 1. Reads SpectroKit only through `git archive`; never writes
# in a repository; the owner's files (--owner) are only read.
set -euo pipefail
zmodload zsh/datetime

HERE=${0:A:h}
FK=${HERE:h:h:h}                       # FormatoKit/tools/step-1/move-parity -> FormatoKit
SK_REPO=${FK:h}/SpectroKit
DATA=${MACEM_DATA:-${FK:h}/data}
RS=$FK/References/rosettasciio-049e7d70/rsciio/tests
SCRATCH=${SCRATCH:-${M3_SCRATCH:-/private/tmp/formato-move-parity}}
JOBS=6
OWNER=0
REUSE=0

# Hidden mode: both sides on one file. Called through xargs, so every worker is its own process.
if [[ ${1:-} == __one ]]; then
  stem=$2 file=$3
  for side in spectro formato; do
    start=$EPOCHREALTIME
    set +e
    "$SCRATCH/bin/$side-reader-dump" "$file" > "$SCRATCH/out/$side/$stem.txt" 2> "$SCRATCH/logs/$side/$stem.err"
    rc=$?
    set -e
    print "exit status: $rc" >> "$SCRATCH/out/$side/$stem.txt"
    printf '%.2f\n' $(( EPOCHREALTIME - start )) > "$SCRATCH/logs/$side/$stem.sec"
  done
  exit 0
fi

while (( $# )); do
  case $1 in
    --owner) OWNER=1 ;;
    --reuse) REUSE=1 ;;                # keep the extracted copies and their build cache (development only)
    --scratch) SCRATCH=$2; shift ;;
    --jobs) JOBS=$2; shift ;;
    *) print -u2 "usage: run.sh [--owner] [--scratch DIR] [--jobs N<=8] [--reuse]"; exit 2 ;;
  esac
  shift
done
(( JOBS >= 1 && JOBS <= 8 )) || { print -u2 "--jobs must be 1...8"; exit 2 }
export SCRATCH
T0=$EPOCHSECONDS

SKC=$SCRATCH/spectrokit-0.3.0          # SpectroKit 0.3.0, git archive
FKC=$SCRATCH/formatokit-head           # FormatoKit's committed HEAD, git archive
mkdir -p "$SCRATCH"

# 1. The two copies.
if (( ! REUSE )); then
  rm -rf "$SKC" "$FKC" "$SCRATCH/bin" "$SCRATCH/out" "$SCRATCH/logs" "$SCRATCH/zips"
fi
if [[ ! -f $SKC/Package.swift ]]; then
  mkdir -p "$SKC"; git -C "$SK_REPO" archive refs/tags/0.3.0 | tar -x -C "$SKC"
fi
if [[ ! -f $FKC/Package.swift ]]; then
  mkdir -p "$FKC"; git -C "$FK" archive HEAD | tar -x -C "$FKC"
fi
print "spectrokit: $(git -C "$SK_REPO" rev-parse --short refs/tags/0.3.0^{commit}) (tag 0.3.0)   formatokit: $(git -C "$FK" rev-parse --short HEAD) (HEAD)"

# 2. The dump target in each copy: the same dump.swift under two import headers.
add_target() {   # copy-dir  imports  dependencies
  local dir=$1 imports=$2 deps=$3
  mkdir -p "$dir/Sources/reader-dump"
  { print -r -- "$imports"; cat "$HERE/dump.swift" } > "$dir/Sources/reader-dump/main.swift.new"
  if cmp -s "$dir/Sources/reader-dump/main.swift.new" "$dir/Sources/reader-dump/main.swift" 2>/dev/null; then
    rm "$dir/Sources/reader-dump/main.swift.new"
  else
    mv "$dir/Sources/reader-dump/main.swift.new" "$dir/Sources/reader-dump/main.swift"
  fi
  if ! grep -q 'reader-dump' "$dir/Package.swift"; then
    cat >> "$dir/Package.swift" <<PKG

// move-parity (FormatoKit/tools/step-1/move-parity/run.sh): the dump program, added to this scratch copy only.
package.targets.append(.executableTarget(name: "reader-dump", dependencies: [$deps], path: "Sources/reader-dump",
                                         swiftSettings: [.swiftLanguageMode(.v5)]))
PKG
  fi
}
add_target "$SKC" 'import SpectroCore' '"SpectroCore"'
add_target "$FKC" $'import FormatoDM\nimport FormatoEMD\nimport FormatoCore' '"FormatoDM", "FormatoEMD", "FormatoCore"'

# 3. Release builds of the one product (no tests), side by side.
mkdir -p "$SCRATCH/bin" "$SCRATCH/logs"
build() {   # copy-dir  side
  ( cd "$1" && swift build -c release --product reader-dump ) > "$SCRATCH/logs/build-$2.log" 2>&1 && cp "$1/.build/release/reader-dump" "$SCRATCH/bin/$2-reader-dump"
}
build "$SKC" spectro & p1=$!
build "$FKC" formato & p2=$!
b1=0 b2=0
wait $p1 || b1=$?
wait $p2 || b2=$?
if (( b1 || b2 )); then
  print -u2 "build failed (spectro $b1, formato $b2); see $SCRATCH/logs/build-*.log"
  tail -n 30 "$SCRATCH/logs/build-spectro.log" "$SCRATCH/logs/build-formato.log" >&2
  exit 3
fi
print "built both in $(( EPOCHSECONDS - T0 )) s"

# libhdf5: SpectroKit 0.3.0 ships none; FormatoKit's own copy serves both.
export FORMATO_LOCAL_XCFRAMEWORKS=1
ln -sfn "$FK/dist" "$FKC/dist"   # the local XCFrameworks (tools/xcframework/build.sh)
export FORMATO_HDF5_PATH=$FK/dist/xcframeworks/FormatoLibHDF5.xcframework/macos-arm64/FormatoLibHDF5.framework/Versions/A/FormatoLibHDF5
[[ -f $FORMATO_HDF5_PATH ]] || { print -u2 "missing $FORMATO_HDF5_PATH"; exit 3 }
export MAC4DSTEM_HDF5_PATH=$FORMATO_HDF5_PATH   # the original package's side still reads its own name

# 4. The file list: label, path.
RAW=$SCRATCH/files.raw
: > "$RAW"
add() { print -r -- "$1"$'\t'"$2" >> "$RAW" }

#   every committed fixture
for f in "$FKC"/Tests/Formato*Tests/Fixtures/*.(dm3|dm4|emd)(N); do
  add "fixture/${f:h:h:t}/${f:t}" "$f"
done
#   every public RosettaSciIO DM file, and the loose emd files
while IFS= read -r -d '' f; do add "rsciio/${f#$RS/data/}" "$f"; done \
  < <(find "$RS/data/digitalmicrograph" -type f \( -iname '*.dm3' -o -iname '*.dm4' \) -print0)
while IFS= read -r -d '' f; do add "rsciio/${f#$RS/data/}" "$f"; done \
  < <(find "$RS/data/emd" -maxdepth 1 -type f -iname '*.emd' -print0)
#   the four zips, each checked against the registry before it is opened
for zip in fei_emd_files velox_EELS_EDS velox_emd_v11_elementSelection velox_emd_version11; do
  z=$RS/data/emd/$zip.zip
  sha=$(shasum -a 256 "$z" | cut -d' ' -f1)
  grep -Fq "'emd/$zip.zip' $sha" "$RS/registry.txt" || { print -u2 "$zip.zip does not match rsciio/tests/registry.txt"; exit 4 }
  mkdir -p "$SCRATCH/zips/$zip"
  [[ -n $(ls -A "$SCRATCH/zips/$zip") ]] || unzip -q -d "$SCRATCH/zips/$zip" "$z"
  while IFS= read -r -d '' f; do add "zip/$zip/${f#$SCRATCH/zips/$zip/}" "$f"; done \
    < <(find "$SCRATCH/zips/$zip" -type f \( -iname '*.emd' -o -iname '*.dm3' -o -iname '*.dm4' \) -print0)
done
#   the owner's files, read in place
if (( OWNER )); then
  for d in tem stem-edx eels; do
    [[ -d $DATA/$d ]] || continue
    while IFS= read -r -d '' f; do add "owner/${f#$DATA/}" "$f"; done \
      < <(find -L "$DATA/$d" -type f \( -iname '*.dm3' -o -iname '*.dm4' -o -iname '*.emd' \) -print0)
  done
fi
LC_ALL=C sort -t$'\t' -k1,1 "$RAW" > "$SCRATCH/files.tsv"
N=$(wc -l < "$SCRATCH/files.tsv" | tr -d ' ')
print "$N files ($(grep -c '^fixture/' "$SCRATCH/files.tsv") fixtures, $(grep -c '^rsciio/' "$SCRATCH/files.tsv") loose public, $(grep -c '^zip/' "$SCRATCH/files.tsv") from zips, $(grep -c '^owner/' "$SCRATCH/files.tsv") owner)"

# 5. Run both sides on every file. Large files (200 MB and up) one at a time, the rest JOBS at a time.
rm -rf "$SCRATCH/out" "$SCRATCH/logs/spectro" "$SCRATCH/logs/formato"
mkdir -p "$SCRATCH"/out/{spectro,formato} "$SCRATCH"/logs/{spectro,formato}
: > "$SCRATCH/stems.txt"; : > "$SCRATCH/jobs-small.0"; : > "$SCRATCH/jobs-big.0"
i=0
while IFS=$'\t' read -r label fpath_; do
  i=$(( i + 1 ))
  stem=$(printf '%04d-%s' $i "${label//[^A-Za-z0-9._-]/_}"); stem=${stem[1,150]}
  print -r -- "$stem" >> "$SCRATCH/stems.txt"
  size=$(/usr/bin/stat -f %z "$fpath_")
  if (( size >= 200000000 )); then dest=big; else dest=small; fi
  printf '%s\0%s\0' "$stem" "$fpath_" >> "$SCRATCH/jobs-$dest.0"
done < "$SCRATCH/files.tsv"
export FORMATO_HDF5_PATH MAC4DSTEM_HDF5_PATH
T1=$EPOCHSECONDS
xargs -0 -n 2 -P "$JOBS" "$HERE/run.sh" __one < "$SCRATCH/jobs-small.0"
T2=$EPOCHSECONDS
xargs -0 -n 2 -P 1 "$HERE/run.sh" __one < "$SCRATCH/jobs-big.0"
T3=$EPOCHSECONDS
print "ran both sides: small files $(( T2 - T1 )) s, large files $(( T3 - T2 )) s"

# 6. Compare.
bad=0 shown=0
while IFS= read -r stem; do
  a=$SCRATCH/out/spectro/$stem.txt b=$SCRATCH/out/formato/$stem.txt
  if [[ ! -s $a || ! -s $b ]] || ! cmp -s "$a" "$b"; then
    bad=$(( bad + 1 ))
    print "DIFFERENT: $stem"
    if [[ -s $a && -s $b ]]; then
      diff "$a" "$b" | head -n 8 | sed 's/^/    /' || true
    else
      print "    a dump is missing or empty ($a, $b)"
    fi
  fi
done < "$SCRATCH/stems.txt"

# Informational only (not in scope): stderr, the quit barrier's line names the kit.
errdiff=0
while IFS= read -r stem; do
  if ! cmp -s <(sed 's/SpectroKit:/<Kit>:/' "$SCRATCH/logs/spectro/$stem.err") <(sed 's/FormatoKit:/<Kit>:/' "$SCRATCH/logs/formato/$stem.err"); then
    errdiff=$(( errdiff + 1 )); print "stderr differs beyond the barrier line (not in scope): $stem"
  fi
done < "$SCRATCH/stems.txt"
nonzero=$(grep -L '^exit status: 0$' "$SCRATCH"/out/spectro/*.txt 2>/dev/null | wc -l | tr -d ' ')
errlines=$(cat "$SCRATCH"/out/spectro/*.txt | grep -c ': error ' || true)
lines=$(cat "$SCRATCH"/out/spectro/*.txt | wc -l | tr -d ' ')
print "dump lines per side: $lines; thrown errors printed: $errlines; processes with a non-zero exit (same on both sides if identical): $nonzero"
print "wall time: $(( EPOCHSECONDS - T0 )) s; logs and dumps in $SCRATCH"
if (( bad )); then
  print "move-parity: $bad of $N files differ"
  exit 1
fi
print "move-parity: $N files, all byte-identical"
