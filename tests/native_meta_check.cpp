// Native Meta credential lifecycle regression. Only a synthetic key and a
// refused loopback connection are used: no provider request, no real secret.
#include "../native/continuum_native.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/wait.h>
#include <unistd.h>

static void check(bool ok, const char *label) {
    if (!ok) {
        std::fprintf(stderr, "FAIL %s\n", label);
        std::exit(1);
    }
    std::printf("ok %s\n", label);
}

static ct_bytes bytes(const char *s) {
    return {reinterpret_cast<const uint8_t *>(s),
            static_cast<int64_t>(std::strlen(s))};
}

int main() {
    constexpr const char *name = "CONTINUUM_TEST_META_KEY";
    constexpr const char *key = "synthetic-credential-not-a-secret";
    check(setenv(name, key, 1) == 0, "synthetic credential staged");
    const char *config =
        "{\"api_key_env\":\"CONTINUUM_TEST_META_KEY\","
        "\"base_url\":\"https://127.0.0.1:1\","
        "\"timeout_ms\":1000,\"max_bytes\":32768}";
    const char *request = "{\"path\":\"/responses\",\"body\":{}}";
    ct_handle handle = 0;
    check(ct_meta_open(bytes(config), &handle) == CT_OK && handle != 0,
          "transport opens with credential source name");
    for (int turn = 0; turn < 2; ++turn) {
        uint64_t request_id = 0;
        check(ct_meta_submit(handle, bytes(request), &request_id) == CT_OK &&
                  request_id != 0,
              "each turn reaches the transport");
        const char *after = std::getenv(name);
        check(after && std::strcmp(after, key) == 0,
              "submission does not mutate the credential environment");
        uint8_t buffer[33792] = {};
        int64_t size = 0;
        check(ct_meta_poll(handle, {buffer, sizeof buffer}, &size) == CT_OK &&
                  size > 0,
              "failed connection returns an envelope");
        check(std::strstr(reinterpret_cast<const char *>(buffer),
                          "\"status\":0") != nullptr,
              "refused connection does not claim provider success");
    }
    check(ct_meta_close(handle) == CT_OK, "transport closes");
    // A setup request and the resident monitor are independent processes.
    // Both allocate the same numeric handle after fork. Closing one must not
    // erase or replace the other's configuration or pending response.
    int ready[2];
    check(pipe(ready) == 0, "process-isolation barrier opens");
    std::fflush(stdout);
    const pid_t other = fork();
    check(other >= 0, "independent transport process starts");
    if (other == 0) {
        close(ready[1]);
        char start = 0;
        if (read(ready[0], &start, 1) != 1) _exit(2);
        close(ready[0]);
        ct_handle own = 0;
        const bool ok = ct_meta_open(bytes(config), &own) == CT_OK && ct_meta_close(own) == CT_OK;
        _exit(ok ? 0 : 3);
    }
    close(ready[0]);
    check(ct_meta_open(bytes(config), &handle) == CT_OK, "resident transport opens before setup completes");
    check(write(ready[1], "x", 1) == 1, "setup transport is released");
    close(ready[1]);
    int status = 0;
    check(waitpid(other, &status, 0) == other && WIFEXITED(status) && WEXITSTATUS(status) == 0,
          "independent setup transport closes");
    uint64_t request_id = 0;
    check(ct_meta_submit(handle, bytes(request), &request_id) == CT_OK && request_id > 0,
          "another process cannot invalidate an open Meta transport");
    uint8_t result[33792] = {};
    int64_t length = 0;
    check(ct_meta_poll(handle, {result, sizeof result}, &length) == CT_OK && length > 0,
          "resident request retains its own response envelope");
    check(ct_meta_close(handle) == CT_OK, "isolated resident transport closes");
    check(unsetenv(name) == 0, "synthetic credential cleared");
    std::puts("NATIVE_META_ALL_GREEN");
}
