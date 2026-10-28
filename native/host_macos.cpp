// macOS host backend for the leap ceremony: the production ct_vault_*
// (login keychain) plus ct_host_* (secret staging, Wi-Fi rejoin,
// interface IP). Ports the host legs proven live by the local lab
// script, with the same safety shape:
//
//   stage   generate [A-Za-z0-9] secrets with arc4random_uniform, store
//           both in the keychain, verify by readback before claiming
//           staged -- the staged copies are the only way back after
//           the leap. reuse:true returns the existing pair untouched
//           (lengths only), which is what makes a rerun resume instead
//           of re-leaping with fresh credentials the router never saw.
//   rejoin  forget any stale preferred-network entry for the SSID
//           first (a pre-reset entry makes macOS retry the old PSK
//           forever while networksetup still exits 0), then join and
//           wait for a lease in the router prefix. Already holding an
//           in-prefix address returns before touching the association:
//           current-SSID readout is TCC-redacted in this context, so
//           the prefix is the honest proxy. The PSK transits the
//           networksetup child's argv (no stdin mode exists on macOS);
//           spawned without a shell, so nothing is interpreted.
//   vault   refs are keychain service names verbatim (account
//           "continuum"), matching `security find-generic-password
//           -s <ref> -a continuum -w` for operator recovery. Items are
//           WhenUnlockedThisDeviceOnly: router credentials never sync.
//
// Link exactly one vault backend: this file OR native/vault.cpp (env
// test double). Off macOS only ct_host_* link, as CT_NOT_IMPLEMENTED.
#include "continuum_native.h"

#if defined(__APPLE__)

#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <netinet/in.h>
#include <spawn.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <unistd.h>

#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

extern char **environ;

