// Item 6 transport check (C++): drives native/router_web.cpp against a
// live lab/router_server.py. The server runs separately on the lab host;
// this binary assumes it at host:port with ROUTER_PASSWORD in env.
// Build on the lab host with g++ -std=c++20 and the repo native files.
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
