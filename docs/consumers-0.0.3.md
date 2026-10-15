# FormatoKit 0.0.3: what the consumers change

Written 2026-10-15 by FormatoKit's session, for SpectroKit's 0.4.x bump (the first consumer) and anyone else bumping from
0.0.2. Everything in `docs/consumers-0.0.1.md` and `docs/consumers-0.0.2.md` still holds.

- **Five members are public** (additive; registration step 1, A6): `VeloxSpectrumImage.streamCount`,
  `VeloxSpectrumImage.energyCalibrationAgrees`, `VeloxStreamInfo.id`, `VeloxEventStore.streamsAgreeOnCoverage`,
  `VeloxEventStore.pixelCount`. **The two flags cover every stream**: `energyCalibrationAgrees` is false when the X-ray
  segments of ANY stream's detector differ in dispersion or offset, and `streamsAgreeOnCoverage` is false when ANY stream
  ends in another frame or pixel than the first. SpectroKit 0.4.0's registered test-side stand-in checked the head stream
  only, so it reads true on files where these flags read false (`Tests/FormatoEMDTests/Fixtures/velox-flags-planted.emd`
  is one): SpectroKit drops the stand-in and its deviation note (`consumers-0.4.0.md` §7) at its bump and reads the flags.
