#ifndef CONTINUUM_NATIVE_H
#define CONTINUUM_NATIVE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* ABI v1. Byte spans are borrowed during the call only. Production adapters
 * must copy asynchronous payloads. Native callbacks must enqueue copied
 * events; Goose drains them on its own thread. Never call Goose runtime
 * entrypoints on arbitrary native threads. */
typedef struct { const uint8_t *data; int64_t len; } ct_bytes;
typedef struct { uint8_t *data; int64_t capacity; } ct_output;
typedef uint64_t ct_handle;

enum ct_status {
    CT_NOT_IMPLEMENTED = -100,
    CT_OK = 0,
    CT_PENDING = 1,
    CT_INVALID_ARGUMENT = -1,
    CT_BUFFER_TOO_SMALL = -2,
    CT_EXPIRED = -3,
    CT_REJECTED = -4,
    CT_FAILED = -5
};

/* credentials_json MUST contain references to credential sources, never
 * credentials to be placed in logs. The actual secret stays in the adapter. */
int32_t ct_meta_open(ct_bytes config_json, ct_handle *out_handle);
int32_t ct_meta_submit(ct_handle handle, ct_bytes request_json, uint64_t *out_request_id);
int32_t ct_meta_poll(ct_handle handle, ct_output result_json, int64_t *out_length);
int32_t ct_meta_cancel(ct_handle handle, uint64_t request_id);
int32_t ct_meta_close(ct_handle handle);

/* Reserved request/response boundaries for a separate owned-profile
 * service, not permission to execute arbitrary commands in-process. */
int32_t ct_profile_apply(ct_bytes admitted_request_json, ct_output receipt_json, int64_t *out_length);
int32_t ct_profile_restore(ct_bytes admitted_request_json, ct_output receipt_json, int64_t *out_length);
int32_t ct_watchdog_reconcile(ct_bytes owned_state_json, ct_output receipt_json, int64_t *out_length);
int32_t ct_observation_read(ct_bytes query_json, ct_output observation_json, int64_t *out_length);

/* Optional owned-link object delivery, separate from the Meta HTTPS adapter. */
int32_t ct_object_submit(ct_bytes manifest_json, ct_bytes object, uint64_t *out_transfer_id);
int32_t ct_object_poll(uint64_t transfer_id, ct_output receipt_json, int64_t *out_length);

#ifdef __cplusplus
}
#endif
#endif
