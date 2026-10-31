// Item 6 transport check (C++): drives native/router_web.cpp against
// the C++ virtual router (tests/router_double.cpp), which
// `make transport-check` spawns itself; this binary assumes it at
// host:port with ROUTER_PASSWORD in env.
// Build with `make transport-check` (C++20, repo native files).
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

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

static bool http_exchange(const char *host, int port, const std::string &req,
                          std::string &resp) {
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<uint16_t>(port));
    if (inet_pton(AF_INET, host, &addr.sin_addr) != 1) return false;
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return false;
    timeval tv{};
    tv.tv_sec = 2;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    if (connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof addr) != 0) {
        close(fd);
        return false;
    }
    size_t sent = 0;
    while (sent < req.size()) {
        ssize_t n = send(fd, req.data() + sent, req.size() - sent, 0);
        if (n <= 0) {
            close(fd);
            return false;
        }
        sent += static_cast<size_t>(n);
    }
    resp.clear();
    char buf[2048];
    for (;;) {
        ssize_t n = recv(fd, buf, sizeof buf, 0);
        if (n < 0) {
            close(fd);
            return false;
        }
        if (n == 0) break;
        resp.append(buf, static_cast<size_t>(n));
    }
    close(fd);
    return resp.compare(0, 5, "HTTP/") == 0;
}

static long json_long(const std::string &body, const char *key) {
    std::string q = std::string("\"") + key + "\":";
    size_t p = body.find(q);
    if (p == std::string::npos) return -1;
    p += q.size();
    while (p < body.size() && (body[p] == ' ' || body[p] == '\t')) p++;
    return std::atol(body.c_str() + p);
}

static long status_sessions(const char *host, int port) {
    std::string req = std::string("GET /api/status HTTP/1.0\r\nHost: ") + host +
                      "\r\nConnection: close\r\n\r\n";
    std::string resp;
    if (!http_exchange(host, port, req, resp)) return -1;
    return json_long(resp, "sessions");
}

// Drops every Bearer session, the way a firmware reboot does. The next
// apply must log in again; a cached token that is not retried is a miss.
static bool reboot_router(const char *host, int port, const char *pw) {
    std::string payload = std::string("{\"password\":\"") + pw + "\"}";
    std::string req = "POST /api/login HTTP/1.0\r\nHost: " + std::string(host) +
                      "\r\nContent-Type: application/json\r\nContent-Length: " +
                      std::to_string(payload.size()) +
                      "\r\nConnection: close\r\n\r\n" + payload;
    std::string resp;
    if (!http_exchange(host, port, req, resp)) return false;
    const char *marker = "\"session\": \"";
    size_t p = resp.find(marker);
    if (p == std::string::npos) return false;
    p += std::strlen(marker);
    size_t e = resp.find('"', p);
    if (e == std::string::npos || e == p) return false;
    std::string tok = resp.substr(p, e - p);
    req = "POST /api/reboot HTTP/1.0\r\nHost: " + std::string(host) +
          "\r\nAuthorization: Bearer " + tok +
          "\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}";
    resp.clear();
    if (!http_exchange(host, port, req, resp)) return false;
    return resp.find(" 200 ") != std::string::npos;
}

static std::string apply_json(const char *host, int port) {
    char b[512];
    std::snprintf(b, sizeof b,
                  "{\"host\":\"%s\",\"port\":%d,\"profile_id\":\"sqm-fair\","
                  "\"rate_mbit\":20,\"scope_id\":\"lab-sim\","
                  "\"lease_id\":\"req-t1\",\"revision\":7}",
                  host, port);
    return b;
}

