// Process lifetime and bounded status storage; service policy stays in Goose.
#include "continuum_native.h"
#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstring>
#include <filesystem>
#include <fcntl.h>
#include <poll.h>
#include <string>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace {
int directory_fd = -1, lock_fd = -1, wake_read = -1;
int device_directory_fd = -1, device_lock_fd = -1;
bool device_exclusive = false;
volatile sig_atomic_t wake_write = -1, stopped = 0;
struct sigaction old_term{}, old_int{};
constexpr int64_t status_limit = 16384;
void stop_service(int) {
    const int saved = errno;
    stopped = 1;
    const uint8_t byte = 1;
    if (wake_write >= 0) { const auto ignored = write(wake_write, &byte, 1); (void)ignored; }
    errno = saved;
}
bool private_regular(int fd) {
    struct stat st{};
    return fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == geteuid() &&
           (st.st_mode & 0077) == 0 && st.st_nlink == 1;
}
}

extern "C" int64_t ct_service_now_ms(void) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}
extern "C" int64_t ct_service_wall_ms(void) {
    return std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
}
extern "C" int64_t ct_service_pid(void) { return getpid(); }
extern "C" int32_t ct_service_close(void) {
    if (directory_fd >= 0) {
        sigaction(SIGTERM, &old_term, nullptr);
        sigaction(SIGINT, &old_int, nullptr);
    }
    const int writer = wake_write; wake_write = -1;
    for (int fd : {wake_read, writer, lock_fd, directory_fd}) if (fd >= 0) close(fd);
    wake_read = lock_fd = directory_fd = -1;
    return CT_OK;
}
extern "C" int32_t ct_service_open(ct_bytes path_bytes) {
    if (directory_fd >= 0 || !path_bytes.data || path_bytes.len <= 0 || path_bytes.len > 1024 ||
        path_bytes.data[0] != '/' || std::memchr(path_bytes.data, 0, static_cast<size_t>(path_bytes.len)))
        return CT_INVALID_ARGUMENT;
    const std::string path(reinterpret_cast<const char *>(path_bytes.data), static_cast<size_t>(path_bytes.len));
    std::error_code error;
    bool created = std::filesystem::create_directories(path, error);
    if (error || (created && chmod(path.c_str(), 0700) != 0)) return CT_FAILED;
    int parent = open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat st{};
    if (parent < 0) return CT_FAILED;
    if (fstat(parent, &st) != 0 || st.st_uid != geteuid() || (st.st_mode & 0077) != 0) {
        close(parent); return CT_REJECTED;
    }
    int lock = openat(parent, "service.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (lock < 0 || !private_regular(lock) || flock(lock, LOCK_EX | LOCK_NB) != 0) {
        if (lock >= 0) close(lock);
        close(parent); return CT_REJECTED;
    }
    int fds[2];
    if (pipe(fds) != 0) { close(lock); close(parent); return CT_FAILED; }
    for (int fd : fds) {
        if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0 || fcntl(fd, F_SETFL, O_NONBLOCK) != 0) {
            close(fds[0]); close(fds[1]); close(lock); close(parent); return CT_FAILED;
        }
    }
    stopped = 0; wake_read = fds[0]; wake_write = fds[1];
    struct sigaction action{};
    action.sa_handler = stop_service;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, &old_term) != 0) {
        close(fds[0]); close(fds[1]); close(lock); close(parent);
        wake_write = wake_read = -1; return CT_FAILED;
    }
    if (sigaction(SIGINT, &action, &old_int) != 0) {
        sigaction(SIGTERM, &old_term, nullptr);
        close(fds[0]); close(fds[1]); close(lock); close(parent);
        wake_write = wake_read = -1; return CT_FAILED;
    }
    directory_fd = parent; lock_fd = lock;
    return CT_OK;
}
extern "C" int32_t ct_service_wait(int64_t milliseconds) {
    if (directory_fd < 0 || milliseconds < 0 || milliseconds > 3600000) return CT_INVALID_ARGUMENT;
    const int64_t deadline = ct_service_now_ms() + milliseconds;
    while (!stopped) {
        const int64_t remaining = deadline - ct_service_now_ms();
        if (remaining <= 0) return CT_OK;
        pollfd fd{wake_read, POLLIN, 0};
        const int result = poll(&fd, 1, static_cast<int>(remaining));
        if (result < 0 && errno != EINTR) return CT_FAILED;
        if (result > 0 && !stopped) return CT_FAILED;
    }
    return CT_EXPIRED;
}
namespace {
int32_t load_record(int parent, const char *name, ct_output out, int64_t *length, int64_t limit = status_limit) {
    if (!length || parent < 0 || !out.data || out.capacity < limit) return CT_INVALID_ARGUMENT;
    *length = 0;
    int fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return errno == ENOENT ? CT_OK : CT_FAILED;
    struct stat st{};
    if (!private_regular(fd) || fstat(fd, &st) != 0 || st.st_size <= 0 || st.st_size > limit) {
        close(fd); return CT_REJECTED;
    }
    while (*length < st.st_size) {
        const ssize_t n = read(fd, out.data + *length, static_cast<size_t>(st.st_size - *length));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return CT_FAILED; }
        *length += n;
    }
    close(fd); return CT_OK;
}
int32_t store_record(int parent, const char *name, const char *pending, ct_bytes data, int32_t durable, int64_t limit = status_limit) {
    if (parent < 0 || !data.data || data.len <= 0 || data.len > limit) return CT_INVALID_ARGUMENT;
    int fd = openat(parent, pending, O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return CT_FAILED;
    bool ok = private_regular(fd) && ftruncate(fd, 0) == 0;
    int64_t done = 0;
    while (ok && done < data.len) {
        const ssize_t n = write(fd, data.data + done, static_cast<size_t>(data.len - done));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) ok = false;
        else done += n;
    }
    if (ok && durable) ok = fsync(fd) == 0;
    if (close(fd) != 0) ok = false;
    if (ok) ok = renameat(parent, pending, parent, name) == 0;
    if (ok && durable) ok = fsync(parent) == 0;
    return ok ? CT_OK : CT_FAILED;
}
} // namespace

