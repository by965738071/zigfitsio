/*
 * zigfitsio.h — C ABI for the pure-Zig zigfitsio FITS library.
 *
 * This header is the hand-maintained contract for the `zf_*` symbols exported by the
 * `zigfitsio_capi` shared library (built from `bindings/capi/`). It is the single source of
 * truth shared by C consumers and the Python (ctypes) bindings.
 *
 * Conventions
 *   - Every fallible function returns an `int` status: 0 on success, else a CFITSIO-compatible
 *     code. On error, `zf_errmsg`/`zf_last_*` describe the most recent failure on this thread.
 *   - Strings are passed as (pointer, length) pairs (NOT NUL-terminated) unless a parameter is
 *     documented as a C string (`const char*`). String getters fill a caller buffer and report
 *     the full length in `*out_len` (re-query with a larger buffer if truncated).
 *   - `zf_read_key_longstr` and similar allocate-and-return; release with `zf_free`.
 *   - Handles (`ZfFits*`, `ZfTable*`, `ZfFindings*`) are opaque. A `ZfFits` handle is not
 *     thread-safe; distinct handles are independent.
 *   - Pixel/element transfers name a runtime datatype via `ZfType`. Image flat indices and
 *     table rows are 1-based (CFITSIO style); section bounds and column indices are 0-based.
 */
#ifndef ZIGFITSIO_H
#define ZIGFITSIO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ── Opaque handles ──────────────────────────────────────────────────────────────────────── */
typedef struct ZfFits ZfFits;
typedef struct ZfTable ZfTable;
typedef struct ZfFindings ZfFindings;

/* ── Element datatype codes (ZfType) ─────────────────────────────────────────────────────── */
#define ZF_UINT8      1
#define ZF_INT8       2
#define ZF_INT16      3
#define ZF_UINT16     4
#define ZF_INT32      5
#define ZF_UINT32     6
#define ZF_INT64      7
#define ZF_UINT64     8
#define ZF_FLOAT32    9
#define ZF_FLOAT64    10
#define ZF_BOOL       11
#define ZF_BIT        12
#define ZF_STRING     13
#define ZF_COMPLEX64  14
#define ZF_COMPLEX128 15

/* ── Open modes ──────────────────────────────────────────────────────────────────────────── */
#define ZF_READONLY   0
#define ZF_READWRITE  1
#define ZF_CREATE     2

/* ── HDU kinds ───────────────────────────────────────────────────────────────────────────── */
#define ZF_HDU_PRIMARY       0
#define ZF_HDU_IMAGE         1
#define ZF_HDU_ASCII_TABLE   2
#define ZF_HDU_BINARY_TABLE  3
#define ZF_HDU_RANDOM_GROUPS 4

/* ── Table type codes (zf_create_tbl) ────────────────────────────────────────────────────── */
#define ZF_BINARY_TBL 0
#define ZF_ASCII_TBL  1

/* ── Option / scaling / column structs (must match bindings/capi/abi.zig) ────────────────── */
typedef struct {
    int      checksum_on_close;
    uint32_t max_header_blocks;
    uint32_t max_hdu_count;
    uint64_t max_naxis_product;
    uint64_t max_heap_bytes;
    uint64_t max_vla_elems;
    uint32_t max_string_value;
    uint64_t max_tile_bytes;
    uint64_t max_open_alloc;
    uint32_t max_matches;
} ZfOpenOpts;

typedef struct {
    double  bscale;
    double  bzero;
    int64_t blank;
    int     has_blank; /* 0 ⇒ no integer null sentinel */
    int     raw;       /* non-zero ⇒ expose stored values unscaled */
} ZfScaling;

typedef struct {
    int     typecode;  /* natural element ZfType */
    int64_t repeat;    /* elements per cell (bytes for 'A', bits for 'X'); -1 for VLA */
    int64_t width;     /* field byte width (binary) or text width (ASCII) */
    int     is_vla;
    int     tform_char;/* raw TFORM letter, e.g. 'J' */
    double  tscal;
    double  tzero;
    int64_t tnull;
    int     has_tnull;
} ZfColInfo;

/* ── Version & error introspection ───────────────────────────────────────────────────────── */
const char* zf_version(void);
int    zf_last_status(void);
int    zf_errmsg(uint8_t* buf, size_t buf_len, size_t* out_len);
void   zf_last_keyword(uint8_t* buf, size_t buf_len, size_t* out_len);
int64_t zf_last_byte_offset(void);
int64_t zf_last_hdu_index(void);
void   zf_free(uint8_t* ptr, size_t len);

