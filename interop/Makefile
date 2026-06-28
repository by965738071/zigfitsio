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
	rm -f $(CMP)/tile_rice.fits $(CMP)/tile_gzip.fits $(CMP)/tile_hcompress.fits $(CMP)/tile_plio.fits
	fpack -C -r      -O $(CMP)/tile_rice.fits      $(CMP)/src_rice.fits
	fpack -C -g1     -O $(CMP)/tile_gzip.fits      $(CMP)/src_gzip.fits
	fpack -C -h -s 0 -O $(CMP)/tile_hcompress.fits $(CMP)/src_hcompress.fits
	fpack -C -p      -O $(CMP)/tile_plio.fits      $(CMP)/src_plio.fits
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
