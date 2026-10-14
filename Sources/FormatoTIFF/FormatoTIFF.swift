// FormatoTIFF — empty until registered (step 2, the first format lane).
//
// Planned scope: TIFF images with their microscope metadata, as RosettaSciIO's `tiff` plugin reads them: the FEI / Thermo
// Fisher `FEI_HELIOS` / `FEI_SFEG` private tags (Ceta, Velox-exported TIFF), TIA's tags, Gatan's tag 65027 (a DM tag stream,
// read with FormatoDM's tag walk), ImageJ and plain TIFF; axes and scale from the tags, metadata with provenance; read first,
// write later. Ported from macTEM's FEI and TIA metadata walker and checked against RosettaSciIO bit for bit on the owner's
// Ceta files and RosettaSciIO's own test files.
