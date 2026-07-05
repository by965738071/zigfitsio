/**
 * The 85 `zf_*` prototypes, mirroring `bindings/c/zigfitsio.h` (and the
 * Python `lowlevel.py` `_PROTOS` table) exactly, in header order.
 *
 * ctypes → neutral mapping: handle args → "handle"; every out-scalar /
 * out-handle / byte-pair string / pixel buffer → "buf"; `char**` string
 * arrays → "cstr_arr"; lone NUL-terminated strings → "cstr"; C long → "long"
 * (the LLP64 trap — see platform.ts); `long long` → "i64"; `size_t` → "usize".
 */
import type { NativeType, Proto } from "../ffi/types.js";

function p(name: string, returns: NativeType, ...args: NativeType[]): Proto {
  return { name, returns, args };
}

export const PROTOS: readonly Proto[] = [
  // ── version & errors ──
  p("zf_version", "cstring_ret"),
  p("zf_last_status", "int"),
  p("zf_errmsg", "int", "buf", "usize", "buf"),
  p("zf_last_keyword", "void", "buf", "usize", "buf"),
  p("zf_last_byte_offset", "i64"),
  p("zf_last_hdu_index", "i64"),
  p("zf_free", "void", "handle", "usize"),
  // ── lifecycle ──
  p("zf_open_file", "int", "buf", "usize", "int", "buf", "buf"),
  p("zf_create_file", "int", "buf", "usize", "buf", "buf"),
  p("zf_open_memory", "int", "buf", "usize", "int", "buf", "buf"),
  p("zf_create_memory", "int", "buf", "buf"),
  p("zf_open_gzip", "int", "buf", "usize", "buf", "buf"),
  p("zf_flush", "int", "handle"),
  p("zf_save_gzip", "int", "handle", "buf", "usize"),
  p("zf_data_size", "int", "handle", "buf"),
  p("zf_read_bytes", "int", "handle", "u64", "buf", "usize", "buf"),
  p("zf_close", "void", "handle"),
  // ── navigation ──
  p("zf_hdu_count", "int", "handle", "buf"),
  p("zf_select", "int", "handle", "long"),
  p("zf_move", "int", "handle", "long"),
  p("zf_select_by_name", "int", "handle", "buf", "usize", "long", "int"),
  p("zf_current_hdu", "int", "handle", "buf"),
  p("zf_hdu_type", "int", "handle", "buf"),
  p("zf_img_param", "int", "handle", "buf", "buf", "buf", "int", "buf"),
  // ── images ──
  p("zf_create_img", "int", "handle", "int", "int", "buf"),
  p("zf_resize_img", "int", "handle", "int", "int", "buf"),
  p("zf_read_img", "int", "handle", "int", "i64", "i64", "buf", "buf", "buf"),
  p("zf_write_img", "int", "handle", "int", "i64", "i64", "buf", "buf", "buf"),
  p("zf_read_subset", "int", "handle", "int", "int", "buf", "buf", "buf", "i64", "buf", "buf", "buf"),
  p("zf_write_subset", "int", "handle", "int", "int", "buf", "buf", "buf", "i64", "buf", "buf", "buf"),
  // ── header ──
  p("zf_card_count", "int", "handle", "buf"),
  p("zf_read_card", "int", "handle", "long", "buf"),
  p("zf_key_exists", "int", "handle", "buf", "usize"),
  p("zf_read_key_lng", "int", "handle", "buf", "usize", "buf"),
  p("zf_read_key_dbl", "int", "handle", "buf", "usize", "buf"),
  p("zf_read_key_log", "int", "handle", "buf", "usize", "buf"),
  p("zf_read_key_str", "int", "handle", "buf", "usize", "buf", "usize", "buf"),
  p("zf_read_key_longstr", "int", "handle", "buf", "usize", "buf", "buf"),
  p("zf_key_comment", "int", "handle", "buf", "usize", "buf", "usize", "buf"),
  p("zf_write_key_lng", "int", "handle", "buf", "usize", "i64", "buf", "usize"),
  p("zf_write_key_dbl", "int", "handle", "buf", "usize", "f64", "buf", "usize"),
  p("zf_write_key_log", "int", "handle", "buf", "usize", "int", "buf", "usize"),
  p("zf_write_key_str", "int", "handle", "buf", "usize", "buf", "usize", "buf", "usize"),
  p("zf_write_key_longstr", "int", "handle", "buf", "usize", "buf", "usize", "buf", "usize"),
  p("zf_delete_key", "int", "handle", "buf", "usize"),
  p("zf_rename_key", "int", "handle", "buf", "usize", "buf", "usize"),
  p("zf_write_record", "int", "handle", "buf"),
  p("zf_insert_record", "int", "handle", "long", "buf"),
  // ── HDU management ──
  p("zf_delete_hdu", "int", "handle", "long"),
  p("zf_copy_hdu", "int", "handle", "long"),
  // ── tables ──
  p("zf_create_tbl", "int", "handle", "int", "i64", "int", "cstr_arr", "cstr_arr", "cstr_arr", "cstr"),
  p("zf_create_tbl_heap", "int", "handle", "int", "i64", "int", "cstr_arr", "cstr_arr", "cstr_arr", "cstr", "i64"),
  p("zf_table_open", "int", "handle", "buf"),
  p("zf_table_close", "void", "handle"),
  p("zf_table_nrows", "int", "handle", "buf"),
  p("zf_table_ncols", "int", "handle", "buf"),
  p("zf_table_colnum", "int", "handle", "buf", "usize", "buf"),
  p("zf_table_col_info", "int", "handle", "int", "buf"),
  p("zf_table_col_name", "int", "handle", "int", "buf", "usize", "buf"),
  p("zf_table_col_unit", "int", "handle", "int", "buf", "usize", "buf"),
  p("zf_read_col", "int", "handle", "int", "int", "i64", "i64", "buf", "buf"),
  p("zf_write_col", "int", "handle", "int", "int", "i64", "i64", "buf", "buf"),
  p("zf_read_col_str", "int", "handle", "int", "i64", "i64", "i64", "i64", "buf"),
  p("zf_write_col_str", "int", "handle", "int", "i64", "i64", "i64", "i64", "buf"),
  p("zf_append_rows", "int", "handle", "i64"),
  p("zf_insert_rows", "int", "handle", "i64", "i64"),
  p("zf_delete_rows", "int", "handle", "i64", "i64"),
  p("zf_insert_col", "int", "handle", "int", "cstr", "cstr"),
  p("zf_delete_col", "int", "handle", "int"),
  // ── VLA ──
  p("zf_read_descript", "int", "handle", "int", "i64", "buf", "buf"),
  p("zf_read_col_vla", "int", "handle", "int", "int", "i64", "i64", "buf", "buf"),
  p("zf_write_col_vla", "int", "handle", "int", "int", "i64", "buf", "i64"),
  // ── integrity ──
  p("zf_write_chksum", "int", "handle"),
  p("zf_update_chksum_all", "int", "handle"),
  p("zf_verify_chksum", "int", "handle", "buf", "buf"),
  p("zf_datasum", "int", "handle", "buf"),
  // ── validation ──
  p("zf_validate", "int", "handle", "buf"),
  p("zf_findings_count", "int", "handle", "buf"),
  p("zf_findings_get", "int", "handle", "long", "buf", "buf", "buf", "usize", "buf", "buf", "usize", "buf"),
  p("zf_findings_free", "void", "handle"),
  // ── WCS ──
  p("zf_wcs_pix2world", "int", "handle", "int", "f64", "f64", "buf", "buf"),
  p("zf_wcs_world2pix", "int", "handle", "int", "f64", "f64", "buf", "buf"),
  // ── tiled-compressed image write ──
  p("zf_write_compressed", "int", "handle", "int", "int", "int", "buf", "buf", "cstr", "cstr", "i64", "buf", "i64"),
  p("zf_write_compressed2", "int", "handle", "int", "int", "int", "buf", "buf", "cstr", "cstr", "i64", "f32", "int", "buf", "i64"),
  p("zf_write_compressed3", "int", "handle", "int", "int", "int", "buf", "buf", "cstr", "cstr", "i64", "f32", "int", "f32", "int", "buf", "i64"),
];
