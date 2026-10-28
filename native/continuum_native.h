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

/* ASUS QIS onboarding transport (native/asus_web.cpp), the Class B vendor
 * adapter behind src/onboarding.goose's planner. Request JSON carries
 * routing (host/port/bind_addr) and credential REFS only; staged secrets
 * resolve inside the adapter via ct_vault_fetch and never transit the
 * request, the receipt, or any log. factory_user/factory_pass fields are
 * vendor-published defaults (printed in the manual), not secrets.
 *   discover: wizard-open NVRAM read; falls back to a factory session
 *             when the unit demands one. Receipt names product, bands,
 *             SSIDs, secured bands, MaxLen_http_passwd, session_first.
 *   rotate:   chpass (wizard-open, or authenticated with hex-MD5 current
 *             credentials when session_first), proven by a fresh login
 *             with the staged credential before CT_OK.
 *   apply:    login with the staged credential, echo-current applyapp
 *             form with new SSIDs/PSK; a reply cut by the radio restart
 *             is receipted reply_cut, not failure.
 *   verify:   login + protected read; CT_OK carries authenticated:true|
 *             false so callers classify, transport errors stay CT_FAILED. */
int32_t ct_asus_discover(ct_bytes req, ct_output out, int64_t *out_len);
int32_t ct_asus_rotate(ct_bytes req, ct_output out, int64_t *out_len);
int32_t ct_asus_apply(ct_bytes req, ct_output out, int64_t *out_len);
int32_t ct_asus_verify(ct_bytes req, ct_output out, int64_t *out_len);

/* Vault seam (native/vault.cpp): the secret named by ref, written to out
 * without NUL. The env-backed implementation is a non-durable test double;
 * the macOS keychain implementation is the production one. */
int32_t ct_vault_fetch(ct_bytes ref, ct_output out, int64_t *out_len);
int32_t ct_vault_store(ct_bytes ref, ct_bytes value);
int32_t ct_vault_delete(ct_bytes ref);

// Host operations for the leap ceremony (native/host_macos.cpp on macOS).
// Same request/response JSON convention. Stage generates the admin/PSK
// pair with OS randomness, vaults both, and verifies by readback -- the
// values never enter Goose or a receipt (lengths only). Rejoin drives the
// OS Wi-Fi join (forget-then-join) and waits for a lease in the router
// prefix; iface_ip reports the interface's current IPv4 address.
//   stage req {"admin_ref":"..","psk_ref":"..","admin_len":20,
//              "psk_len":16,"reuse":true}
//   stage receipt {"staged":true,"reused":false,"admin_len":20,
//                  "psk_len":16}
//   rejoin req {"interface":"en0","ssid":"..","psk_ref":"..",
//               "prefix":"192.168.50.","wait_sec":30}
//   rejoin receipt {"joined":true,"already":false,"ip":"192.168.50.7"}
//   iface req {"interface":"en0"} -> {"ip":"192.168.50.7"}
// Extends the status space: CT_REJECTED = the OS refused (join failed,
// no lease in budget); receipts still return with CT_REJECTED so the
// caller can read "joined":false.
int32_t ct_host_stage(ct_bytes req, ct_output out, int64_t *out_len);
int32_t ct_host_rejoin(ct_bytes req, ct_output out, int64_t *out_len);
int32_t ct_host_iface_ip(ct_bytes req, ct_output out, int64_t *out_len);

#ifdef __cplusplus
}
#endif
#endif