namespace {

// --- minimal strict JSON subset (same pattern as router_web.cpp) ---
size_t skip_ws(const std::string &body, size_t p) {
    while (p < body.size() &&
           (body[p] == ' ' || body[p] == '\t' || body[p] == '\n' ||
            body[p] == '\r'))
        p++;
    return p;
}
bool json_str(const std::string &body, const char *key, std::string &out) {
    std::string q = std::string("\"") + key + "\":";
    size_t p = body.find(q);
    if (p == std::string::npos) return false;
    p = skip_ws(body, p + q.size());
    if (p >= body.size() || body[p] != '"') return false;
    p++;
    size_t e = body.find('"', p);
    if (e == std::string::npos || e - p > 256) return false;
    out.assign(body, p, e - p);
    return true;
}
bool json_int(const std::string &body, const char *key, long &out) {
    std::string q = std::string("\"") + key + "\":";
    size_t p = body.find(q);
    if (p == std::string::npos) return false;
    p = skip_ws(body, p + q.size());
    if (p >= body.size() ||
        !(body[p] == '-' || (body[p] >= '0' && body[p] <= '9')))
        return false;
    size_t e = p + (body[p] == '-' ? 1 : 0);
    while (e < body.size() && body[e] >= '0' && body[e] <= '9') e++;
    if (e == p || e - p > 18) return false;
    out = std::stol(body.substr(p, e - p));
    return true;
}
bool json_bool(const std::string &body, const char *key, bool &out) {
    std::string q = std::string("\"") + key + "\":";
    size_t p = body.find(q);
    if (p == std::string::npos) return false;
    p = skip_ws(body, p + q.size());
    if (body.compare(p, 4, "true") == 0) {
        out = true;
        return true;
    }
    if (body.compare(p, 5, "false") == 0) {
        out = false;
        return true;
    }
    return false;
}

// Receipt writer that leaves the status to the caller: rejoin receipts
// a "joined":false body together with CT_REJECTED.
bool put_receipt(ct_output out, int64_t *out_len, const std::string &s) {
    if ((int64_t)s.size() > out.capacity) return false;
    std::memcpy(out.data, s.data(), s.size());
    *out_len = (int64_t)s.size();
    return true;
}

bool ref_ok_str(const std::string &r) {
    if (r.empty() || r.size() > 128) return false;
    for (char c : r) {
        bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9') || c == '.' || c == '_' ||
                  c == '-';
        if (!ok) return false;
    }
    return true;
}
bool ref_ok(ct_bytes ref, std::string &out) {
    if (!ref.data || ref.len <= 0 || ref.len > 128) return false;
    out.assign((const char *)ref.data, (size_t)ref.len);
    return ref_ok_str(out);
}

// --- keychain (login keychain, generic passwords) ---
struct CFStr {
    CFStringRef ref = nullptr;
    explicit CFStr(const std::string &s)
        : ref(CFStringCreateWithCString(nullptr, s.c_str(),
                                        kCFStringEncodingUTF8)) {}
    ~CFStr() {
        if (ref) CFRelease(ref);
    }
    CFStr(const CFStr &) = delete;
    CFStr &operator=(const CFStr &) = delete;
};

CFDictionaryRef kc_query(CFStringRef svc) {
    const void *keys[] = {kSecClass, kSecAttrService, kSecAttrAccount};
    const void *vals[] = {kSecClassGenericPassword, svc,
                          CFSTR("continuum")};
    return CFDictionaryCreate(nullptr, keys, vals, 3,
                              &kCFTypeDictionaryKeyCallBacks,
                              &kCFTypeDictionaryValueCallBacks);
}

bool kc_fetch(const std::string &service, std::string &out) {
    CFStr svc(service);
    if (!svc.ref) return false;
    const void *keys[] = {kSecClass, kSecAttrService, kSecAttrAccount,
                          kSecReturnData, kSecMatchLimit};
    const void *vals[] = {kSecClassGenericPassword, svc.ref,
                          CFSTR("continuum"), kCFBooleanTrue,
                          kSecMatchLimitOne};
    CFDictionaryRef q = CFDictionaryCreate(
        nullptr, keys, vals, 5, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (!q) return false;
    CFTypeRef res = nullptr;
    OSStatus st = SecItemCopyMatching(q, &res);
    CFRelease(q);
    if (st != errSecSuccess || !res ||
        CFGetTypeID(res) != CFDataGetTypeID()) {
        if (res) CFRelease(res);
        return false;
    }
    CFDataRef d = (CFDataRef)res;
    out.assign((const char *)CFDataGetBytePtr(d),
               (size_t)CFDataGetLength(d));
    CFRelease(d);
    return !out.empty();
}

bool kc_store(const std::string &service, const std::string &value) {
    CFStr svc(service);
    if (!svc.ref) return false;
    CFDataRef data =
        CFDataCreate(nullptr, (const UInt8 *)value.data(),
                     (CFIndex)value.size());
    if (!data) return false;
    const void *keys[] = {kSecClass, kSecAttrService, kSecAttrAccount,
                          kSecValueData, kSecAttrAccessible};
    const void *vals[] = {kSecClassGenericPassword, svc.ref,
                          CFSTR("continuum"), data,
                          kSecAttrAccessibleWhenUnlockedThisDeviceOnly};
    CFDictionaryRef add = CFDictionaryCreate(
        nullptr, keys, vals, 5, &kCFTypeDictionaryKeyCallBacks,
        &kCFTypeDictionaryValueCallBacks);
    if (!add) {
        CFRelease(data);
        return false;
    }
    OSStatus st = SecItemAdd(add, nullptr);
    CFRelease(add);
    if (st == errSecDuplicateItem) {
        CFDictionaryRef q = kc_query(svc.ref);
        const void *uk[] = {kSecValueData};
        const void *uv[] = {data};
        CFDictionaryRef upd = CFDictionaryCreate(
            nullptr, uk, uv, 1, &kCFTypeDictionaryKeyCallBacks,
            &kCFTypeDictionaryValueCallBacks);
        if (q && upd) st = SecItemUpdate(q, upd);
        if (q) CFRelease(q);
        if (upd) CFRelease(upd);
    }
    CFRelease(data);
    return st == errSecSuccess;
}

bool kc_delete(const std::string &service) {
    CFStr svc(service);
    if (!svc.ref) return false;
    CFDictionaryRef q = kc_query(svc.ref);
    if (!q) return false;
    OSStatus st = SecItemDelete(q);
    CFRelease(q);
    return st == errSecSuccess || st == errSecItemNotFound;
}

std::string gen_secret(long n) {
    static const char kAlphabet[] =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    std::string s;
    s.reserve((size_t)n);
    for (long i = 0; i < n; i++)
        s += kAlphabet[arc4random_uniform(62)];
    return s;
}

// --- interface IPv4 via getifaddrs (no spawn for the poll path) ---
std::string iface_ipv4(const std::string &name) {
    ifaddrs *all = nullptr;
    if (getifaddrs(&all) != 0 || !all) return "";
    std::string found;
    for (ifaddrs *a = all; a; a = a->ifa_next) {
        if (!a->ifa_addr || a->ifa_addr->sa_family != AF_INET) continue;
        if (!a->ifa_name || name != a->ifa_name) continue;
        char buf[INET_ADDRSTRLEN] = {0};
        auto *sin = (sockaddr_in *)a->ifa_addr;
        if (sin->sin_addr.s_addr == 0) continue;
        if (!inet_ntop(AF_INET, &sin->sin_addr, buf, sizeof buf)) continue;
        found = buf;
        if (!(a->ifa_flags & IFF_LOOPBACK)) break;
    }
    freeifaddrs(all);
    return found;
}

bool iface_name_ok(const std::string &s) {
    if (s.empty() || s.size() > 16) return false;
    for (char c : s) {
        bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9');
        if (!ok) return false;
    }
    return true;
}

// Run a fixed argv (no shell) capturing merged stdout+stderr, bounded
// in time and output. Returns spawn success; exit code via `code`.
bool run_capture(const std::vector<std::string> &args, int timeout_sec,
                 std::string &out, int &code) {
    code = -1;
    if (args.empty()) return false;
    int pfds[2];
    if (pipe(pfds) != 0) return false;
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, pfds[1], STDOUT_FILENO);
    posix_spawn_file_actions_adddup2(&fa, pfds[1], STDERR_FILENO);
    posix_spawn_file_actions_addclose(&fa, pfds[0]);
    posix_spawn_file_actions_addclose(&fa, pfds[1]);
    std::vector<char *> argv;
    for (const auto &a : args) argv.push_back((char *)a.c_str());
    argv.push_back(nullptr);
    pid_t pid = -1;
    int rc = posix_spawn(&pid, args[0].c_str(), &fa, nullptr, argv.data(),
                         environ);
    posix_spawn_file_actions_destroy(&fa);
    close(pfds[1]);
    if (rc != 0 || pid <= 0) {
        close(pfds[0]);
        return false;
    }
    // Drain with a deadline; networksetup output is a line or two, so a
    // full pipe means something is wrong, not something to buffer.
    long deadline_ms = (long)timeout_sec * 1000;
    long waited_ms = 0;
    bool eof = false;
    while (!eof && waited_ms < deadline_ms) {
        fd_set rf;
        FD_ZERO(&rf);
        FD_SET(pfds[0], &rf);
        timeval tv{0, 100 * 1000};
        int sel = select(pfds[0] + 1, &rf, nullptr, nullptr, &tv);
        if (sel > 0 && FD_ISSET(pfds[0], &rf)) {
            char buf[1024];
            ssize_t n = read(pfds[0], buf, sizeof buf);
            if (n <= 0) {
                eof = true;
            } else if (out.size() + (size_t)n <= 8192) {
                out.append(buf, (size_t)n);
            }
        } else if (sel == 0) {
            waited_ms += 100;
        } else {
            break;
        }
    }
    close(pfds[0]);
    int status = 0;
    if (!eof) kill(pid, SIGKILL);
    if (waitpid(pid, &status, 0) < 0) return false;
    if (WIFEXITED(status)) code = WEXITSTATUS(status);
    return eof;
}

bool parse_body(ct_bytes req, std::string &body) {
    if (!req.data || req.len <= 0 || req.len > 8192) return false;
    body.assign((const char *)req.data, (size_t)req.len);
    return true;
}

}  // namespace

