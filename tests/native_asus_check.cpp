// ASUS onboarding transport check (C++): drives native/asus_web.cpp
// against the lab double's QIS fixture (ROUTER_WIZARD=1 or =session, fresh
// ROUTER_STATE). Staged secrets come from the env-backed test vault:
//   CONTINUUM_SECRET_TEST_ADMIN / _TEST_PSK / _TEST_ADMIN_LONG
// Usage: native_asus_check host port open|session
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "continuum_native.h"

static int failures = 0;
static void check(bool cond, const char *label) {
    std::printf("%s %s\n", cond ? "ok" : "FAIL", label);
    if (!cond) failures++;
}

static bool has(const std::string &body, const char *needle) {
    return body.find(needle) != std::string::npos;
}

static std::string call(int32_t (*fn)(ct_bytes, ct_output, int64_t *),
                        const std::string &req, int32_t &rc) {
    static uint8_t receipt[4096];
    int64_t out_len = 0;
    ct_bytes r{reinterpret_cast<const uint8_t *>(req.data()),
               (int64_t)req.size()};
    ct_output o{receipt, (int64_t)sizeof receipt};
    rc = fn(r, o, &out_len);
    if (rc != CT_OK || out_len < 0 || out_len > (int64_t)sizeof receipt)
        return "";
    return std::string(reinterpret_cast<char *>(receipt), (size_t)out_len);
}

static std::string base(const char *host, int port) {
    char b[256];
    std::snprintf(b, sizeof b, "{\"host\":\"%s\",\"port\":%d,\"bind_addr\":\"\"",
                  host, port);
    return b;
}

int main(int argc, char **argv) {
    if (argc != 4) {
        std::printf("usage: %s host port open|session\n", argv[0]);
        return 2;
    }
    const char *host = argv[1];
    int port = std::atoi(argv[2]);
    bool session = std::strcmp(argv[3], "session") == 0;
    int32_t rc = 0;

    // Malformed input fails closed before any socket opens.
    std::string bad = "{\"host\":";
    call(ct_asus_discover, bad, rc);
    check(rc == CT_INVALID_ARGUMENT, "truncated request rejected");

    // Unreachable router is a transport failure, never a phantom success.
    std::string down = base("127.0.0.1", 9) +
        ",\"factory_user\":\"admin\",\"factory_pass\":\"admin\"}";
    call(ct_asus_discover, down, rc);
    check(rc == CT_FAILED, "unreachable router fails closed");

    // Discovery: factory unit, three open bands, password cap known.
    std::string dreq = base(host, port) +
        ",\"factory_user\":\"admin\",\"factory_pass\":\"admin\"}";
    std::string d = call(ct_asus_discover, dreq, rc);
    check(rc == CT_OK, "discover returns CT_OK");
    check(has(d, "\"productid\":\"RT-TEST\""), "discover names the product");
    check(has(d, "\"max_admin_len\":16"), "discover reports the password cap");
    check(has(d, "\"bands\":[0,1,2]"), "discover lists three bands");
    check(has(d, "\"TEST_5G2\""), "discover lists factory SSIDs");
    check(has(d, "\"secured\":[]"), "factory unit has no secured band");
    check(has(d, session ? "\"session_first\":true"
                         : "\"session_first\":false"),
          "discover names the access branch");

    // The staged credential must NOT authenticate before rotation.
    std::string vreq = base(host, port) +
        ",\"admin_user\":\"admin\",\"admin_ref\":\"TEST_ADMIN\"}";
    std::string v = call(ct_asus_verify, vreq, rc);
    check(rc == CT_OK && has(v, "\"authenticated\":false"),
          "staged credential refused before rotation");

    // An over-cap staged password is refused before any write.
    std::string lreq = base(host, port) +
        ",\"admin_user\":\"admin\",\"admin_ref\":\"TEST_ADMIN_LONG\""
        ",\"factory_user\":\"admin\",\"factory_pass\":\"admin\""
        ",\"session_first\":" + (session ? "true" : "false") + "}";
    call(ct_asus_rotate, lreq, rc);
    check(rc == CT_INVALID_ARGUMENT, "over-cap password refused pre-write");

    // Rotation, proven inside the adapter by a fresh staged login.
    std::string rreq = base(host, port) +
        ",\"admin_user\":\"admin\",\"admin_ref\":\"TEST_ADMIN\""
        ",\"factory_user\":\"admin\",\"factory_pass\":\"admin\""
        ",\"session_first\":" + (session ? "true" : "false") + "}";
    std::string r = call(ct_asus_rotate, rreq, rc);
    check(rc == CT_OK, "rotate returns CT_OK");
    check(has(r, session ? "\"branch\":\"session\"" : "\"branch\":\"open\""),
          "rotate names its branch");
    check(has(r, "\"login_verified\":true"), "rotate proves the new login");

    v = call(ct_asus_verify, vreq, rc);
    check(rc == CT_OK && has(v, "\"authenticated\":true"),
          "staged credential authenticates after rotation");
    check(has(v, "\"x_setting\":\"0\""), "setup not yet applied");

    // The leap submission: rename every band, secure with the staged PSK.
    std::string areq = base(host, port) +
        ",\"admin_user\":\"admin\",\"admin_ref\":\"TEST_ADMIN\""
        ",\"psk_ref\":\"TEST_PSK\",\"ssid_stem\":\"LeapLab\"}";
    std::string a = call(ct_asus_apply, areq, rc);
    check(rc == CT_OK, "apply returns CT_OK");
    check(has(a, "\"submitted\":true"), "apply receipt submitted");
    check(has(a, "\"LeapLab_5G2\""), "apply names the new SSIDs");

    // Post-leap truth: protected read under the staged credential.
    v = call(ct_asus_verify, vreq, rc);
    check(rc == CT_OK && has(v, "\"authenticated\":true"),
          "verify authenticates post-apply");
    check(has(v, "\"x_setting\":\"1\""), "verify sees setup applied");
    check(has(v, "\"wl0_ssid\":\"LeapLab_2G\""), "verify sees the rename");

    // The factory credential is dead now; a fresh discover says so.
    call(ct_asus_discover, dreq, rc);
    check(rc == CT_REJECTED, "post-setup factory discover rejected");

    // A receipt buffer that cannot hold the answer is an explicit error.
    uint8_t tiny[8];
    int64_t out_len = 0;
    check(ct_asus_verify(
              {reinterpret_cast<const uint8_t *>(vreq.data()),
               (int64_t)vreq.size()},
              {tiny, 8}, &out_len) == CT_BUFFER_TOO_SMALL,
          "tiny receipt buffer reported");

    std::printf(failures == 0 ? "ASUS_ALL_GREEN\n" : "ASUS_RED\n");
    return failures == 0 ? 0 : 1;
}