extern "C" int32_t ct_service_load(ct_output out, int64_t *length) {
    return load_record(directory_fd, "status.json", out, length);
}
extern "C" int32_t ct_service_store(ct_bytes data, int32_t durable) {
    return store_record(directory_fd, "status.json", ".status.pending", data, durable);
}

// Observations/tool conversations hold a shared binding lock. Setup/retarget
// needs an exclusive lock, preventing target changes during protected reads.
// A process crash releases the lock, not the persisted recovery phase.
extern "C" int32_t ct_device_open(ct_bytes path_bytes, int32_t exclusive) {
    if (device_directory_fd >= 0 || !path_bytes.data || path_bytes.len <= 0 || path_bytes.len > 1024 ||
        path_bytes.data[0] != '/' || std::memchr(path_bytes.data, 0, static_cast<size_t>(path_bytes.len)) ||
        (exclusive != 0 && exclusive != 1)) return CT_INVALID_ARGUMENT;
    const std::string path(reinterpret_cast<const char *>(path_bytes.data), static_cast<size_t>(path_bytes.len));
    std::error_code error;
    const bool created = std::filesystem::create_directories(path, error);
    if (error || (created && chmod(path.c_str(), 0700) != 0)) return CT_FAILED;
    int parent = open(path.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat st{};
    if (parent < 0) return CT_FAILED;
    if (fstat(parent, &st) != 0 || st.st_uid != geteuid() || (st.st_mode & 0077) != 0) {
        close(parent); return CT_REJECTED;
    }
    int lock = openat(parent, "device.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (lock < 0 || !private_regular(lock) || flock(lock, (exclusive ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0) {
        if (lock >= 0) close(lock);
        close(parent); return CT_REJECTED;
    }
    device_directory_fd = parent; device_lock_fd = lock; device_exclusive = exclusive == 1;
    return CT_OK;
}
extern "C" int32_t ct_device_close(void) {
    if (device_lock_fd >= 0) close(device_lock_fd);
    if (device_directory_fd >= 0) close(device_directory_fd);
    device_lock_fd = device_directory_fd = -1; device_exclusive = false;
    return CT_OK;
}
extern "C" int32_t ct_device_load(ct_output out, int64_t *length) {
    return load_record(device_directory_fd, "state.json", out, length);
}
extern "C" int32_t ct_programs_load(ct_output out, int64_t *length) {
    return load_record(device_directory_fd, "programs.json", out, length, 65536);
}
extern "C" int32_t ct_programs_store(ct_bytes data) {
    if (!device_exclusive) return CT_REJECTED;
    return store_record(device_directory_fd, "programs.json", ".programs.pending", data, 1, 65536);
}
extern "C" int32_t ct_owner_load(ct_output out, int64_t *length) {
    return load_record(device_directory_fd, "owner.json", out, length, 8192);
}
extern "C" int32_t ct_owner_store(ct_bytes data) {
    if (!device_exclusive) return CT_REJECTED;
    return store_record(device_directory_fd, "owner.json", ".owner.pending", data, 1, 8192);
}
extern "C" int32_t ct_device_store(ct_bytes data) {
    if (!device_exclusive) return CT_REJECTED;
    return store_record(device_directory_fd, "state.json", ".state.pending", data, 1);
}
