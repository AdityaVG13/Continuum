#include "continuum_native.h"

// Every operational entrypoint returns CT_NOT_IMPLEMENTED. These functions
// perform no I/O, allocation, privileged mutation, model call or codec work.
// TODO: validate ABI sizes, implement ownership/cancellation, and map native
// errors before linking a real adapter to Goose. Exceptions must not cross ABI.
extern "C" {
int32_t ct_meta_open(ct_bytes, ct_handle *out) { if (out) *out = 0; return CT_NOT_IMPLEMENTED; }
int32_t ct_meta_submit(ct_handle, ct_bytes, uint64_t *out) { if (out) *out = 0; return CT_NOT_IMPLEMENTED; }
int32_t ct_meta_poll(ct_handle, ct_output, int64_t *out) { if (out) *out = 0; return CT_NOT_IMPLEMENTED; }
int32_t ct_meta_cancel(ct_handle, uint64_t) { return CT_NOT_IMPLEMENTED; }
int32_t ct_meta_close(ct_handle) { return CT_NOT_IMPLEMENTED; }
int32_t ct_profile_apply(ct_bytes, ct_output, int64_t *out) { if (out) *out = 0; return CT_NOT_IMPLEMENTED; }
int32_t ct_profile_restore(ct_bytes, ct_output, int64_t *out) { if (out) *out = 0; return CT_NOT_IMPLEMENTED; }
int32_t ct_watchdog_reconcile(ct_bytes, ct_output, int64_t *out) { if (out) *out = 0; return CT_NOT_IMPLEMENTED; }
int32_t ct_observation_read(ct_bytes, ct_output, int64_t *out) { if (out) *out = 0; return CT_NOT_IMPLEMENTED; }
int32_t ct_object_submit(ct_bytes, ct_bytes, uint64_t *out) { if (out) *out = 0; return CT_NOT_IMPLEMENTED; }
int32_t ct_object_poll(uint64_t, ct_output, int64_t *out) { if (out) *out = 0; return CT_NOT_IMPLEMENTED; }
}
