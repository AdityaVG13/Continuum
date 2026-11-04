// Host backend check (C++): keychain vault roundtrip, staged-secret
// generation/reuse, interface IP and rejection of phantom Wi-Fi joins.
// --rejoin-check substitutes only the OS-command boundary: real children
// check private stdin delivery and DHCP evidence without joining Wi-Fi.
// Other rejoin probes use loopback or a nonexistent interface. Test-owned
// Keychain items use continuum.test.<pid>.* and are removed afterwards.
// macOS only; elsewhere it reports a skip.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "continuum_native.h"

#if defined(__APPLE__)
#include <dlfcn.h>
#include <spawn.h>
#include <unistd.h>
#include <vector>

// Substitute only the OS command boundary. The real host adapter still owns
// vault reads, child pipes, exit handling and interpretation of lease evidence.
static bool rejoin_fixture = false;
static std::string fixture_ssid;
extern "C" int posix_spawn(pid_t *pid, const char *path,
                           const posix_spawn_file_actions_t *actions,
                           const posix_spawnattr_t *attrs,
                           char *const argv[], char *const envp[]) {
    using Spawn = decltype(&posix_spawn);
    static auto spawn = reinterpret_cast<Spawn>(dlsym(RTLD_NEXT, "posix_spawn"));
    if (!spawn) return 1;
    if (!rejoin_fixture || (std::strcmp(path, "/usr/sbin/networksetup") != 0 &&
                            std::strcmp(path, "/usr/sbin/ipconfig") != 0))
        return spawn(pid, path, actions, attrs, argv, envp);
    std::string script = "";
    if (std::strcmp(path, "/usr/sbin/ipconfig") == 0) {
        script = fixture_ssid == "StaleAlias_5G"
                     ? "print('yiaddr = 10.0.0.99')"
                     : "print('yiaddr = 127.0.0.1')";
    } else if (argv[1] && std::strcmp(argv[1], "-setairportnetwork") == 0) {
        fixture_ssid = argv[3];
        script = "import sys; p='fixture-only-password'; "
                 "ok=sys.argv[-1]=='-' and p not in sys.argv and "
                 "sys.stdin.buffer.read()==(p+'\\n').encode(); "
                 "print('joined' if ok else 'Failed private password delivery'); "
                 "sys.exit(0 if ok else 17)";
    } else {
        script = "pass";
    }
    std::vector<char *> child = {const_cast<char *>("/usr/bin/python3"),
                                const_cast<char *>("-c"), script.data()};
    for (size_t i = 1; argv[i]; i++) child.push_back(argv[i]);
    child.push_back(nullptr);
    return spawn(pid, "/usr/bin/python3", actions, attrs, child.data(), envp);
}

static int failures = 0;
static void check(bool cond, const char *label) {
    std::printf("%s %s\n", cond ? "ok" : "FAIL", label);
    if (!cond) failures++;
}

static std::string call(int32_t (*fn)(ct_bytes, ct_output, int64_t *),
                        const std::string &req_json, int32_t &rc) {
    static uint8_t receipt[4096];
    int64_t out_len = 0;
    ct_bytes req{reinterpret_cast<const uint8_t *>(req_json.data()),
                 (int64_t)req_json.size()};
    ct_output out{receipt, (int64_t)sizeof receipt};
    rc = fn(req, out, &out_len);
    if (out_len < 0 || out_len > (int64_t)sizeof receipt) return "";
    return std::string(reinterpret_cast<char *>(receipt), (size_t)out_len);
}

static std::string fetch(const std::string &ref, int32_t &rc) {
    static uint8_t buf[512];
    int64_t n = 0;
    ct_bytes r{reinterpret_cast<const uint8_t *>(ref.data()),
               (int64_t)ref.size()};
    ct_output o{buf, (int64_t)sizeof buf};
    rc = ct_vault_fetch(r, o, &n);
    if (rc != CT_OK) return "";
    return std::string(reinterpret_cast<char *>(buf), (size_t)n);
}

