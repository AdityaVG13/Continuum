// Goose slices have the same pointer+length ABI as ct_bytes/ct_output.
// Keep setup-only symbols out of the router bridge used by other roots.
#include "continuum_native.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { uint8_t *data; int64_t len; } setup_slice;
CT_STATIC_ASSERT(sizeof(setup_slice) == sizeof(ct_bytes), "Goose setup ABI drift");

int32_t ct_setup_device_open(setup_slice path, int32_t exclusive) {
    ct_bytes directory = {path.data, path.len}; return ct_device_open(directory, exclusive);
}
int32_t ct_setup_device_load(setup_slice out, int64_t *n) {
    ct_output buffer = {out.data, out.len}; return ct_device_load(buffer, n);
}
int32_t ct_setup_device_store(setup_slice data) {
    ct_bytes record = {data.data, data.len}; return ct_device_store(record);
}
int32_t ct_setup_programs_load(setup_slice out, int64_t *n) {
    ct_output buffer = {out.data, out.len}; return ct_programs_load(buffer, n);
}
int32_t ct_setup_programs_store(setup_slice data) {
    ct_bytes record = {data.data, data.len}; return ct_programs_store(record);
}
int32_t ct_setup_owner_load(setup_slice out, int64_t *n) {
    ct_output buffer = {out.data, out.len}; return ct_owner_load(buffer, n);
}
int32_t ct_setup_owner_store(setup_slice data) {
    ct_bytes record = {data.data, data.len}; return ct_owner_store(record);
}
int32_t ct_setup_program_execute(setup_slice source, setup_slice input, int64_t timeout_ms, setup_slice out, int64_t *n) {
    ct_bytes code = {source.data, source.len}, context = {input.data, input.len};
    ct_output buffer = {out.data, out.len}; return ct_program_execute(code, context, timeout_ms, buffer, n);
}
int64_t ct_setup_service_start(setup_slice path) {
    ct_bytes directory = {path.data, path.len}; return ct_tui_service_start(directory);
}
int32_t ct_setup_service_open(setup_slice path) {
    ct_bytes directory = {path.data, path.len}; return ct_service_open(directory);
}
int32_t ct_setup_service_sample(setup_slice out, int64_t *n) {
    ct_output buffer = {out.data, out.len}; return ct_host_sample(buffer, n);
}
int32_t ct_setup_service_load(setup_slice out, int64_t *n) {
    ct_output buffer = {out.data, out.len}; return ct_service_load(buffer, n);
}
int32_t ct_setup_service_store(setup_slice data, int32_t durable) {
    ct_bytes record = {data.data, data.len}; return ct_service_store(record, durable);
}
int32_t ct_setup_discover(setup_slice out, int64_t *n) {
    const uint8_t empty[] = "{}";
    ct_bytes req = {empty, 2}; ct_output buffer = {out.data, out.len};
    return ct_discover_full(req, buffer, n);
}
int32_t ct_setup_probe(setup_slice id, int64_t port, setup_slice out, int64_t *n) {
    ct_bytes candidate = {id.data, id.len}; ct_output buffer = {out.data, out.len};
    return ct_discover_probe(candidate, port, buffer, n);
}
int32_t ct_setup_draw(setup_slice text, int64_t scroll) {
    ct_bytes frame = {text.data, text.len}; return ct_tui_draw(frame, scroll);
}
int32_t ct_setup_input(setup_slice label, setup_slice initial, setup_slice out, int64_t *n) {
    ct_bytes l = {label.data, label.len}, value = {initial.data, initial.len};
    ct_output buffer = {out.data, out.len};
    return ct_tui_input(l, value, buffer, n);
}
int32_t ct_setup_secret(setup_slice label, setup_slice out, int64_t *n) {
    ct_bytes l = {label.data, label.len};
    ct_output buffer = {out.data, out.len};
    return ct_tui_secret(l, buffer, n);
}
// Store an owner-supplied device credential exactly where the adapter looks it
// up (the binding's ref). Production resolves this to the OS keychain; the
// modeled vault used by tests is process-scoped and inherited by the job child.
int32_t ct_setup_vault_store(setup_slice ref, setup_slice value) {
    ct_bytes r = {ref.data, ref.len}, v = {value.data, value.len};
    return ct_vault_store(r, v);
}
int32_t ct_setup_job_start(setup_slice mode) {
    ct_bytes task = {mode.data, mode.len}; return ct_tui_job_start(task);
}
int32_t ct_setup_job_poll(setup_slice out, int64_t *n) {
    ct_output buffer = {out.data, out.len}; return ct_tui_job_poll(buffer, n);
}
#ifdef __cplusplus
}
#endif
