/*
 * gen_sources.c — golden-corpus authoring tool (CFITSIO 4.6.4).
 *
 * Authors the *reference* FITS bytes that the pure-Zig `zigfitsio` library is cross-checked
 * against (the `test/golden` tree). Every committed golden is produced here by CFITSIO so bytes
 * are version-stable and reproducible (the determinism contract): no wall-clock cards are
 * written (no fits_write_date), and the checksum cards carry FIXED comments (see
 * write_chksum_deterministic) instead of CFITSIO's default timestamped ones.
 *
 * Build (see ../Makefile):
 *   cc gen_sources.c -I<cfitsio>/include -L<cfitsio>/lib -lcfitsio -o gen_sources
 * Run:
 *   ./gen_sources <golden_root>
 *
 * The compressed-tile *sources* (compress/src_*.fits) are written here as plain images; the
 * Makefile then runs `fpack` over them and renames the `.fz` outputs to compress/tile_*.fits.
 *
 * This file lives under interop/ ONLY (never under src/tools/test): the CI guards job greps
 * those three trees for C and would fail on a stray .c there.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include "fitsio.h"

/* Abort loudly on any CFITSIO error so a broken golden never gets committed silently. */
static void check(int status, const char *what) {
    if (status) {
        fprintf(stderr, "FATAL: %s: CFITSIO status %d\n", what, status);
        fits_report_error(stderr, status);
        exit(1);
    }
}

/* Build an overwrite-forcing CFITSIO path: "!<root>/<rel>". */
static void mkpath(char *buf, size_t n, const char *root, const char *rel) {
    snprintf(buf, n, "!%s/%s", root, rel);
}

/* ── 16x16 identity ramp (pixel[i] = i) sources for the tile codecs ───────────────────────
 * Decoded by the Zig consumer with a pure formula (no sidecar): out[i] == i.
 * rice/gzip/hcompress use BITPIX 32; plio needs a positive integer image, so BITPIX 16. */

#define RAMP_W 16
#define RAMP_H 16
#define RAMP_N (RAMP_W * RAMP_H)

static void gen_ramp_i32(const char *root, const char *rel) {
    char path[1024];
    mkpath(path, sizeof path, root, rel);
    int status = 0;
    fitsfile *f;
    long naxes[2] = { RAMP_W, RAMP_H };
    int data[RAMP_N];
    for (int i = 0; i < RAMP_N; i++) data[i] = i;
    fits_create_file(&f, path, &status);          check(status, "ramp_i32 create");
    fits_create_img(f, LONG_IMG, 2, naxes, &status); check(status, "ramp_i32 img");
    fits_write_img(f, TINT, 1, RAMP_N, data, &status); check(status, "ramp_i32 write");
    fits_close_file(f, &status);                  check(status, "ramp_i32 close");
}

static void gen_ramp_i16(const char *root, const char *rel) {
    char path[1024];
    mkpath(path, sizeof path, root, rel);
    int status = 0;
    fitsfile *f;
    long naxes[2] = { RAMP_W, RAMP_H };
    short data[RAMP_N];
    for (int i = 0; i < RAMP_N; i++) data[i] = (short)i;  /* 0..255, positive (PLIO-safe) */
    fits_create_file(&f, path, &status);          check(status, "ramp_i16 create");
    fits_create_img(f, SHORT_IMG, 2, naxes, &status); check(status, "ramp_i16 img");
    fits_write_img(f, TSHORT, 1, RAMP_N, data, &status); check(status, "ramp_i16 write");
    fits_close_file(f, &status);                  check(status, "ramp_i16 close");
}

/* ── 32x32 curved surface (pixel[r*32+c] = r*r + 2*c*c + r*c) for the LOSSY hcompress goldens.
 * A quadratic has nonzero curvature everywhere, so decode-side smoothing (hsmooth) visibly
 * changes pixels — a pure ramp would make the SMOOTH golden vacuous. Values max 3844 (i16-safe).
 * The committed expectations are the funpack-decoded pixel files (not a formula). */

#define CURV_W 32
#define CURV_H 32
#define CURV_N (CURV_W * CURV_H)

