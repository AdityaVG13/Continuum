// Goose FFI bridge for the WebApi transport (item 6).
//
// Goose externs arrive as (sl_u8, sl_u8, int64_t*): two pointer+length
// slices and an out-length. Those layouts are identical to ct_bytes and to
// a bounded ct_output, asserted below against the pinned toolchain's
// codegen (wrote ../.build/.../ffiprobe2.c: sl_u8{uint8_t*,int64_t}).
// The bridge copies nothing: it reframes the slices and calls through to
// native/router_web.cpp, which owns all socket and JSON work.
//
// Compile with the generated C file plus router_web.cpp:
//   cc prog.c goose_bridge.c router_web.cpp -o prog -lstdc++ -pthread
#include <stdint.h>

#include "continuum_native.h"

// The generated program is C and calls these by unmangled name, so they
// stay extern "C" even when this file is compiled by the C++ driver.
#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t *data;
    int64_t len;
} gs_slice_u8;

_Static_assert(sizeof(gs_slice_u8) == sizeof(ct_bytes),
               "goose slice layout drifted from ct_bytes");
_Static_assert(sizeof(gs_slice_u8) == 16, "slice must be ptr+len");
_Static_assert(sizeof(int64_t) == 8, "goose i64 must be 8 bytes");

// One reframe for every JSON-in/JSON-out entry point: validate the
// slices, then call through. The ct_* targets share the exact signature.
typedef int32_t (*ct_json_fn)(ct_bytes, ct_output, int64_t *);

static int32_t bridge_json(ct_json_fn fn, gs_slice_u8 req,
                           gs_slice_u8 receipt, int64_t *out_len) {
    if (!out_len || !req.data || req.len <= 0 || !receipt.data ||
        receipt.len <= 0)
        return CT_INVALID_ARGUMENT;
    ct_bytes r = {(const uint8_t *)req.data, req.len};
    ct_output o = {receipt.data, receipt.len};
    return fn(r, o, out_len);
}

int32_t ct_apply_json(gs_slice_u8 req, gs_slice_u8 receipt,
                      int64_t *out_len) {
    return bridge_json(ct_profile_apply, req, receipt, out_len);
}

int32_t ct_restore_json(gs_slice_u8 req, gs_slice_u8 receipt,
                        int64_t *out_len) {
    return bridge_json(ct_profile_restore, req, receipt, out_len);
}

int32_t ct_reconcile_json(gs_slice_u8 req, gs_slice_u8 receipt,
                          int64_t *out_len) {
    return bridge_json(ct_watchdog_reconcile, req, receipt, out_len);
}

#ifdef __cplusplus
}
#endif
