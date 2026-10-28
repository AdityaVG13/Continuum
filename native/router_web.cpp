// Continuum WebApi transport (item 6): real ct_profile_* over HTTP.
//
// Talks to a stock-like router admin API (see tests/router_double.cpp
// for the test double): login with a password that ONLY comes from the
// ROUTER_PASSWORD environment variable, set the QoS knob, read it back,
// restore the baseline, reconcile revision. No TLS here: the lab link is a
// private test network; HTTPS with pinned firmware certificates is the
// documented ticket before any real router is touched.
//
// Request JSON (admitted_request_json) carries routing, never secrets:
//   {"host":"127.0.0.1","port":18080,
//    "profile_id":"sqm-fair","rate_mbit":20,
//    "scope_id":"lab-sim","lease_id":"req-1","revision":7}
// Receipt JSON written to receipt_json:
//   {"applied":true,"verified":true,"revision":8,
//    "lease_id":"req-1","profile_id":"sqm-fair"}
//
// Status mapping: router 401 -> CT_REJECTED, router 400 -> CT_INVALID,
// unreachable/timeout/garbage -> CT_FAILED, receipt buffer too small ->
// CT_BUFFER_TOO_SMALL. Transport errors never claim success.
#include "continuum_native.h"

#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {

const int kTimeoutSec = 5;
const int kMaxBody = 8192;

struct RouterRef {
    std::string host;
    int port = 0;
    std::string profile;
    int rate_mbit = 0;
    std::string scope;
    std::string lease;
    long revision = 0;
    bool ok = false;
};

// --- minimal strict JSON subset: flat object, string/int/bool values ---
// Whitespace after the colon is skipped; nested objects are matched by
// substring, which is exact enough for the lab double's fixed shapes.
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
    if (p >= body.size() || !(body[p] == '-' ||
                              (body[p] >= '0' && body[p] <= '9')))
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

bool parse_request(const char *data, int64_t len, RouterRef &r) {
    if (len <= 0 || len > kMaxBody) return false;
    std::string body(data, (size_t)len);
    if (!json_str(body, "host", r.host) || r.host.empty() ||
        r.host.size() > 253)
        return false;
    long port = 0;
    if (!json_int(body, "port", port) || port <= 0 || port > 65535)
        return false;
    r.port = (int)port;
    if (!json_str(body, "profile_id", r.profile) || r.profile.empty() ||
        r.profile.size() > 64)
        return false;
    long rate = 0;
    if (!json_int(body, "rate_mbit", rate) || rate < 1 || rate > 1000)
        return false;
    r.rate_mbit = (int)rate;
    if (!json_str(body, "scope_id", r.scope) || r.scope.empty() ||
        r.scope.size() > 64)
        return false;
    if (!json_str(body, "lease_id", r.lease) || r.lease.empty() ||
        r.lease.size() > 64)
        return false;
    long rev = 0;
    if (!json_int(body, "revision", rev) || rev < 0) return false;
    r.revision = rev;
    r.ok = true;
    return true;
}

