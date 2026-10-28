# Provenance

Copied 2026-10-15 by FormatoKit's step-4 session, unchanged, from SpectroKit
0.4.0 at commit `9b93fb4c3478476d41b17904961548086552dc8a`, path `Tests/SpectroEDXTests/Fixtures/`, read with
`git archive` (SpectroKit's working tree was not touched). Written there by SpectroKit's
`tools/edx-stages/make_velox_streams.py` (h5py 3.16.0, NumPy 2.5.4); the truth is that generator's draw. GPL-3.0, as both
repositories.

| File | sha256 |
|---|---|
| `velox-stream-1stream-1frame.emd` | `01e89d77aee01bcf32f30fea202a920c2e67eb66eede4dd3c33503a8b668a3f4` |
| `velox-stream-1stream-3frames.emd` | `c10cc219c14ce4a25ec8074495ac5837da48e534b8a8aac38d4bf65182cd22a9` |
| `velox-stream-4streams-2frames.emd` | `ad66d2ae0261811691a86e9d6fff45c7bfa2007b3fc01a6948c898bc359ffe7c` |
| `velox-stream-axis-decoy.emd` | `656aff17b83f3a37ba8efe68b9b0a56fef5bbfffe39ec1ecb013234e18a1575c` |
| `velox-stream-axis-order.emd` | `5fb8100f76e030c83a0dd88e7df98c33ce70151e8a8b36469ce7f8ad094dae3b` |
| `velox-stream-unterminated.emd` | `3fa6b18742962da8b5381a13b02d7d387ca2a05734a7dbb551f5d7ab953a2559` |
| `velox-streams-truth.json` | `aa55353affd9061e6ee1708322058aaef74535d1c3c660042c928fb15a1f0a5d` |

RosettaSciIO 049e7d70 raises `KeyError: 'Displays'` on each `.emd` here (a version-11 spectrum-image file without a
`Displays` group); FormatoKit refuses them too. `tools/step-4/make_velox_si.py` copies their stream and image datasets
verbatim into `../sk-<case>.emd` with the metadata completed, so both readers read them.
