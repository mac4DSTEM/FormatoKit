# Contributing to FormatoKit

Thank you for your interest. FormatoKit reads electron microscopy file formats in Swift and is checked against
[RosettaSciIO](https://github.com/hyperspy/rosettasciio). Bug reports, new test files and pull requests are welcome.

## Building and testing

You need macOS 15 or later on Apple silicon and Xcode 26 or later (Swift 6.2).

```sh
swift build
swift test
```

The libhdf5 libraries the HDF5 and EMD readers need are binary targets of the package. If the release they are
downloaded from is not available to you, build them locally and point the package at them:

```sh
tools/xcframework/build.sh --local
FORMATO_LOCAL_XCFRAMEWORKS=1 swift test -c release
```

`tools/test.sh` does both steps for you and also checks the build for warnings.

## How the tests work

- Tests use [Swift Testing](https://developer.apple.com/documentation/testing) (`import Testing`, `@Test`, `#expect`),
  not XCTest.
- What a reader returns (shapes, values, axes, units, metadata) is compared bit for bit with what RosettaSciIO returns
  for the same file. The expected values are committed as fixtures next to the tests, so you can run them without
  installing Python. The scripts that write them are under `tools/`; `tools/README.md` lists each one and the pinned
  Python environment it runs in.
- If a test disagrees with RosettaSciIO, treat it as a bug in the reader. If you believe RosettaSciIO is wrong, say so in
  the pull request and show why. A test's tolerance is the one the Python package's own tests use for that function; a
  result outside it is a bug. A change that moves a fixture says why in the pull request and in the CHANGELOG:
  each moved fixture is its own commit, and the pull request has a `test:` title or one `test:` line per fixture between
  `BEGIN_COMMIT_OVERRIDE` and `END_COMMIT_OVERRIDE` in its description, which the release notes list under "Fixtures
  and tests".
- New behaviour needs a test that fails without your change and passes with it. A small file that shows the case is
  the best test data; please check you may share it.

## Pull requests

1. Open an issue first for anything larger than a fix, so we can agree on the approach.
2. Keep each pull request focused on one change.
3. Update the documentation that your change touches (the DocC pages in `Sources/<Module>/<Module>.docc` and
   `docs/parity.md` for format support).
4. Make sure `swift test` passes.

By contributing you agree that your work is licensed under GPL-3.0-only, like the rest of the package.

## Reporting issues

Use the issue templates. For a file that will not read, the most useful report is the format, the error message,
the version of FormatoKit, and (if you can share it) the file or a trimmed copy.