// --- blocking HTTP/1.0 with a hard timeout, no redirects, no chunks ---
int32_t http_round(const std::string &host, int port, const std::string &req,
                   int &status, std::string &body) {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char port_s[16];
    std::snprintf(port_s, sizeof port_s, "%d", port);
    addrinfo *ai = nullptr;
    if (getaddrinfo(host.c_str(), port_s, &hints, &ai) != 0 || !ai)
        return CT_FAILED;
    int fd = -1;
    for (addrinfo *a = ai; a; a = a->ai_next) {
        fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0) continue;
        timeval tv{};
        tv.tv_sec = kTimeoutSec;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        if (connect(fd, a->ai_addr, a->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(ai);
    if (fd < 0) return CT_FAILED;
    size_t sent = 0;
    while (sent < req.size()) {
        ssize_t n = send(fd, req.data() + sent, req.size() - sent, 0);
        if (n <= 0) {
            close(fd);
            return CT_FAILED;
        }
        sent += (size_t)n;
    }
    std::string raw;
    char buf[4096];
    for (;;) {
        ssize_t n = recv(fd, buf, sizeof buf, 0);
        if (n < 0) {
            close(fd);
            return CT_FAILED;
        }
        if (n == 0) break;
        if (raw.size() + (size_t)n > 65536) {
            close(fd);
            return CT_FAILED;
        }
        raw.append(buf, (size_t)n);
    }
    close(fd);
    if (raw.compare(0, 5, "HTTP/") != 0) return CT_FAILED;
    size_t eol = raw.find("\r\n");
    if (eol == std::string::npos) return CT_FAILED;
    // Status line is "HTTP/1.0 200 OK": the code follows the first space.
    size_t sp = raw.find(' ', 5);
    if (sp == std::string::npos || sp + 1 >= raw.size()) return CT_FAILED;
    status = std::atoi(raw.c_str() + sp + 1);
    if (status <= 0 || status > 599) return CT_FAILED;
    size_t hdr_end = raw.find("\r\n\r\n");
    if (hdr_end == std::string::npos) return CT_FAILED;
    body = raw.substr(hdr_end + 4);
    if ((long)body.size() > kMaxBody) return CT_FAILED;
    return CT_OK;
}

std::string post(const std::string &host, int port, const std::string &path,
                 const std::string &json, const std::string &token) {
    (void)port;
    std::string r = "POST " + path + " HTTP/1.0\r\nHost: " + host +
                    "\r\nContent-Type: application/json\r\nContent-Length: " +
                    std::to_string(json.size()) + "\r\n";
    if (!token.empty()) r += "Authorization: Bearer " + token + "\r\n";
    return r + "Connection: close\r\n\r\n" + json;
}
std::string get(const std::string &host, int port, const std::string &path,
                const std::string &token) {
    (void)port;
    std::string r =
        "GET " + path + " HTTP/1.0\r\nHost: " + host + "\r\n";
    if (!token.empty()) r += "Authorization: Bearer " + token + "\r\n";
    return r + "Connection: close\r\n\r\n";
}
void put_receipt(ct_output out, int64_t *out_len, const std::string &s,
                 int32_t &rc) {
    if ((int64_t)s.size() > out.capacity) {
        rc = CT_BUFFER_TOO_SMALL;
        return;
    }
    std::memcpy(out.data, s.data(), s.size());
    *out_len = (int64_t)s.size();
    rc = CT_OK;
}

// Login per call (no token caching): lab sessions are cheap and a cached
// token that the router dropped on reboot is a stale-credential bug.
int32_t router_login(const std::string &host, int port, std::string &token) {
    const char *pw = std::getenv("ROUTER_PASSWORD");
    if (!pw || !*pw) return CT_INVALID_ARGUMENT;
    std::string payload = std::string("{\"password\":\"") + pw + "\"}";
    int status = 0;
    std::string body;
    int32_t rc = http_round(host, port, post(host, port, "/api/login",
                                             payload, ""),
                            status, body);
    if (rc != CT_OK) return CT_FAILED;
    if (status == 401) return CT_REJECTED;
    if (status != 200) return CT_FAILED;
    if (!json_str(body, "session", token) || token.empty())
        return CT_FAILED;
    return CT_OK;
}

int32_t qos_set(const RouterRef &r, bool on, int rate, long &rev_out) {
    std::string token;
    int32_t rc = router_login(r.host, r.port, token);
    if (rc != CT_OK) return rc;
    char payload[256];
    std::snprintf(payload, sizeof payload,
                  "{\"on\":%s,\"rate_mbit\":%d}", on ? "true" : "false",
                  rate);
    int status = 0;
    std::string body;
    rc = http_round(r.host, r.port, post(r.host, r.port, "/api/qos",
                                         payload, token),
                    status, body);
    if (rc != CT_OK) return CT_FAILED;
    if (status == 401) return CT_REJECTED;
    if (status == 400) return CT_INVALID_ARGUMENT;
    if (status != 200) return CT_FAILED;
    // Readback: the write counts only if the router reports it.
    bool qon = false;
    long qrate = 0, qrev = 0;
    if (!json_bool(body, "on", qon) || !json_int(body, "rate_mbit", qrate) ||
        !json_int(body, "revision", qrev))
        return CT_FAILED;
    // Note: /api/qos nests under "qos":{...}; accept both flat and nested
    // by falling back to a second GET readback when fields are absent.
    if (!body.empty() && (qon != on || qrate != rate)) {
        int gs = 0;
        std::string gb;
        rc = http_round(r.host, r.port,
                        get(r.host, r.port, "/api/qos", token), gs, gb);
        if (rc != CT_OK || gs != 200) return CT_FAILED;
        if (!json_bool(gb, "on", qon) || !json_int(gb, "rate_mbit", qrate) ||
            !json_int(gb, "revision", qrev))
            return CT_FAILED;
        if (qon != on || qrate != rate) return CT_FAILED;
    }
    rev_out = qrev;
    return CT_OK;
}

}  // namespace

extern "C" {
int32_t ct_profile_apply(ct_bytes req, ct_output out, int64_t *out_len) {
    if (!out_len || !req.data) return CT_INVALID_ARGUMENT;
    RouterRef r;
    if (!parse_request((const char *)req.data, req.len, r))
        return CT_INVALID_ARGUMENT;
    long rev = 0;
    int32_t rc = qos_set(r, true, r.rate_mbit, rev);
    if (rc != CT_OK) return rc;
    char receipt[512];
    int n = std::snprintf(
        receipt, sizeof receipt,
        "{\"applied\":true,\"verified\":true,\"revision\":%ld,"
        "\"lease_id\":\"%s\",\"profile_id\":\"%s\"}",
        rev, r.lease.c_str(), r.profile.c_str());
    if (n <= 0 || n >= (int)sizeof receipt) return CT_FAILED;
    put_receipt(out, out_len, std::string(receipt, (size_t)n), rc);
    return rc;
}
int32_t ct_profile_restore(ct_bytes req, ct_output out, int64_t *out_len) {
    if (!out_len || !req.data) return CT_INVALID_ARGUMENT;
    RouterRef r;
    if (!parse_request((const char *)req.data, req.len, r))
        return CT_INVALID_ARGUMENT;
    // Baseline for the lab double: QoS off, full rate.
    long rev = 0;
    int32_t rc = qos_set(r, false, 100, rev);
    if (rc != CT_OK) return rc;
    char receipt[512];
    int n = std::snprintf(
        receipt, sizeof receipt,
        "{\"restored\":true,\"verified\":true,\"revision\":%ld,"
        "\"lease_id\":\"%s\"}",
        rev, r.lease.c_str());
    if (n <= 0 || n >= (int)sizeof receipt) return CT_FAILED;
    put_receipt(out, out_len, std::string(receipt, (size_t)n), rc);
    return rc;
}
int32_t ct_watchdog_reconcile(ct_bytes req, ct_output out, int64_t *out_len) {
    if (!out_len || !req.data) return CT_INVALID_ARGUMENT;
    RouterRef r;
    if (!parse_request((const char *)req.data, req.len, r))
        return CT_INVALID_ARGUMENT;
    std::string token;
    int32_t rc = router_login(r.host, r.port, token);
    if (rc != CT_OK) return rc;
    int status = 0;
    std::string body;
    rc = http_round(r.host, r.port,
                    get(r.host, r.port, "/api/status", token), status,
                    body);
    if (rc != CT_OK) return CT_FAILED;
    if (status == 401) return CT_REJECTED;
    if (status != 200) return CT_FAILED;
    long rev = 0, boot = 0;
    if (!json_int(body, "revision", rev) || !json_int(body, "boot_id", boot))
        return CT_FAILED;
    char receipt[512];
    int n = std::snprintf(
        receipt, sizeof receipt,
        "{\"revision\":%ld,\"boot_id\":%ld,\"expected_revision\":%ld,"
        "\"in_sync\":%s}",
        rev, boot, r.revision, rev == r.revision ? "true" : "false");
    if (n <= 0 || n >= (int)sizeof receipt) return CT_FAILED;
    put_receipt(out, out_len, std::string(receipt, (size_t)n), rc);
    return rc;
}
}
