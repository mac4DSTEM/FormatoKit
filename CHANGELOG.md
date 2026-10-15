# Changelog

Earlier releases: `docs/consumers-0.0.1.md` to `docs/consumers-0.2.0.md` (what each tag changed for a consumer) and `docs/status.md`.

## 0.2.1

- The platform floor drops to macOS 15 and iOS 18 (was macOS 27). The bundled HDF5 2.1.1, libsz and libaec are rebuilt with
  `MACOSX_DEPLOYMENT_TARGET=15.0` (recipe and hashes in `NOTICE`); every pin and test is unchanged.
- The pure-Swift modules (FormatoCore, FormatoDM, FormatoTIFF and the empty MRC, EMPAD, MSA) build for iOS 18. FormatoHDF5 and
  FormatoEMD load the bundled macOS libhdf5 at run time, so they are macOS-only in practice.
- Measured on macOS 27 (gate, consumer check, iOS 18 builds); not run on a macOS 15 machine. An iOS app should not depend on FormatoHDF5 or
  FormatoEMD: they copy the macOS dylibs as a resource.
- CI runs on `macos-15` with Xcode 26.0 selected and fails if Swift is older than 6.2.

**Migration.** Nothing to change in code. SpectroKit and the apps may lower their declared floor to macOS 15 (apps: iOS 18) and re-pin to 0.2.1.
