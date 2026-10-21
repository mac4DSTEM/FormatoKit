# Scope

## What is read and written

The keyword header (`#KEY: value`, one `#KEY-unit` suffix per keyword), `Y` and `XY` data with one or two columns, the date and time
as RosettaSciIO parses them, the signal type (`ELS` to `EELS`, `CLS` to `CL`, `EDS` to `EDS_TEM` above 30 kV else `EDS_SEM`), and the
quantity. Text is Latin-1 by default, UTF-8 on request. Where RosettaSciIO raises, the read throws `FormatoReadError.unsupported`.

## Where it differs

A numeric keyword that does not convert stays a string in RosettaSciIO; here a bad `XPERCHAN` or `OFFSET` refuses the read. The writer
checks its `format` before it opens the file, does not rewrite a shared keyword table for an SEM signal, and names its own `creator` in the
header comment. The full list is in `docs/parity.md`.
