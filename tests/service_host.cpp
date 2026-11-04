// Authored OS boundary for resident-service incidents. Production links
// native/discovery.cpp instead; this file never changes the host network.
#include "../native/continuum_native.h"
#include <cstdlib>
#include <cstring>
#include <string>

extern "C" int32_t ct_discover_full(ct_bytes, ct_output out, int64_t *length) {
    if (!std::getenv("CONTINUUM_DEVICE_FIXTURE")) return CT_NOT_IMPLEMENTED;
    const std::string body = "{\"provenance\":\"authored_host_fixture\",\"interfaces\":["
        "{\"name\":\"lo0\",\"address\":\"127.0.0.1\",\"netmask\":\"255.0.0.0\",\"kind\":\"ethernet\",\"up\":true}],"
        "\"candidates\":[{\"candidate_id\":\"lo0:127.0.0.1\",\"address\":\"127.0.0.1\","
        "\"interface\":\"lo0\",\"source\":\"neighbor_cache\",\"identity\":\"unverified\"}]}";
    if (!length || !out.data || out.capacity < static_cast<int64_t>(body.size())) return CT_BUFFER_TOO_SMALL;
    std::memcpy(out.data, body.data(), body.size()); *length = static_cast<int64_t>(body.size());
    return CT_OK;
}
extern "C" int32_t ct_discover_probe(ct_bytes, int64_t, ct_output, int64_t *) { return CT_REJECTED; }
extern "C" int32_t ct_host_sample(ct_output out, int64_t *length) {
    static int sample = 0;
    // A stable baseline, a changed route, two healthy intervals to rearm,
    // then a distinct transition that must not exceed the durable budget.
    const int route = sample < 2 ? 1 : sample < 5 ? 2 : 3;
    ++sample;
    const std::string body = "{\"provenance\":\"authored_host_fixture\",\"routes_known\":true,"
        "\"ipv4_default_routes\":1,\"route_signature\":\"fixture:" + std::to_string(route) +
        "\",\"counters_known\":true,\"interface_faults\":0,\"rx_bytes\":123,\"tx_bytes\":456}";
    if (!length || !out.data || out.capacity < static_cast<int64_t>(body.size())) return CT_BUFFER_TOO_SMALL;
    std::memcpy(out.data, body.data(), body.size());
    *length = static_cast<int64_t>(body.size());
    return CT_OK;
}
