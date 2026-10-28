// Env-backed vault: the NON-DURABLE test implementation of the
// ct_vault_* seam. A credential ref maps to the environment variable
// CONTINUUM_SECRET_<REF> (ref upper-cased, non-alphanumerics folded to
// '_'), so test harnesses stage secrets without touching the OS
// keychain. store() is setenv: it dies with the process, which is why
// this file must never be the production vault -- the macOS keychain
// implementation replaces it (native/host_macos.cpp), and the leap
// ceremony's staging durability comes from there, never from here.
#include "continuum_native.h"

#include <cstdlib>
#include <cstring>
#include <string>

namespace {

bool env_name(ct_bytes ref, std::string &out) {
    if (!ref.data || ref.len <= 0 || ref.len > 128) return false;
    out = "CONTINUUM_SECRET_";
    for (int64_t i = 0; i < ref.len; i++) {
        char c = (char)ref.data[i];
        if (c >= 'a' && c <= 'z')
            out += (char)(c - 'a' + 'A');
        else if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
            out += c;
        else
            out += '_';
    }
    return true;
}

}  // namespace

extern "C" {
int32_t ct_vault_fetch(ct_bytes ref, ct_output secret, int64_t *out_len) {
    if (!out_len || !secret.data || secret.capacity <= 0)
        return CT_INVALID_ARGUMENT;
    std::string name;
    if (!env_name(ref, name)) return CT_INVALID_ARGUMENT;
    const char *v = std::getenv(name.c_str());
    if (!v || !*v) return CT_FAILED;
    size_t n = std::strlen(v);
    if ((int64_t)n > secret.capacity) return CT_BUFFER_TOO_SMALL;
    std::memcpy(secret.data, v, n);
    *out_len = (int64_t)n;
    return CT_OK;
}

int32_t ct_vault_store(ct_bytes ref, ct_bytes secret) {
    if (!secret.data || secret.len <= 0 || secret.len > 256)
        return CT_INVALID_ARGUMENT;
    std::string name;
    if (!env_name(ref, name)) return CT_INVALID_ARGUMENT;
    std::string value((const char *)secret.data, (size_t)secret.len);
    if (setenv(name.c_str(), value.c_str(), 1) != 0) return CT_FAILED;
    return CT_OK;
}

int32_t ct_vault_delete(ct_bytes ref) {
    std::string name;
    if (!env_name(ref, name)) return CT_INVALID_ARGUMENT;
    unsetenv(name.c_str());
    return CT_OK;
}
}
