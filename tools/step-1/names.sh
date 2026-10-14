#!/bin/zsh
# Gate M1 of docs/registration-step-1.md: the 121 test names that moved from SpectroKit 0.3.0 exist in FormatoKit, as
# `Class.testName`, and nothing else of those files was dropped. Reads SpectroKit only with `git show` at the tag.
#   names.sh    prints "names: 121 of 121 moved names present" and exits 0, or lists the missing ones and exits 1.
set -euo pipefail
cd "${0:A:h}/../.."
sk=../SpectroKit tag=0.3.0
moved=(
  Tests/SpectroCoreTests/DM4ExperimentTests+Spectro.swift Tests/SpectroCoreTests/DM4TagTreeTests.swift
  Tests/SpectroCoreTests/DemoEDXFixtureTests+Spectro.swift Tests/SpectroKitTests/DM4EELSSpectrumImageTests.swift
  Tests/SpectroCoreTests/VeloxEMDReaderTests.swift Tests/SpectroCoreTests/VeloxLockAndCancelTests.swift
  Tests/SpectroCoreTests/VeloxMetadataBoundTests.swift Tests/SpectroKitTests/VeloxMetadataFieldsTests.swift
  Tests/SpectroKitTests/HDF5ExitBarrierTests.swift
)
names() {   # reads Swift source on stdin, prints Class.test per test method (XCTest `class X: XCTestCase` or Swift Testing `@Test func testX` in a top-level struct/class/actor)
  /usr/bin/python3 -I -c '
import re, sys
cls = None
for line in sys.stdin:
    m = re.match(r"\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase", line)
    if m: cls = m.group(1)
    m = re.match(r"(?:@\w+(?:\([^)]*\))?\s+)*(?:final\s+)?(?:class|struct|actor)\s+(\w+)", line) or re.match(r"\s+@Suite(?:\([^)]*\))?\s+(?:final\s+)?(?:class|struct|actor)\s+(\w+)", line)   # Swift Testing suite: top level, or an indented @Suite (nested in an extension of a serialized parent)
    if m: cls = m.group(1)
    t = re.match(r"\s*(?:@\w+(?:\([^)]*\))?\s+)*func\s+(test\w*)\s*\(", line)
    if t and cls: print(cls + "." + t.group(1))
'
}
want=$(for f in $moved; do git -C $sk --no-optional-locks show $tag:$f | names; done | sort)
have=$(cat Tests/Formato*Tests/*.swift | names | sort)
missing=$(comm -23 <(print -r -- $want) <(print -r -- $have))
n=$(print -r -- $want | grep -c .)
if [[ -n $missing ]]; then print -r -- "missing:"; print -r -- $missing; exit 1; fi
print "names: $n of $n moved names present"
