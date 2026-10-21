# ``FormatoMSA``

Reads and writes the EMSA/MAS spectral data format (`.msa`, `.ems`, `.mas`, `.emsa`) as RosettaSciIO's `msa` plugin does.

## Overview

``MSAReader`` returns a ``MSASpectrum``: a float64 signal with one axis, the keywords mapped into FormatoCore's metadata (each
entry with the keyword it came from), and the keywords themselves in file order. ``MSAWriter`` writes a signal back, byte for byte as
RosettaSciIO writes it, keeping the original keywords when it is given them. The article <doc:Scope> says what is pinned and where
the module differs.

## Topics

### Reading and writing

- ``MSAReader``
- ``MSAWriter``
- ``MSASpectrum``
- ``MSAParameter``
- ``MSAValue``
- ``MSAEncoding``
- ``MSADataFormat``

### Scope

- <doc:Scope>
