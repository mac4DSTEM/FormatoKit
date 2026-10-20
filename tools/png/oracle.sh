#!/bin/zsh
# Runs the first consumer's own PNG text-chunk insertion (macTEM Sources/TEMCore/Data/ImageExport.swift, `PNGChunks`, at the
# revision below) offline on Fixtures/png/input.png and writes Fixtures/png/mactem-inserted.png: the oracle FormatoPNG.inserting
# is pinned to, byte for byte. The app repo is read with `git show`; nothing in it is built or changed.
#
#   tools/png/oracle.sh <scratch-dir>
set -euo pipefail
here=${0:A:h}; kit=${here:h:h}; suite=${kit:h}
rev=53f612a
scratch=${1:?scratch dir}; mkdir -p $scratch
blob=$(git -C $suite/macTEM show $rev:Sources/TEMCore/Data/ImageExport.swift)
start=$(print -r -- "$blob" | grep -n "private enum PNGChunks" | head -1 | cut -d: -f1)
{ print "import Foundation"; print "enum ImageExport {"; print -r -- "$blob" | sed -n "${start},\$p"; } > $scratch/PNGChunks.swift
cat > $scratch/main.swift <<'SWIFT'
import Foundation
let input = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
let text: [(keyword: String, value: String)] = [
    ("Title", "oracle title"), ("Software", "macTEM oracle 1.0"),
    ("Description", "{\"width\":4,\"height\":3,\"unit\":\"nm\"}"),
    ("Comment", "caf\u{E9} \u{B5}m \u{2713}"), ("Empty", "")]
guard let out = ImageExport.PNGChunks.inserting(text: text, into: input) else { fatalError("not a PNG") }
try out.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
SWIFT
sed -i '' 's/^    private enum PNGChunks/    enum PNGChunks/' $scratch/PNGChunks.swift
xcrun swiftc -O -o $scratch/oracle $scratch/PNGChunks.swift $scratch/main.swift 2>&1 | grep -v "^$" || true
$scratch/oracle $kit/Tests/FormatoCoreTests/Fixtures/png/input.png $kit/Tests/FormatoCoreTests/Fixtures/png/mactem-inserted.png