static void fill_curved(int *data) {
    for (int r = 0; r < CURV_H; r++)
        for (int c = 0; c < CURV_W; c++)
            data[r * CURV_W + c] = r * r + 2 * c * c + r * c;
}

static void gen_curved_i16(const char *root, const char *rel) {
    char path[1024];
    mkpath(path, sizeof path, root, rel);
    int status = 0;
    fitsfile *f;
    long naxes[2] = { CURV_W, CURV_H };
    int data[CURV_N];
    short sdata[CURV_N];
    fill_curved(data);
    for (int i = 0; i < CURV_N; i++) sdata[i] = (short)data[i];
    fits_create_file(&f, path, &status);          check(status, "curved_i16 create");
    fits_create_img(f, SHORT_IMG, 2, naxes, &status); check(status, "curved_i16 img");
    fits_write_img(f, TSHORT, 1, CURV_N, sdata, &status); check(status, "curved_i16 write");
    fits_close_file(f, &status);                  check(status, "curved_i16 close");
}

static void gen_curved_i32(const char *root, const char *rel) {
    char path[1024];
    mkpath(path, sizeof path, root, rel);
    int status = 0;
    fitsfile *f;
    long naxes[2] = { CURV_W, CURV_H };
    int data[CURV_N];
    fill_curved(data);
    fits_create_file(&f, path, &status);          check(status, "curved_i32 create");
    fits_create_img(f, LONG_IMG, 2, naxes, &status); check(status, "curved_i32 img");
    fits_write_img(f, TINT, 1, CURV_N, data, &status); check(status, "curved_i32 write");
    fits_close_file(f, &status);                  check(status, "curved_i32 close");
}

/* compress/tile_hcompress_lossy32.fits and compress/tile_hcompress_smooth.fits — HCOMPRESS_1
 * with ABSOLUTE scale 16 (fits_set_hcomp_scale(-16): negative = absolute, so no data-dependent
 * noise estimation enters the committed bytes) over the curved i32 source, 32x16 tiles. The two
 * files differ ONLY in the recorded ZNAME2='SMOOTH'/ZVAL2 request (0 vs 1): the compressed
 * streams are identical, so any difference between their funpack decodes is purely hsmooth —
 * that non-vacuousness is asserted by the Zig golden consumer. fpack cannot set the smooth flag
 * (no CLI option), hence this API-level author. */
static void gen_hcomp_lossy(const char *root, const char *rel, int smooth) {
    char srcpath[1024], path[1024];
    /* plain (no '!' prefix) read path for the source authored earlier in this run */
    snprintf(srcpath, sizeof srcpath, "%s/%s", root, "compress/src_hcompress_lossy32.fits");
    mkpath(path, sizeof path, root, rel);
    int status = 0;
    fitsfile *in, *out;
    long tiledim[2] = { CURV_W, 16 };
    fits_open_file(&in, srcpath, READONLY, &status); check(status, "hcomp_lossy open src");
    fits_create_file(&out, path, &status);           check(status, "hcomp_lossy create");
    fits_set_compression_type(out, HCOMPRESS_1, &status); check(status, "hcomp_lossy ctype");
    fits_set_tile_dim(out, 2, tiledim, &status);     check(status, "hcomp_lossy tiledim");
    fits_set_hcomp_scale(out, -16.0f, &status);      check(status, "hcomp_lossy scale");
    fits_set_hcomp_smooth(out, smooth, &status);     check(status, "hcomp_lossy smooth");
    fits_img_compress(in, out, &status);             check(status, "hcomp_lossy compress");
    fits_close_file(out, &status);                   check(status, "hcomp_lossy close out");
    fits_close_file(in, &status);                    check(status, "hcomp_lossy close in");
}