int main(int argc, char **argv) {
    if (argc != 3) {
        std::printf("usage: %s host port\n", argv[0]);
        return 2;
    }
    const char *host = argv[1];
    int port = std::atoi(argv[2]);
    const char *real_pw = std::getenv("ROUTER_PASSWORD");
    std::string saved_pw = real_pw ? real_pw : "";
    uint8_t receipt[2048];
    int64_t out_len = 0;
    ct_bytes req{nullptr, 0};
    ct_output out{receipt, (int64_t)sizeof receipt};

    // Malformed input fails closed before any socket opens.
    std::string bad = "{\"host\":";
    req = {reinterpret_cast<const uint8_t *>(bad.data()),
           (int64_t)bad.size()};
    check(ct_profile_apply(req, out, &out_len) == CT_INVALID_ARGUMENT,
          "truncated request rejected");

    // Wrong password is rejected by the router, surfaced as REJECTED.
    setenv("ROUTER_PASSWORD", "definitely-wrong", 1);
    std::string good = apply_json(host, port);
    req = {reinterpret_cast<const uint8_t *>(good.data()),
           (int64_t)good.size()};
    check(ct_profile_apply(req, out, &out_len) == CT_REJECTED,
          "wrong router password rejected");
    setenv("ROUTER_PASSWORD", saved_pw.c_str(), 1);

    // Apply the fair profile: receipt must verify with a bumped revision.
    // The router's absolute revision is its own business (it persists
    // across runs), so read it first, then require exactly +1.
    req = {reinterpret_cast<const uint8_t *>(good.data()),
           (int64_t)good.size()};
    out_len = 0;
    check(ct_watchdog_reconcile(req, out, &out_len) == CT_OK,
          "pre-apply reconcile returns CT_OK");
    std::string pre(reinterpret_cast<char *>(receipt), (size_t)out_len);
    long rev0 = -1;
    {
        size_t p = pre.find("\"revision\":");
        if (p != std::string::npos)
            rev0 = std::stol(pre.substr(p + 11));
    }
    check(rev0 >= 0, "pre-apply revision reads back");
    int32_t rc = ct_profile_apply(req, out, &out_len);
    check(rc == CT_OK, "apply returns CT_OK");
    std::string rec(reinterpret_cast<char *>(receipt), (size_t)out_len);
    check(rec.find("\"verified\":true") != std::string::npos,
          "apply receipt verified");
    check(rec.find("\"lease_id\":\"req-t1\"") != std::string::npos,
          "apply receipt carries the lease");
    long rev = 0;
    {
        size_t p = rec.find("\"revision\":");
        if (p != std::string::npos) rev = std::stol(rec.substr(p + 11));
    }
    check(rev == rev0 + 1, "apply receipt shows a bumped revision");

    // Reconcile against the reported revision: in sync.
    char recq[512];
    std::snprintf(recq, sizeof recq,
                  "{\"host\":\"%s\",\"port\":%d,\"profile_id\":\"sqm-fair\","
                  "\"rate_mbit\":20,\"scope_id\":\"lab-sim\","
                  "\"lease_id\":\"req-t1\",\"revision\":%ld}",
                  host, port, rev);
    std::string recqs = recq;
    req = {reinterpret_cast<const uint8_t *>(recqs.data()),
           (int64_t)recqs.size()};
    out_len = 0;
    check(ct_watchdog_reconcile(req, out, &out_len) == CT_OK,
          "reconcile returns CT_OK");
    std::string con(reinterpret_cast<char *>(receipt), (size_t)out_len);
    check(con.find("\"in_sync\":true") != std::string::npos,
          "reconcile reports in sync");

    // Restore the baseline, then reconcile: revision moved, not in sync.
    out_len = 0;
    check(ct_profile_restore(req, out, &out_len) == CT_OK,
          "restore returns CT_OK");
    std::string rst(reinterpret_cast<char *>(receipt), (size_t)out_len);
    check(rst.find("\"verified\":true") != std::string::npos,
          "restore receipt verified");
    out_len = 0;
    check(ct_watchdog_reconcile(req, out, &out_len) == CT_OK,
          "post-restore reconcile returns CT_OK");
    std::string con2(reinterpret_cast<char *>(receipt), (size_t)out_len);
    check(con2.find("\"in_sync\":false") != std::string::npos,
          "post-restore reconcile reports drift");

    // Five applies must not open five router sessions. Login-per-call
    // grows the session table by five; a reused session grows it by at most one.
    long sessions_before = status_sessions(host, port);
    check(sessions_before >= 0, "status reports session count");
    int repeat_ok = 0;
    for (int n = 0; n < 5; n++) {
        out_len = 0;
        if (ct_profile_apply(req, out, &out_len) == CT_OK) {
            std::string recn(reinterpret_cast<char *>(receipt), (size_t)out_len);
            if (recn.find("\"verified\":true") != std::string::npos) repeat_ok++;
        }
    }
    check(repeat_ok == 5, "five repeat applies verify");
    long sessions_after = status_sessions(host, port);
    check(sessions_after >= 0 && sessions_after - sessions_before <= 1,
          "five applies open at most one session");

    // Reboot while the session is still cached. A retry-less cache returns
    // the router's 401 and never applies; login-per-call happens to survive
    // because it never held a token.
    check(reboot_router(host, port, saved_pw.c_str()), "router reboot accepted");
    out_len = 0;
    int32_t after_boot = ct_profile_apply(req, out, &out_len);
    check(after_boot == CT_OK, "apply after reboot returns CT_OK");
    if (after_boot == CT_OK) {
        std::string recb(reinterpret_cast<char *>(receipt), (size_t)out_len);
        check(recb.find("\"verified\":true") != std::string::npos,
              "apply after reboot verified");
    }

    // A password change must not reuse the previous session.
    setenv("ROUTER_PASSWORD", "definitely-wrong", 1);
    out_len = 0;
    check(ct_profile_apply(req, out, &out_len) == CT_REJECTED,
          "changed password rejected");
    setenv("ROUTER_PASSWORD", saved_pw.c_str(), 1);

    // A receipt buffer that cannot hold the answer is an explicit error.
    uint8_t tiny[8];
    ct_output small{tiny, 8};
    out_len = 0;
    check(ct_profile_apply(
              {reinterpret_cast<const uint8_t *>(good.data()),
               (int64_t)good.size()},
              small, &out_len) == CT_BUFFER_TOO_SMALL,
          "tiny receipt buffer reported");

    // Unreachable router is a transport failure, never a phantom success.
    std::string down = apply_json("127.0.0.1", 9);
    check(ct_profile_apply(
              {reinterpret_cast<const uint8_t *>(down.data()),
               (int64_t)down.size()},
              out, &out_len) == CT_FAILED,
          "unreachable router fails closed");

    std::printf(failures == 0 ? "TRANSPORT_ALL_GREEN\n"
                              : "TRANSPORT_RED\n");
    return failures == 0 ? 0 : 1;
}
