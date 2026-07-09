# interop/Makefile — author the committed golden corpus with CFITSIO 4.6.4 + fpack.
#
# `make golden` builds the CFITSIO C generator, runs it to author the reference sources, fpacks
# the tile sources with the four standard codecs, drops the intermediate uncompressed sources,
# and runs the determinism normalizer. Regenerating must produce byte-identical files (the
# determinism contract): the C generator writes no wall-clock cards and `fpack -C` suppresses
# the timestamped CHECKSUM/DATASUM cards fpack would otherwise inject.
#
# This tree (interop/) is the ONLY place C/Python generators may live — the CI `guards` job
# greps src/tools/test for C and would fail on a stray generator there.

CFITSIO_PREFIX ?= /opt/homebrew/Cellar/cfitsio/4.6.4
CC             ?= cc
PYTHON         ?= python3

GOLDEN := ../test/golden
BUILD  := build
GEN    := $(BUILD)/gen_sources
CMP    := $(GOLDEN)/compress

.PHONY: golden normalize verify clean

golden: $(GEN)
	@mkdir -p $(GOLDEN)/images $(GOLDEN)/tables $(CMP) $(GOLDEN)/wcs \
	          $(GOLDEN)/checksum $(GOLDEN)/conformance/valid $(GOLDEN)/conformance/malformed
	# 1. Author every uncompressed source + the plain/table/checksum/wcs/conformance goldens.
	./$(GEN) $(GOLDEN)
	# 2. fpack each tile source with a standard codec. -C suppresses timestamped checksum cards
	#    (determinism); -O names the output directly. fpack refuses an existing target, so clear.
	rm -f $(CMP)/tile_rice.fits $(CMP)/tile_gzip.fits $(CMP)/tile_hcompress.fits $(CMP)/tile_plio.fits \
	      $(CMP)/tile_rice_i16_blank.fits \
	      $(CMP)/tile_hcompress_lossy16.fits $(CMP)/tile_hcompress_lossy16_expected.fits \
	      $(CMP)/tile_hcompress_clip16.fits $(CMP)/tile_hcompress_clip16_expected.fits \
	      $(CMP)/tile_hcompress_lossy32_expected.fits $(CMP)/tile_hcompress_smooth_expected.fits \
	      $(CMP)/tile_hcompress_fq0.fits $(CMP)/tile_hcompress_fq0_expected.fits \
	      $(CMP)/tile_hcompress_fdith_expected.fits $(CMP)/tile_rice_fdith_expected.fits \
	      $(CMP)/tile_rice_ddith_expected.fits
	fpack -C -r      -O $(CMP)/tile_rice.fits      $(CMP)/src_rice.fits
	# integer-null tile: fpack copies the source's BLANK into the compressed header as ZBLANK.
	fpack -C -r      -O $(CMP)/tile_rice_i16_blank.fits $(CMP)/src_rice_i16_blank.fits
	fpack -C -g1     -O $(CMP)/tile_gzip.fits      $(CMP)/src_gzip.fits
	fpack -C -h -s 0 -O $(CMP)/tile_hcompress.fits $(CMP)/src_hcompress.fits
	fpack -C -p      -O $(CMP)/tile_plio.fits      $(CMP)/src_plio.fits
	# 2b. Lossy HCOMPRESS: fpack authors the i16 SMOOTH=0 golden (-s -16 = ABSOLUTE scale 16,
	#     data-independent, deterministic). The i32 SMOOTH=0/1 pair was authored by the C
	#     generator (fpack has no smooth flag). funpack (same CFITSIO) authors the expected
	#     pixel files — the authoritative decode each consumer must reproduce EXACTLY.
	fpack -C -h -s -16 -O $(CMP)/tile_hcompress_lossy16.fits $(CMP)/src_hcompress_lossy16.fits
	funpack -C -O $(CMP)/tile_hcompress_lossy16_expected.fits $(CMP)/tile_hcompress_lossy16.fits
	# 2b'. CLIP golden: absolute scale 800 over the boundary-value plateau source makes the
	#      reconstruction overshoot 32767; funpack CLIPS to the i16 range (CFITSIO treats lossy
	#      HCOMPRESS overflow as expected) — the expectation pins that clamp-not-reject contract.
	fpack -C -h -s -800 -O $(CMP)/tile_hcompress_clip16.fits $(CMP)/src_hcompress_clip16.fits
	funpack -C -O $(CMP)/tile_hcompress_clip16_expected.fits $(CMP)/tile_hcompress_clip16.fits
	funpack -C -O $(CMP)/tile_hcompress_lossy32_expected.fits $(CMP)/tile_hcompress_lossy32.fits
	funpack -C -O $(CMP)/tile_hcompress_smooth_expected.fits  $(CMP)/tile_hcompress_smooth.fits
	# 2c. Quantized-float tiles over the f32 noise source. NO_DITHER (-q0) is seed-free, so
	#     fpack authors it deterministically; the SUBTRACTIVE_DITHER_1 pair was authored by
	#     the C generator (fpack's ZDITHER0 is clock-derived — non-deterministic). funpack
	#     (same CFITSIO) authors every expected pixel file, dequantization included.
	fpack -C -h -q0 4 -O $(CMP)/tile_hcompress_fq0.fits $(CMP)/src_f32.fits
	funpack -C -O $(CMP)/tile_hcompress_fq0_expected.fits   $(CMP)/tile_hcompress_fq0.fits
	funpack -C -O $(CMP)/tile_hcompress_fdith_expected.fits $(CMP)/tile_hcompress_fdith.fits
	funpack -C -O $(CMP)/tile_rice_fdith_expected.fits      $(CMP)/tile_rice_fdith.fits
	# 2d. Quantized-DOUBLE tile (BITPIX=-64): dithered, authored by the C generator (pinned
	#     ZDITHER0), decoded by funpack at full f64 width. Pins the double-precision
	#     dequantization path (hunt 2026-07-06 item 41: an f32 funnel corrupted every pixel).
	funpack -C -O $(CMP)/tile_rice_ddith_expected.fits      $(CMP)/tile_rice_ddith.fits
	# 3. The intermediate uncompressed sources are not committed — only the .fz tiles are.
	rm -f $(CMP)/src_*.fits
	# 4. Determinism normalizer (defensive: strips any DATE / timestamped comment a tool injects).
	$(MAKE) normalize
	@echo "golden corpus generated under $(GOLDEN)"

# Prefer pkg-config (resolves both Homebrew cfitsio and Debian/Ubuntu libcfitsio-dev); fall back
# to the $(CFITSIO_PREFIX) layout when no .pc file is installed.
CFITSIO_CFLAGS ?= $(shell pkg-config --cflags cfitsio 2>/dev/null || echo -I$(CFITSIO_PREFIX)/include)
CFITSIO_LIBS   ?= $(shell pkg-config --libs cfitsio 2>/dev/null || echo -L$(CFITSIO_PREFIX)/lib -lcfitsio)

$(GEN): c/gen_sources.c
	@mkdir -p $(BUILD)
	$(CC) c/gen_sources.c $(CFITSIO_CFLAGS) $(CFITSIO_LIBS) -o $(GEN)

# Strip wall-clock cards (DATE) and timestamp text from any committed golden, in place, so the
# bytes are reproducible. A no-op on the clean pipeline above; here as a hard invariant.
normalize:
	$(PYTHON) normalize_fits.py $(GOLDEN)

# Astropy cross-check (never authors committed bytes): open every golden, verify('exception').
verify:
	$(PYTHON) verify_outbound.py $(GOLDEN)

clean:
	rm -rf $(BUILD)
	rm -f $(CMP)/src_*.fits