/* ── Lifecycle ───────────────────────────────────────────────────────────────────────────── */
int  zf_open_file(const uint8_t* path, size_t path_len, int mode, const ZfOpenOpts* opts, ZfFits** out);
int  zf_create_file(const uint8_t* path, size_t path_len, const ZfOpenOpts* opts, ZfFits** out);
int  zf_open_memory(const uint8_t* buf, size_t buf_len, int mode, const ZfOpenOpts* opts, ZfFits** out);
int  zf_create_memory(const ZfOpenOpts* opts, ZfFits** out);
int  zf_open_gzip(const uint8_t* buf, size_t buf_len, const ZfOpenOpts* opts, ZfFits** out);
int  zf_flush(ZfFits* h);
int  zf_save_gzip(ZfFits* h, const uint8_t* path, size_t path_len);
int  zf_data_size(ZfFits* h, uint64_t* out);
int  zf_read_bytes(ZfFits* h, uint64_t offset, uint8_t* dst, size_t len, size_t* out_read);
/* Close a handle and free its resources. Safe to call with NULL. Any open ZfTable* views over
 * this handle are invalidated (subsequent table calls return an error, not a crash), but must
 * still be freed with zf_table_close(). Calling zf_close() twice on the same non-NULL handle is
 * undefined behavior (double free) — a freed handle is indistinguishable from a live one. */
void zf_close(ZfFits* h);

/* ── HDU navigation ──────────────────────────────────────────────────────────────────────── */
int  zf_hdu_count(ZfFits* h, long* out);
int  zf_select(ZfFits* h, long n);
int  zf_move(ZfFits* h, long delta);
int  zf_select_by_name(ZfFits* h, const uint8_t* name, size_t name_len, long extver, int has_extver);
int  zf_current_hdu(ZfFits* h, long* out);
int  zf_hdu_type(ZfFits* h, int* out);
int  zf_img_param(ZfFits* h, int* bitpix, int* naxis, long* axes, int axes_cap, int* filled);

/* ── Images ──────────────────────────────────────────────────────────────────────────────── */
int  zf_create_img(ZfFits* h, int bitpix, int naxis, const long* axes);
int  zf_resize_img(ZfFits* h, int bitpix, int naxis, const long* axes);
int  zf_read_img(ZfFits* h, int dtype, long long firstelem, long long nelem, const void* nulval, const ZfScaling* scaling, void* array);
int  zf_write_img(ZfFits* h, int dtype, long long firstelem, long long nelem, const void* nulval, const ZfScaling* scaling, const void* array);
int  zf_read_subset(ZfFits* h, int dtype, int naxis, const long* lower, const long* upper, const long* inc, long long nelem, const void* nulval, const ZfScaling* scaling, void* array);
int  zf_write_subset(ZfFits* h, int dtype, int naxis, const long* lower, const long* upper, const long* inc, long long nelem, const void* nulval, const ZfScaling* scaling, void* array);

/* ── Header ──────────────────────────────────────────────────────────────────────────────── */
int  zf_card_count(ZfFits* h, long* out);
int  zf_read_card(ZfFits* h, long index, uint8_t* buf80);
int  zf_key_exists(ZfFits* h, const uint8_t* name, size_t name_len);
int  zf_read_key_lng(ZfFits* h, const uint8_t* name, size_t name_len, long long* out);
int  zf_read_key_dbl(ZfFits* h, const uint8_t* name, size_t name_len, double* out);
int  zf_read_key_log(ZfFits* h, const uint8_t* name, size_t name_len, int* out);
int  zf_read_key_str(ZfFits* h, const uint8_t* name, size_t name_len, uint8_t* buf, size_t buf_len, size_t* out_len);
int  zf_read_key_longstr(ZfFits* h, const uint8_t* name, size_t name_len, uint8_t** out_ptr, size_t* out_len);
int  zf_key_comment(ZfFits* h, const uint8_t* name, size_t name_len, uint8_t* buf, size_t buf_len, size_t* out_len);
int  zf_write_key_lng(ZfFits* h, const uint8_t* name, size_t name_len, long long value, const uint8_t* comment, size_t comment_len);
int  zf_write_key_dbl(ZfFits* h, const uint8_t* name, size_t name_len, double value, const uint8_t* comment, size_t comment_len);
int  zf_write_key_log(ZfFits* h, const uint8_t* name, size_t name_len, int value, const uint8_t* comment, size_t comment_len);
int  zf_write_key_str(ZfFits* h, const uint8_t* name, size_t name_len, const uint8_t* value, size_t value_len, const uint8_t* comment, size_t comment_len);
int  zf_write_key_longstr(ZfFits* h, const uint8_t* name, size_t name_len, const uint8_t* value, size_t value_len, const uint8_t* comment, size_t comment_len);
int  zf_delete_key(ZfFits* h, const uint8_t* name, size_t name_len);
int  zf_rename_key(ZfFits* h, const uint8_t* old, size_t old_len, const uint8_t* neu, size_t neu_len);
int  zf_write_record(ZfFits* h, const uint8_t* card80);
int  zf_insert_record(ZfFits* h, long index, const uint8_t* card80);