/* ── 32x32 f32 noise+gradient source for the QUANTIZED-float tile goldens ─────────────────
 * value[r*32+c] = 10.0 + (r + c)*0.5 + (u - 0.5)*8.0, u = LCG-uniform in [0,1). Deterministic
 * across platforms: the LCG is pure integer math and every FP step below is EXACT in double
 * (the sole rounding is the final cast to float), so no libm variance and no FMA-contraction
 * hazard can change the committed bytes. The gradient gives quantization a non-trivial signal;
 * the noise term drives CFITSIO's FnNoise5-based ZSCALE (q = 4) through a realistic code path.
 *
 * The +10.0 offset keeps every value strictly positive — DELIBERATE, and load-bearing for the
 * cross-platform bit-exactness of the *expected* decodes. CFITSIO fudges ZZERO to an exact
 * integer multiple of ZSCALE (fits_quantize_data's iqfactor), so a pixel reconstructing near
 * zero computes fl(s*zscale) == -zzero exactly and the final `s*zscale + zzero` becomes a
 * catastrophic cancellation whose result depends on FP contraction: an FMA-contracted CFITSIO
 * build (e.g. Homebrew arm64 clang, -ffp-contract=on) yields a 2^-53-order residual where a
 * non-contracted build (baseline x86-64, and zigfitsio/astropy) yields exactly 0.0 — observed
 * empirically with this very corpus. CFITSIO is therefore not bit-stable across its own builds
 * for near-zero reconstructions; all-positive data keeps every golden off that knife edge so
 * every reference build decodes to identical bits. */

#define NOISE_W 32
#define NOISE_H 32
#define NOISE_N (NOISE_W * NOISE_H)

static void gen_noise_f32(const char *root, const char *rel) {
    char path[1024];
    mkpath(path, sizeof path, root, rel);
    int status = 0;
    fitsfile *f;
    long naxes[2] = { NOISE_W, NOISE_H };
    float data[NOISE_N];
    unsigned int state = 12345u; /* fixed LCG seed — part of the determinism contract */
    for (int i = 0; i < NOISE_N; i++) {
        state = state * 1664525u + 1013904223u;
        double u = (double)(state >> 8) / 16777216.0; /* exact: 24-bit / 2^24 */
        int r = i / NOISE_W, c = i % NOISE_W;
        data[i] = (float)(10.0 + (double)(r + c) * 0.5 + (u - 0.5) * 8.0);
    }
    fits_create_file(&f, path, &status);          check(status, "noise_f32 create");
    fits_create_img(f, FLOAT_IMG, 2, naxes, &status); check(status, "noise_f32 img");
    fits_write_img(f, TFLOAT, 1, NOISE_N, data, &status); check(status, "noise_f32 write");
    fits_close_file(f, &status);                  check(status, "noise_f32 close");
}

/* compress/tile_hcompress_fdith.fits and compress/tile_rice_fdith.fits — the f32 noise source
 * quantized with SUBTRACTIVE_DITHER_1 (q = 4, fpack's float default) under HCOMPRESS_1 / RICE_1.
 * Authored via the API rather than `fpack -q` because fpack derives ZDITHER0 from the wall
 * clock (verified: two runs differ), which would break the committed-byte determinism contract;
 * fits_set_dither_seed(1) pins ZDITHER0 = 1. Default tiling (HCOMPRESS row-block rule → 32x16;
 * RICE row strips → 32x1) so the goldens exercise the per-tile dither-seed offsets. */
static void gen_quantized_f32(const char *root, const char *rel, int comptype) {
    char srcpath[1024], path[1024];
    snprintf(srcpath, sizeof srcpath, "%s/%s", root, "compress/src_f32.fits");
    mkpath(path, sizeof path, root, rel);
    int status = 0;
    fitsfile *in, *out;
    fits_open_file(&in, srcpath, READONLY, &status);       check(status, "quantized open src");
    fits_create_file(&out, path, &status);                 check(status, "quantized create");
    fits_set_compression_type(out, comptype, &status);     check(status, "quantized ctype");
    fits_set_quantize_method(out, SUBTRACTIVE_DITHER_1, &status); check(status, "quantized method");
    fits_set_quantize_level(out, 4.0f, &status);           check(status, "quantized level");
    fits_set_dither_seed(out, 1, &status);                 check(status, "quantized seed");
    if (comptype == HCOMPRESS_1) {
        fits_set_hcomp_scale(out, 0.0f, &status);          check(status, "quantized hscale");
        fits_set_hcomp_smooth(out, 0, &status);            check(status, "quantized hsmooth");
    }
    fits_img_compress(in, out, &status);                   check(status, "quantized compress");
    fits_close_file(out, &status);                         check(status, "quantized close out");
    fits_close_file(in, &status);                          check(status, "quantized close in");
}