extern "C" {

int32_t ct_vault_fetch(ct_bytes ref, ct_output out, int64_t *out_len) {
    if (!out_len || !out.data || out.capacity <= 0)
        return CT_INVALID_ARGUMENT;
    std::string service;
    if (!ref_ok(ref, service)) return CT_INVALID_ARGUMENT;
    std::string v;
    if (!kc_fetch(service, v)) return CT_FAILED;
    if ((int64_t)v.size() > out.capacity) return CT_BUFFER_TOO_SMALL;
    std::memcpy(out.data, v.data(), v.size());
    *out_len = (int64_t)v.size();
    return CT_OK;
}

int32_t ct_vault_store(ct_bytes ref, ct_bytes value) {
    std::string service;
    if (!ref_ok(ref, service)) return CT_INVALID_ARGUMENT;
    if (!value.data || value.len <= 0 || value.len > 256)
        return CT_INVALID_ARGUMENT;
    std::string v((const char *)value.data, (size_t)value.len);
    return kc_store(service, v) ? CT_OK : CT_FAILED;
}

int32_t ct_vault_delete(ct_bytes ref) {
    std::string service;
    if (!ref_ok(ref, service)) return CT_INVALID_ARGUMENT;
    return kc_delete(service) ? CT_OK : CT_FAILED;
}

int32_t ct_host_stage(ct_bytes req, ct_output out, int64_t *out_len) {
    if (!out_len || !out.data) return CT_INVALID_ARGUMENT;
    std::string body;
    if (!parse_body(req, body)) return CT_INVALID_ARGUMENT;
    std::string admin_ref, psk_ref;
    long admin_len = 0, psk_len = 0;
    bool reuse = false;
    if (!json_str(body, "admin_ref", admin_ref) || !ref_ok_str(admin_ref) ||
        !json_str(body, "psk_ref", psk_ref) || !ref_ok_str(psk_ref) ||
        !json_int(body, "admin_len", admin_len) || admin_len < 8 ||
        admin_len > 64 || !json_int(body, "psk_len", psk_len) ||
        psk_len < 8 || psk_len > 63 || !json_bool(body, "reuse", reuse))
        return CT_INVALID_ARGUMENT;
    char receipt[256];
    if (reuse) {
        std::string a, p;
        if (kc_fetch(admin_ref, a) && kc_fetch(psk_ref, p)) {
            int n = std::snprintf(
                receipt, sizeof receipt,
                "{\"staged\":true,\"reused\":true,\"admin_len\":%zu,"
                "\"psk_len\":%zu}",
                a.size(), p.size());
            if (n <= 0 || n >= (int)sizeof receipt) return CT_FAILED;
            return put_receipt(out, out_len,
                               std::string(receipt, (size_t)n))
                       ? CT_OK
                       : CT_BUFFER_TOO_SMALL;
        }
    }
    std::string admin = gen_secret(admin_len);
    std::string psk = gen_secret(psk_len);
    if (!kc_store(admin_ref, admin) || !kc_store(psk_ref, psk))
        return CT_FAILED;
    // The staged copies are the only way back after the leap: verify
    // them against what was generated, hard failure, never assume.
    std::string back_a, back_p;
    if (!kc_fetch(admin_ref, back_a) || back_a != admin ||
        !kc_fetch(psk_ref, back_p) || back_p != psk)
        return CT_FAILED;
    int n = std::snprintf(receipt, sizeof receipt,
                          "{\"staged\":true,\"reused\":false,"
                          "\"admin_len\":%ld,\"psk_len\":%ld}",
                          admin_len, psk_len);
    if (n <= 0 || n >= (int)sizeof receipt) return CT_FAILED;
    return put_receipt(out, out_len, std::string(receipt, (size_t)n))
               ? CT_OK
               : CT_BUFFER_TOO_SMALL;
}

int32_t ct_host_iface_ip(ct_bytes req, ct_output out, int64_t *out_len) {
    if (!out_len || !out.data) return CT_INVALID_ARGUMENT;
    std::string body;
    if (!parse_body(req, body)) return CT_INVALID_ARGUMENT;
    std::string iface;
    if (!json_str(body, "interface", iface) || !iface_name_ok(iface))
        return CT_INVALID_ARGUMENT;
    std::string receipt =
        "{\"ip\":\"" + iface_ipv4(iface) + "\"}";
    return put_receipt(out, out_len, receipt) ? CT_OK
                                              : CT_BUFFER_TOO_SMALL;
}

int32_t ct_host_rejoin(ct_bytes req, ct_output out, int64_t *out_len) {
    if (!out_len || !out.data) return CT_INVALID_ARGUMENT;
    std::string body;
    if (!parse_body(req, body)) return CT_INVALID_ARGUMENT;
    std::string iface, ssid, psk_ref, prefix;
    long wait_sec = 0;
    if (!json_str(body, "interface", iface) || !iface_name_ok(iface) ||
        !json_str(body, "ssid", ssid) || ssid.empty() || ssid.size() > 32 ||
        !json_str(body, "psk_ref", psk_ref) ||
        (!psk_ref.empty() && !ref_ok_str(psk_ref)) ||
        !json_str(body, "prefix", prefix) || prefix.size() > 15 ||
        !json_int(body, "wait_sec", wait_sec) || wait_sec < 0 ||
        wait_sec > 180)
        return CT_INVALID_ARGUMENT;
    auto receipt = [](bool joined, bool already,
                      const std::string &ip) {
        return std::string("{\"joined\":") +
               (joined ? "true" : "false") + ",\"already\":" +
               (already ? "true" : "false") + ",\"ip\":\"" + ip + "\"}";
    };
    // Already holding an in-prefix lease: the current association is
    // doing the job; networksetup churn could knock it loose.
    std::string cur = iface_ipv4(iface);
    if (!prefix.empty() && !cur.empty() &&
        cur.compare(0, prefix.size(), prefix) == 0) {
        return put_receipt(out, out_len, receipt(true, true, cur))
                   ? CT_OK
                   : CT_BUFFER_TOO_SMALL;
    }
    const char *kNetworksetup = "/usr/sbin/networksetup";
    std::string sink;
    int code = -1;
    run_capture({kNetworksetup, "-removepreferredwirelessnetwork", iface,
                 ssid},
                15, sink, code);
    std::vector<std::string> join = {kNetworksetup, "-setairportnetwork",
                                     iface, ssid};
    std::string psk;
    if (!psk_ref.empty()) {
        if (!kc_fetch(psk_ref, psk)) return CT_FAILED;
        join.push_back(psk);
    }
    std::string blob;
    code = -1;
    if (!run_capture(join, 30, blob, code) ||
        blob.find("Failed") != std::string::npos ||
        blob.find("Could not find") != std::string::npos) {
        if (!put_receipt(out, out_len, receipt(false, false, "")))
            return CT_BUFFER_TOO_SMALL;
        return CT_REJECTED;
    }
    for (long waited = 0; waited <= wait_sec; waited++) {
        std::string ip = iface_ipv4(iface);
        bool match = !ip.empty() &&
                     (prefix.empty() ||
                      ip.compare(0, prefix.size(), prefix) == 0);
        if (match) {
            return put_receipt(out, out_len, receipt(true, false, ip))
                       ? CT_OK
                       : CT_BUFFER_TOO_SMALL;
        }
        if (waited < wait_sec) sleep(1);
    }
    if (!put_receipt(out, out_len, receipt(false, false, "")))
        return CT_BUFFER_TOO_SMALL;
    return CT_REJECTED;
}

}  // extern "C"

#else  // !__APPLE__

extern "C" {
int32_t ct_host_stage(ct_bytes, ct_output, int64_t *) {
    return CT_NOT_IMPLEMENTED;
}
int32_t ct_host_rejoin(ct_bytes, ct_output, int64_t *) {
    return CT_NOT_IMPLEMENTED;
}
int32_t ct_host_iface_ip(ct_bytes, ct_output, int64_t *) {
    return CT_NOT_IMPLEMENTED;
}
}  // extern "C"

#endif
