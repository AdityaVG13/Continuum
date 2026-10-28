// Headless host backend for Goose leap tests: the ct_host_* surface
// with no keychain and no Wi-Fi. Stage generates the credential pair
// and writes it through whichever ct_vault_* backend is linked (the
// env vault in test links), so native/asus_web.cpp resolves the same
// secrets by ref -- the values still never enter Goose or a receipt.
// Rejoin always reports a clean not-joined; iface_ip reports no
// address, which run_leap treats as "no bind hint" (loopback needs
// none). Production links native/host_macos.cpp instead; never both.
#include <cstdlib>
#include <cstring>
#include <string>

#include "../native/continuum_native.h"

namespace {

bool str_field(const std::string &j, const char *key, std::string &out) {
    std::string pat = "\"" + std::string(key) + "\":\"";
    size_t p = j.find(pat);
    if (p == std::string::npos) return false;
    size_t a = p + pat.size();
    size_t b = j.find('"', a);
    if (b == std::string::npos) return false;
    out = j.substr(a, b - a);
    return true;
}

bool int_field(const std::string &j, const char *key, long &out) {
    std::string pat = "\"" + std::string(key) + "\":";
    size_t p = j.find(pat);
    if (p == std::string::npos) return false;
    size_t a = p + pat.size();
    if (a >= j.size()) return false;
    char *end = nullptr;
    long v = std::strtol(j.c_str() + a, &end, 10);
    if (end == j.c_str() + a) return false;
    out = v;
    return true;
}

bool bool_field(const std::string &j, const char *key, bool &out) {
    std::string pat = "\"" + std::string(key) + "\":";
    size_t p = j.find(pat);
    if (p == std::string::npos) return false;
    size_t a = p + pat.size();
    if (j.compare(a, 4, "true") == 0) { out = true; return true; }
    if (j.compare(a, 5, "false") == 0) { out = false; return true; }
    return false;
}

int32_t put_receipt(ct_output out, int64_t *out_len, const std::string &s) {
    if ((int64_t)s.size() > out.capacity) return CT_BUFFER_TOO_SMALL;
    std::memcpy(out.data, s.data(), s.size());
    *out_len = (int64_t)s.size();
    return CT_OK;
}

bool fetch(const std::string &ref, std::string &value) {
    uint8_t buf[512];
    ct_output o{buf, (int64_t)sizeof buf};
    int64_t n = 0;
    ct_bytes r{(const uint8_t *)ref.data(), (int64_t)ref.size()};
    if (ct_vault_fetch(r, o, &n) != CT_OK || n <= 0) return false;
    value.assign((const char *)buf, (size_t)n);
    return true;
}

bool store(const std::string &ref, const std::string &value) {
    ct_bytes r{(const uint8_t *)ref.data(), (int64_t)ref.size()};
    ct_bytes v{(const uint8_t *)value.data(), (int64_t)value.size()};
    return ct_vault_store(r, v) == CT_OK;
}

// Same alphabet as the keychain stage: alnum minus look-alikes.
std::string generate(int len) {
    static const char kAlphabet[] =
        "ABCDEFGHJKMNPQRSTUVWXYZabcdefghjkmnpqrstuvwxyz23456789";
    std::string out;
    uint8_t buf[128];
    arc4random_buf(buf, sizeof buf);
    for (int i = 0; i < len; i++)
        out += kAlphabet[buf[i % (int)sizeof buf] % (sizeof kAlphabet - 1)];
    return out;
}

}  // namespace

extern "C" {

int32_t ct_host_stage(ct_bytes req, ct_output out, int64_t *out_len) {
    if (!out_len || !req.data || req.len <= 0 || !out.data)
        return CT_INVALID_ARGUMENT;
    std::string body((const char *)req.data, (size_t)req.len);
    std::string admin_ref, psk_ref;
    long admin_len = 0, psk_len = 0;
    bool reuse = false;
    if (!str_field(body, "admin_ref", admin_ref) ||
        !str_field(body, "psk_ref", psk_ref) ||
        !int_field(body, "admin_len", admin_len) ||
        !int_field(body, "psk_len", psk_len) ||
        !bool_field(body, "reuse", reuse))
        return CT_INVALID_ARGUMENT;
    if (admin_len < 8 || admin_len > 64 || psk_len < 8 || psk_len > 63)
        return CT_INVALID_ARGUMENT;

    std::string admin, psk;
    bool reused = reuse && fetch(admin_ref, admin) && fetch(psk_ref, psk);
    if (!reused) {
        admin = generate((int)admin_len);
        psk = generate((int)psk_len);
        if (!store(admin_ref, admin) || !store(psk_ref, psk)) {
            // A half-staged pair must not survive as a lying success.
            ct_bytes r{(const uint8_t *)admin_ref.data(),
                       (int64_t)admin_ref.size()};
            ct_vault_delete(r);
            return CT_FAILED;
        }
        std::string back_admin, back_psk;
        if (!fetch(admin_ref, back_admin) || back_admin != admin ||
            !fetch(psk_ref, back_psk) || back_psk != psk)
            return CT_FAILED;
    }
    std::string receipt = "{\"staged\":true,\"reused\":";
    receipt += reused ? "true" : "false";
    receipt += ",\"admin_len\":" + std::to_string(admin.size());
    receipt += ",\"psk_len\":" + std::to_string(psk.size()) + "}";
    return put_receipt(out, out_len, receipt);
}

int32_t ct_host_rejoin(ct_bytes, ct_output out, int64_t *out_len) {
    if (!out_len || !out.data) return CT_INVALID_ARGUMENT;
    int32_t rc = put_receipt(out, out_len,
                             "{\"joined\":false,\"already\":false,\"ip\":\"\"}");
    return rc == CT_OK ? CT_REJECTED : rc;
}

int32_t ct_host_iface_ip(ct_bytes, ct_output out, int64_t *out_len) {
    if (!out_len || !out.data) return CT_INVALID_ARGUMENT;
    return put_receipt(out, out_len, "{\"ip\":\"\"}");
}

}  // extern "C"