/* ── Plain inbound images (X-INTEROP inbound) ─────────────────────────────────────────────*/

/* images/img_i16.fits — 8x4 i16, value[i] = i - 8 (spans zero). */
static void gen_img_i16(const char *root) {
    char path[1024];
    mkpath(path, sizeof path, root, "images/img_i16.fits");
    int status = 0;
    fitsfile *f;
    long naxes[2] = { 8, 4 };
    const int n = 8 * 4;
    short data[8 * 4];
    for (int i = 0; i < n; i++) data[i] = (short)(i - 8);
    fits_create_file(&f, path, &status);          check(status, "img_i16 create");
    fits_create_img(f, SHORT_IMG, 2, naxes, &status); check(status, "img_i16 img");
    fits_write_img(f, TSHORT, 1, n, data, &status); check(status, "img_i16 write");
    fits_close_file(f, &status);                  check(status, "img_i16 close");
}

/* images/img_f32.fits — 5x3 f32, value[i] = i*0.25, with a single IEEE-NaN null at index 7. */
static void gen_img_f32(const char *root) {
    char path[1024];
    mkpath(path, sizeof path, root, "images/img_f32.fits");
    int status = 0;
    fitsfile *f;
    long naxes[2] = { 5, 3 };
    const int n = 5 * 3;
    float data[5 * 3];
    for (int i = 0; i < n; i++) data[i] = (float)i * 0.25f;
    data[7] = NAN;  /* the null pixel */
    fits_create_file(&f, path, &status);          check(status, "img_f32 create");
    fits_create_img(f, FLOAT_IMG, 2, naxes, &status); check(status, "img_f32 img");
    /* write raw values incl. the NaN; no BLANK/scaling applied. */
    fits_write_img(f, TFLOAT, 1, n, data, &status); check(status, "img_f32 write");
    fits_close_file(f, &status);                  check(status, "img_f32 close");
}

/* tables/bintable.fits — 3-row BINTABLE: 1J INDEX, 1E FLUX, 1D DVAL, 8A NAME. */
static void gen_bintable(const char *root) {
    char path[1024];
    mkpath(path, sizeof path, root, "tables/bintable.fits");
    int status = 0;
    fitsfile *f;
    char *ttype[] = { "INDEX", "FLUX", "DVAL", "NAME" };
    char *tform[] = { "1J", "1E", "1D", "8A" };
    char *tunit[] = { "", "", "", "" };
    int    idx[3] = { 10, 20, 30 };
    float  flx[3] = { 1.5f, 2.5f, 3.5f };
    double dvl[3] = { 0.25, 0.5, 0.75 };
    char  *nam[3] = { "alpha", "beta", "gamma" };

    fits_create_file(&f, path, &status);          check(status, "bintable create");
    /* empty primary, then the BINTABLE extension. */
    long no_axes[1] = { 0 };
    fits_create_img(f, BYTE_IMG, 0, no_axes, &status); check(status, "bintable primary");
    fits_create_tbl(f, BINARY_TBL, 3, 4, ttype, tform, tunit, "DATA", &status);
    check(status, "bintable tbl");
    fits_write_col(f, TINT,    1, 1, 1, 3, idx, &status); check(status, "bintable col1");
    fits_write_col(f, TFLOAT,  2, 1, 1, 3, flx, &status); check(status, "bintable col2");
    fits_write_col(f, TDOUBLE, 3, 1, 1, 3, dvl, &status); check(status, "bintable col3");
    fits_write_col(f, TSTRING, 4, 1, 1, 3, nam, &status); check(status, "bintable col4");
    fits_close_file(f, &status);                  check(status, "bintable close");
}