static bool all_alnum(const std::string &s) {
    for (char c : s) {
        bool ok = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
                  (c >= '0' && c <= '9');
        if (!ok) return false;
    }
    return !s.empty();
}

static int rejoin_check() {
    rejoin_fixture = true;
    std::string ref = "continuum.test." + std::to_string((long)getpid()) + ".rejoin";
    const std::string password = "fixture-only-password";
    ct_bytes r{reinterpret_cast<const uint8_t *>(ref.data()), (int64_t)ref.size()};
    ct_bytes v{reinterpret_cast<const uint8_t *>(password.data()), (int64_t)password.size()};
    check(ct_vault_store(r, v) == CT_OK, "private fixture credential stored");
    int32_t rc = 0;
    std::string req = "{\"interface\":\"lo0\",\"ssid\":\"StaleAlias_5G\","
                      "\"psk_ref\":\"" + ref + "\",\"prefix\":\"127.\",\"wait_sec\":0}";
    std::string rec = call(ct_host_rejoin, req, rc);
    check(rc == CT_REJECTED && rec.find("\"joined\":false") != std::string::npos,
          "an existing alias does not prove a join when DHCP is on another network");
    req = "{\"interface\":\"lo0\",\"ssid\":\"FreshFixture_5G\","
          "\"psk_ref\":\"" + ref + "\",\"prefix\":\"127.\",\"wait_sec\":0}";
    rec = call(ct_host_rejoin, req, rc);
    check(rc == CT_OK && rec.find("\"joined\":true") != std::string::npos &&
              rec.find("\"already\":false") != std::string::npos,
          "a real child accepts the password privately on stdin and a matching lease");
    check(ct_vault_delete(r) == CT_OK, "only this test's credential removed");
    std::printf(failures == 0 ? "HOST_REJOIN_ALL_GREEN\n" : "HOST_REJOIN_RED\n");
    return failures == 0 ? 0 : 1;
}

