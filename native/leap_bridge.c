// Goose FFI bridge for the leap ceremony (src/leap.goose).
//
// Kept separate from goose_bridge.c on purpose: every root that links
// the WebApi bridge (all contract suites, the product main) would
// otherwise grow references to the ASUS + host entry points and fail to
// link without them. Roots that run the ceremony opt in by listing this
// file beside native/asus_web.cpp and a host backend
// (native/host_macos.cpp in production, tests/host_fake.cpp headless).
// Same slice discipline as goose_bridge.c: reframe, copy nothing.
#include <stdint.h>

#include "continuum_native.h"

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

typedef int32_t (*ct_json_fn)(ct_bytes, ct_output, int64_t *);

static int32_t leap_bridge(ct_json_fn fn, gs_slice_u8 req,
                           gs_slice_u8 receipt, int64_t *out_len) {
    if (!out_len || !req.data || req.len <= 0 || !receipt.data ||
        receipt.len <= 0)
        return CT_INVALID_ARGUMENT;
    ct_bytes r = {(const uint8_t *)req.data, req.len};
    ct_output o = {receipt.data, receipt.len};
    return fn(r, o, out_len);
}

int32_t ct_asus_discover_json(gs_slice_u8 req, gs_slice_u8 receipt,
                              int64_t *out_len) {
    return leap_bridge(ct_asus_discover, req, receipt, out_len);
}

int32_t ct_asus_rotate_json(gs_slice_u8 req, gs_slice_u8 receipt,
                            int64_t *out_len) {
    return leap_bridge(ct_asus_rotate, req, receipt, out_len);
}

int32_t ct_asus_apply_json(gs_slice_u8 req, gs_slice_u8 receipt,
                           int64_t *out_len) {
    return leap_bridge(ct_asus_apply, req, receipt, out_len);
}

int32_t ct_asus_verify_json(gs_slice_u8 req, gs_slice_u8 receipt,
                            int64_t *out_len) {
    return leap_bridge(ct_asus_verify, req, receipt, out_len);
}

int32_t ct_host_stage_json(gs_slice_u8 req, gs_slice_u8 receipt,
                           int64_t *out_len) {
    return leap_bridge(ct_host_stage, req, receipt, out_len);
}

int32_t ct_host_rejoin_json(gs_slice_u8 req, gs_slice_u8 receipt,
                            int64_t *out_len) {
    return leap_bridge(ct_host_rejoin, req, receipt, out_len);
}

int32_t ct_host_iface_json(gs_slice_u8 req, gs_slice_u8 receipt,
                           int64_t *out_len) {
    return leap_bridge(ct_host_iface_ip, req, receipt, out_len);
}

#ifdef __cplusplus
}
#endif