/* tables/ascii.fits — 3-row ASCII TABLE: I6 ID, F12.4 FLUX, A5 NOTE. */
static void gen_ascii(const char *root) {
    char path[1024];
    mkpath(path, sizeof path, root, "tables/ascii.fits");
    int status = 0;
    fitsfile *f;
    char *ttype[] = { "ID", "FLUX", "NOTE" };
    char *tform[] = { "I6", "F12.4", "A5" };
    char *tunit[] = { "", "", "" };
    long   id[3]  = { 100, 200, 300 };
    double flx[3] = { 3.1416, 2.7183, 1.4142 };
    char  *nt[3]  = { "aaa", "bbb", "ccc" };

    fits_create_file(&f, path, &status);          check(status, "ascii create");
    long no_axes[1] = { 0 };
    fits_create_img(f, BYTE_IMG, 0, no_axes, &status); check(status, "ascii primary");
    fits_create_tbl(f, ASCII_TBL, 3, 3, ttype, tform, tunit, "DATA", &status);
    check(status, "ascii tbl");
    fits_write_col(f, TLONG,   1, 1, 1, 3, id,  &status); check(status, "ascii col1");
    fits_write_col(f, TDOUBLE, 2, 1, 1, 3, flx, &status); check(status, "ascii col2");
    fits_write_col(f, TSTRING, 3, 1, 1, 3, nt,  &status); check(status, "ascii col3");
    fits_close_file(f, &status);                  check(status, "ascii close");
}

/* ── Checksum vector (X-SUM) ──────────────────────────────────────────────────────────────
 * Write the two integrity cards CFITSIO-authoritatively but with FIXED comments, replicating
 * ffpcks's algorithm (DATASUM first, then the complemented CHECKSUM over the whole HDU with the
 * field zeroed) via the public fits_get_chksum / fits_encode_chksum. CFITSIO's own
 * fits_write_chksum embeds a wall-clock timestamp in the card *comments*, which would break the
 * committed-byte determinism contract — so we do not use it. The VALUES are identical to what
 * fits_write_chksum would compute; only the comment text is made deterministic.
 * Prints the resulting decimal DATASUM on stdout (captured into the MANIFEST). */
static unsigned long write_chksum_deterministic(fitsfile *f) {
    int status = 0;
    unsigned long datasum = 0, hdusum = 0;
    char buf[32];
    char checksum[FLEN_VALUE];

    /* Reserve both cards (fixed comments) so the header size is final before summing. */
    fits_write_key_str(f, "DATASUM",  "0", "data unit checksum", &status);
    check(status, "chksum reserve DATASUM");
    fits_write_key_str(f, "CHECKSUM", "0000000000000000", "HDU checksum", &status);
    check(status, "chksum reserve CHECKSUM");
    fits_flush_file(f, &status); check(status, "chksum flush 0");

    /* Pass 1: DATASUM over the data unit. */
    fits_get_chksum(f, &datasum, &hdusum, &status); check(status, "chksum get 1");
    snprintf(buf, sizeof buf, "%lu", datasum);
    fits_update_key_str(f, "DATASUM", buf, "data unit checksum", &status);
    check(status, "chksum set DATASUM");
    fits_flush_file(f, &status); check(status, "chksum flush 1");

    /* Pass 2: CHECKSUM as the complement of the whole-HDU sum (field currently zeroed). */
    fits_get_chksum(f, &datasum, &hdusum, &status); check(status, "chksum get 2");
    fits_encode_chksum(hdusum, 1, checksum);
    fits_update_key_str(f, "CHECKSUM", checksum, "HDU checksum", &status);
    check(status, "chksum set CHECKSUM");
    fits_flush_file(f, &status); check(status, "chksum flush 2");

    fprintf(stderr, "checksum vector: DATASUM=%lu CHECKSUM=%s\n", datasum, checksum);
    return datasum;
}

/* checksum/cfitsio_ascii_checksum.fits — a small ASCII TABLE plus deterministic integrity
 * cards. The Zig consumer recomputes DATASUM and must match this CFITSIO-authored value, and
 * checksum.verify must report .match for both cards. */