int main(int argc, char **argv) {
    if (argc == 2 && std::strcmp(argv[1], "--rejoin-check") == 0)
        return rejoin_check();
    std::string base = "continuum.test." +
                       std::to_string((long)getpid());
    std::string admin_ref = base + ".admin";
    std::string psk_ref = base + ".psk";
    // Clear leftovers from a crashed earlier run.
    ct_bytes ar{reinterpret_cast<const uint8_t *>(admin_ref.data()),
                (int64_t)admin_ref.size()};
    ct_bytes pr{reinterpret_cast<const uint8_t *>(psk_ref.data()),
                (int64_t)psk_ref.size()};
    ct_vault_delete(ar);
    ct_vault_delete(pr);

    int32_t rc = 0;
    // Malformed stage request fails closed.
    call(ct_host_stage,
         "{\"admin_ref\":\"" + admin_ref + "\",\"psk_ref\":\"" + psk_ref +
             "\",\"admin_len\":4,\"psk_len\":16,\"reuse\":true}",
         rc);
    check(rc == CT_INVALID_ARGUMENT, "under-length stage rejected");

    // Stage fresh: generated, vaulted, lengths receipted (never values).
    std::string stage_req =
        "{\"admin_ref\":\"" + admin_ref + "\",\"psk_ref\":\"" + psk_ref +
        "\",\"admin_len\":20,\"psk_len\":16,\"reuse\":true}";
    std::string rec = call(ct_host_stage, stage_req, rc);
    check(rc == CT_OK, "stage returns CT_OK");
    check(rec.find("\"staged\":true") != std::string::npos,
          "stage receipt staged");
    check(rec.find("\"reused\":false") != std::string::npos,
          "first stage generates");
    check(rec.find("\"admin_len\":20") != std::string::npos &&
              rec.find("\"psk_len\":16") != std::string::npos,
          "stage receipt lengths");
    std::string admin1 = fetch(admin_ref, rc);
    check(rc == CT_OK && admin1.size() == 20 && all_alnum(admin1),
          "staged admin fetches as 20 alnum chars");
    std::string psk1 = fetch(psk_ref, rc);
    check(rc == CT_OK && psk1.size() == 16 && all_alnum(psk1),
          "staged psk fetches as 16 alnum chars");
    check(admin1 != psk1, "staged pair differs");

    // Reuse: same values come back, receipt says so.
    rec = call(ct_host_stage, stage_req, rc);
    check(rc == CT_OK &&
              rec.find("\"reused\":true") != std::string::npos,
          "second stage reuses");
    check(fetch(admin_ref, rc) == admin1 && fetch(psk_ref, rc) == psk1,
          "reuse keeps the staged values");

    // Forced regeneration replaces both.
    std::string fresh_req =
        "{\"admin_ref\":\"" + admin_ref + "\",\"psk_ref\":\"" + psk_ref +
        "\",\"admin_len\":20,\"psk_len\":16,\"reuse\":false}";
    rec = call(ct_host_stage, fresh_req, rc);
    check(rc == CT_OK &&
              rec.find("\"reused\":false") != std::string::npos,
          "reuse:false regenerates");
    check(fetch(admin_ref, rc) != admin1 && fetch(psk_ref, rc) != psk1,
          "regeneration replaces the values");

    // Interface IP: loopback is deterministic.
    rec = call(ct_host_iface_ip, "{\"interface\":\"lo0\"}", rc);
    check(rc == CT_OK &&
              rec.find("\"ip\":\"127.0.0.1\"") != std::string::npos,
          "lo0 reports 127.0.0.1");
    rec = call(ct_host_iface_ip, "{\"interface\":\"en99\"}", rc);
    check(rc == CT_OK && rec.find("\"ip\":\"\"") != std::string::npos,
          "missing interface reports empty ip");

    // A loopback address is not evidence of a Wi-Fi association or DHCP lease.
    rec = call(ct_host_rejoin,
               "{\"interface\":\"lo0\",\"ssid\":\"Whatever_5G\","
               "\"psk_ref\":\"\",\"prefix\":\"127.\",\"wait_sec\":1}",
               rc);
    check(rc == CT_REJECTED &&
              rec.find("\"joined\":false") != std::string::npos,
          "loopback address alone cannot establish a Wi-Fi join");

    // Rejoin against a nonexistent interface fails as REJECTED with a
    // receipt, never a phantom join.
    rec = call(ct_host_rejoin,
               "{\"interface\":\"en99\",\"ssid\":\"Nope_5G\","
               "\"psk_ref\":\"\",\"prefix\":\"192.0.2.\",\"wait_sec\":1}",
               rc);
    check(rc == CT_REJECTED &&
              rec.find("\"joined\":false") != std::string::npos,
          "unjoinable rejoin rejected with receipt");

    // Delete removes the staged pair.
    check(ct_vault_delete(ar) == CT_OK && ct_vault_delete(pr) == CT_OK,
          "vault delete returns CT_OK");
    fetch(admin_ref, rc);
    check(rc != CT_OK, "deleted admin no longer fetches");

    // Tiny receipt buffer is an explicit error.
    {
        uint8_t tiny[8];
        ct_output small{tiny, 8};
        int64_t n = 0;
        std::string q = "{\"interface\":\"lo0\"}";
        ct_bytes req{reinterpret_cast<const uint8_t *>(q.data()),
                     (int64_t)q.size()};
        check(ct_host_iface_ip(req, small, &n) == CT_BUFFER_TOO_SMALL,
              "tiny receipt buffer reported");
    }

    std::printf(failures == 0 ? "HOST_ALL_GREEN\n" : "HOST_RED\n");
    return failures == 0 ? 0 : 1;
}
#else
int main() {
    std::printf("HOST_SKIPPED non-macOS\n");
    return 0;
}
#endif