/* ── HDU management ──────────────────────────────────────────────────────────────────────── */
int  zf_delete_hdu(ZfFits* h, long n);
int  zf_copy_hdu(ZfFits* h, long src_n);

/* ── Tables ──────────────────────────────────────────────────────────────────────────────── */
int  zf_create_tbl(ZfFits* h, int table_type, long long nrows, int ncols,
                   const char* const* ttype, const char* const* tform,
                   const char* const* tunit, const char* extname);
/* Like zf_create_tbl but reserves `pcount` heap bytes (PCOUNT) up front for VLA writes. */
int  zf_create_tbl_heap(ZfFits* h, int table_type, long long nrows, int ncols,
                        const char* const* ttype, const char* const* tform,
                        const char* const* tunit, const char* extname, long long pcount);
int  zf_table_open(ZfFits* h, ZfTable** out);
void zf_table_close(ZfTable* t);
int  zf_table_nrows(ZfTable* t, long long* out);
int  zf_table_ncols(ZfTable* t, int* out);
int  zf_table_colnum(ZfTable* t, const uint8_t* name, size_t name_len, int* out);
int  zf_table_col_info(ZfTable* t, int col, ZfColInfo* info);
int  zf_table_col_name(ZfTable* t, int col, uint8_t* buf, size_t buf_len, size_t* out_len);
int  zf_table_col_unit(ZfTable* t, int col, uint8_t* buf, size_t buf_len, size_t* out_len);
int  zf_read_col(ZfTable* t, int dtype, int col, long long firstrow, long long nelem, const void* nulval, void* array);
int  zf_write_col(ZfTable* t, int dtype, int col, long long firstrow, long long nelem, const void* nulval, void* array);
int  zf_read_col_str(ZfTable* t, int col, long long firstrow, long long nrows, long long width, long long stride, uint8_t* buf);
int  zf_write_col_str(ZfTable* t, int col, long long firstrow, long long nrows, long long width, long long stride, const uint8_t* buf);
int  zf_append_rows(ZfTable* t, long long n);
int  zf_insert_rows(ZfTable* t, long long before_row, long long n);
int  zf_delete_rows(ZfTable* t, long long first_row, long long n);
int  zf_insert_col(ZfTable* t, int at, const char* tform, const char* ttype);
int  zf_delete_col(ZfTable* t, int col);

/* ── Variable-length arrays ──────────────────────────────────────────────────────────────── */
int  zf_read_descript(ZfTable* t, int col, long long row, long long* out_len, long long* out_off);
int  zf_read_col_vla(ZfTable* t, int dtype, int col, long long row, long long cap, void* array, long long* out_nelem);
int  zf_write_col_vla(ZfTable* t, int dtype, int col, long long row, const void* array, long long nelem);

/* ── Data integrity ──────────────────────────────────────────────────────────────────────── */
int  zf_write_chksum(ZfFits* h);
int  zf_update_chksum_all(ZfFits* h);
int  zf_verify_chksum(ZfFits* h, int* out_checksum, int* out_datasum);
int  zf_datasum(ZfFits* h, uint64_t* out);

/* ── Structural validation ───────────────────────────────────────────────────────────────── */
int  zf_validate(ZfFits* h, ZfFindings** out);
int  zf_findings_count(ZfFindings* f, long* out);
int  zf_findings_get(ZfFindings* f, long i, int* severity, int* hdu,
                     uint8_t* kw_buf, size_t kw_len, size_t* kw_out,
                     uint8_t* msg_buf, size_t msg_len, size_t* msg_out);
void zf_findings_free(ZfFindings* f);

/* ── World Coordinate System ─────────────────────────────────────────────────────────────── */
int  zf_wcs_pix2world(ZfFits* h, int alt, double px, double py, double* out_lon, double* out_lat);
int  zf_wcs_world2pix(ZfFits* h, int alt, double lon, double lat, double* out_px, double* out_py);

/* ── Tiled-compressed image write ────────────────────────────────────────────────────────── */
int  zf_write_compressed(ZfFits* h, int dtype, int bitpix, int naxis, const long* axes,
                         const long* tile, const char* codec, const char* quantize,
                         long long zdither0, const void* pixels, long long nelem);

#ifdef __cplusplus
}
#endif

#endif /* ZIGFITSIO_H */