static unsigned long gen_checksum(const char *root) {
    char path[1024];
    mkpath(path, sizeof path, root, "checksum/cfitsio_ascii_checksum.fits");
    int status = 0;
    fitsfile *f;
    char *ttype[] = { "COUNT", "VALUE" };
    char *tform[] = { "I10", "E15.7" };
    char *tunit[] = { "", "" };
    long   cnt[4] = { 1, 22, 333, 4444 };
    double val[4] = { 0.5, -1.25, 100.0, 3.1415926 };

    fits_create_file(&f, path, &status);          check(status, "checksum create");
    long no_axes[1] = { 0 };
    fits_create_img(f, BYTE_IMG, 0, no_axes, &status); check(status, "checksum primary");
    fits_create_tbl(f, ASCII_TBL, 4, 2, ttype, tform, tunit, "CHKSUM", &status);
    check(status, "checksum tbl");
    fits_write_col(f, TLONG,   1, 1, 1, 4, cnt, &status); check(status, "checksum col1");
    fits_write_col(f, TDOUBLE, 2, 1, 1, 4, val, &status); check(status, "checksum col2");
    unsigned long ds = write_chksum_deterministic(f);
    fits_close_file(f, &status);                  check(status, "checksum close");
    return ds;
}

/* ── WCS (TAN) ────────────────────────────────────────────────────────────────────────────
 * wcs/wcs_tan.fits — 64x64 i16 image carrying a clean gnomonic (TAN) celestial WCS. The
 * Python sidecar (gen_wcs_refpoints.py) tabulates pixel->world via astropy.wcs; the Zig
 * consumer must match within ~1e-6. Data is a small ramp (irrelevant to WCS). */
static void gen_wcs_tan(const char *root) {
    char path[1024];
    mkpath(path, sizeof path, root, "wcs/wcs_tan.fits");
    int status = 0;
    fitsfile *f;
    long naxes[2] = { 64, 64 };
    const int n = 64 * 64;
    short *data = (short *)malloc(sizeof(short) * n);
    for (int i = 0; i < n; i++) data[i] = (short)(i % 1000);

    fits_create_file(&f, path, &status);          check(status, "wcs create");
    fits_create_img(f, SHORT_IMG, 2, naxes, &status); check(status, "wcs img");

    /* A standard FITS-WCS gnomonic projection. CRPIX is 1-based (FITS convention). */
    double crpix1 = 32.0, crpix2 = 32.0;
    double crval1 = 150.0, crval2 = 2.5;
    double cdelt1 = -0.0006, cdelt2 = 0.0006;
    fits_update_key_str(f, "CTYPE1", "RA---TAN", "gnomonic", &status);
    fits_update_key_str(f, "CTYPE2", "DEC--TAN", "gnomonic", &status);
    fits_update_key(f, TDOUBLE, "CRPIX1", &crpix1, "reference pixel", &status);
    fits_update_key(f, TDOUBLE, "CRPIX2", &crpix2, "reference pixel", &status);
    fits_update_key(f, TDOUBLE, "CRVAL1", &crval1, "RA  at reference (deg)", &status);
    fits_update_key(f, TDOUBLE, "CRVAL2", &crval2, "Dec at reference (deg)", &status);
    fits_update_key(f, TDOUBLE, "CDELT1", &cdelt1, "deg/pixel", &status);
    fits_update_key(f, TDOUBLE, "CDELT2", &cdelt2, "deg/pixel", &status);
    fits_update_key_str(f, "CUNIT1", "deg", "", &status);
    fits_update_key_str(f, "CUNIT2", "deg", "", &status);
    check(status, "wcs keys");

    fits_write_img(f, TSHORT, 1, n, data, &status); check(status, "wcs write");
    fits_close_file(f, &status);                  check(status, "wcs close");
    free(data);
}

/* ── Conformance (X-CONF) ─────────────────────────────────────────────────────────────────*/

