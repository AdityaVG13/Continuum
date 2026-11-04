// Exercise the production credential boundary without real items or network
// commands. Legacy Keychain ACL checks can ignore the SecItem query's UI flag.
#include "../native/continuum_native.h"
#include <Security/Security.h>
#include <spawn.h>
#include <cerrno>
#include <cstdio>
#include <cstring>

static Boolean interaction_allowed = true;
static bool policy_available = true;
static bool credential_available = false;
static bool prompted = false;
static bool called = false;
static bool spawned = false;
static int failures = 0;

static void check(bool ok, const char *reason) {
    if (!ok) {
        std::fprintf(stderr, "COMMISSION_KEYCHAIN_RED %s\n", reason);
        failures++;
    }
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
extern "C" OSStatus SecKeychainGetUserInteractionAllowed(Boolean *state) {
    *state = interaction_allowed;
    return errSecSuccess;
}
extern "C" OSStatus SecKeychainSetUserInteractionAllowed(Boolean state) {
    if (!policy_available) return errSecNotAvailable;
    interaction_allowed = state;
    return errSecSuccess;
}
extern "C" OSStatus SecItemCopyMatching(CFDictionaryRef, CFTypeRef *result) {
    called = true;
    *result = nullptr;
    if (credential_available) {
        const char value[] = "test-only-authorized";
        *result = CFDataCreate(nullptr, (const UInt8 *)value, sizeof value - 1);
        return errSecSuccess;
    }
    // Model the legacy ACL behavior, independently of the SecItem query flag.
    prompted = interaction_allowed;
    return errSecInteractionNotAllowed;
}
#pragma clang diagnostic pop

extern "C" int posix_spawn(pid_t *, const char *, const posix_spawn_file_actions_t *,
                           const posix_spawnattr_t *, char *const [], char *const []) {
    spawned = true;
    return EACCES;
}

int main() {
    const char request[] = "{\"host\":\"127.0.0.1\",\"port\":9,\"bind_addr\":\"\","
        "\"admin_user\":\"admin\",\"admin_ref\":\"continuum.test.unavailable\","
        "\"action\":\"inspect\"}";
    uint8_t receipt[1024]{};
    int64_t length = 0;
    int32_t rc = ct_asus_commission(
        {(const uint8_t *)request, (int64_t)std::strlen(request)},
        {receipt, sizeof receipt}, &length);
    check(called && !prompted && rc == CT_REJECTED && length > 0,
          "unattended commissioning must refuse legacy ACL access without UI");
    check(interaction_allowed, "quiet read must restore the owner's interaction policy");

    const char ref[] = "continuum.test.unavailable";
    ct_bytes reference{(const uint8_t *)ref, sizeof ref - 1};
    credential_available = true;
    length = 0;
    rc = ct_vault_fetch_quiet(reference, {receipt, sizeof receipt}, &length);
    check(rc == CT_OK && length == 20 &&
          std::memcmp(receipt, "test-only-authorized", 20) == 0 && interaction_allowed,
          "already authorized credentials must remain readable without UI");

    credential_available = false;
    policy_available = false;
    prompted = called = false;
    rc = ct_vault_fetch_quiet(reference, {receipt, sizeof receipt}, &length);
    check(rc != CT_OK && !called && !prompted && interaction_allowed,
          "failure to suppress interaction must refuse before the credential read");
    policy_available = true;

    interaction_allowed = false;
    prompted = false;
    rc = ct_vault_fetch_quiet(reference, {receipt, sizeof receipt}, &length);
    check(rc != CT_OK && !prompted && !interaction_allowed,
          "quiet read must not enable interaction that was already disabled");

    interaction_allowed = true;
    rc = ct_vault_fetch(reference, {receipt, sizeof receipt}, &length);
    check(rc != CT_OK && prompted && interaction_allowed,
          "explicit owner authorization must retain its interactive boundary");

    const char rejoin[] = "{\"interface\":\"en0\",\"ssid\":\"TestOnly_5G\","
        "\"psk_ref\":\"continuum.test.unavailable\",\"prefix\":\"192.168.50.\",\"wait_sec\":0}";
    prompted = spawned = called = false;
    rc = ct_host_rejoin({(const uint8_t *)rejoin, sizeof rejoin - 1},
                        {receipt, sizeof receipt}, &length);
    check(rc != CT_OK && called && !prompted && !spawned && interaction_allowed,
          "automatic rejoin must refuse unavailable credentials before UI or Wi-Fi changes");

    if (failures) return 1;
    std::puts("COMMISSION_KEYCHAIN_GREEN legacy ACL refusal, authorized reads and rejoin preflight");
    return 0;
}