/* conformance/valid/image.fits — a clean primary image (zero validate errors). */
static void gen_conf_valid_image(const char *root) {
    char path[1024];
    mkpath(path, sizeof path, root, "conformance/valid/image.fits");
    int status = 0;
    fitsfile *f;
    long naxes[2] = { 4, 4 };
    const int n = 16;
    short data[16];
    for (int i = 0; i < n; i++) data[i] = (short)i;
    fits_create_file(&f, path, &status);          check(status, "conf valid create");
    fits_create_img(f, SHORT_IMG, 2, naxes, &status); check(status, "conf valid img");
    fits_write_img(f, TSHORT, 1, n, data, &status); check(status, "conf valid write");
    fits_close_file(f, &status);                  check(status, "conf valid close");
}

/* conformance/malformed/blank_on_float.fits — a float (BITPIX -32) image carrying a BLANK
 * keyword, which is only meaningful for integer BITPIX (§4.4.2.5). Opens cleanly; zigfitsio's
 * validate must flag (hdu 1, .err, "BLANK"). Authored entirely by CFITSIO (no byte surgery). */
static void gen_conf_malformed_blank(const char *root) {
    char path[1024];
    mkpath(path, sizeof path, root, "conformance/malformed/blank_on_float.fits");
    int status = 0;
    fitsfile *f;
    long naxes[2] = { 4, 4 };
    const int n = 16;
    float data[16];
    for (int i = 0; i < n; i++) data[i] = (float)i * 0.5f;
    long blank = -99;
    fits_create_file(&f, path, &status);          check(status, "conf blank create");
    fits_create_img(f, FLOAT_IMG, 2, naxes, &status); check(status, "conf blank img");
    /* BLANK on a float image: the deliberate violation. */
    fits_update_key(f, TLONG, "BLANK", &blank, "illegal on float BITPIX", &status);
    check(status, "conf blank key");
    fits_write_img(f, TFLOAT, 1, n, data, &status); check(status, "conf blank write");
    fits_close_file(f, &status);                  check(status, "conf blank close");
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <golden_root>\n", argv[0]);
        return 2;
    }
    const char *root = argv[1];

    /* tile-codec sources (fpacked by the Makefile) */
    gen_ramp_i32(root, "compress/src_rice.fits");
    gen_ramp_i32(root, "compress/src_gzip.fits");
    gen_ramp_i32(root, "compress/src_hcompress.fits");
    gen_ramp_i16(root, "compress/src_plio.fits");

    /* lossy hcompress: fpack authors the i16 SMOOTH=0 golden from this source… */
    gen_curved_i16(root, "compress/src_hcompress_lossy16.fits");
    /* …and the i32 SMOOTH=0/SMOOTH=1 pair is authored here (fpack has no smooth flag). */
    gen_curved_i32(root, "compress/src_hcompress_lossy32.fits");
    gen_hcomp_lossy(root, "compress/tile_hcompress_lossy32.fits", 0);
    gen_hcomp_lossy(root, "compress/tile_hcompress_smooth.fits", 1);

    /* quantized-float tiles: the dithered pair is authored HERE (pinned ZDITHER0=1 — fpack's
     * clock-derived seed is non-deterministic); the NO_DITHER variant is fpacked (-q0 4) by
     * the Makefile from the same src_f32 source. */
    gen_noise_f32(root, "compress/src_f32.fits");
    gen_quantized_f32(root, "compress/tile_hcompress_fdith.fits", HCOMPRESS_1);
    gen_quantized_f32(root, "compress/tile_rice_fdith.fits", RICE_1);

    /* plain inbound */
    gen_img_i16(root);
    gen_img_f32(root);
    gen_bintable(root);
    gen_ascii(root);

    /* checksum vector */
    unsigned long ds = gen_checksum(root);

    /* WCS */
    gen_wcs_tan(root);

    /* conformance */
    gen_conf_valid_image(root);
    gen_conf_malformed_blank(root);

    /* Emit the authoritative DATASUM on stdout for the MANIFEST/regeneration log. */
    printf("checksum_datasum=%lu\n", ds);
    fprintf(stderr, "gen_sources: all goldens authored under %s\n", root);
    return 0;
}
