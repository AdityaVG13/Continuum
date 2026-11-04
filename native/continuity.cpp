// Private, bounded POSIX file boundary for the Goose task checkpoint.
// Task meaning, input equality and independent validation remain in Goose.
#include "continuum_native.h"
#include <cerrno>
#include <cstring>
#include <filesystem>
#include <fcntl.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

namespace {
constexpr int64_t limit = 65536;
bool path_text(ct_bytes bytes, std::string &path) {
    if (!bytes.data || bytes.len <= 0 || bytes.len > 1024 || bytes.data[0] != '/' ||
        std::memchr(bytes.data, 0, static_cast<size_t>(bytes.len))) return false;
    path.assign(reinterpret_cast<const char *>(bytes.data), static_cast<size_t>(bytes.len));
    return true;
}
bool private_file(int fd, struct stat &st) {
    return fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == geteuid() &&
           (st.st_mode & 0077) == 0 && st.st_nlink == 1;
}
}

extern "C" {
// These structs are the same pointer+i64 layout as Goose's byte slices.
int32_t ct_checkpoint_read(ct_bytes path_bytes, ct_output out, int64_t *length) {
    if (!length) return CT_INVALID_ARGUMENT;
    *length = 0;
    std::string path;
    if (!path_text(path_bytes, path) || !out.data || out.capacity < limit) return CT_INVALID_ARGUMENT;
    int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return CT_FAILED;
    struct stat st{};
    if (!private_file(fd, st) || st.st_size <= 0 || st.st_size > limit) { close(fd); return CT_REJECTED; }
    int64_t n = 0;
    while (n < st.st_size) {
        ssize_t got = read(fd, out.data + n, static_cast<size_t>(st.st_size - n));
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) { close(fd); return CT_FAILED; }
        n += got;
    }
    uint8_t extra = 0;
    ssize_t tail = read(fd, &extra, 1);
    close(fd);
    if (tail != 0) return CT_REJECTED;
    *length = n;
    return CT_OK;
}

int32_t ct_checkpoint_write(ct_bytes path_bytes, ct_bytes data) {
    std::string path;
    if (!path_text(path_bytes, path) || !data.data || data.len <= 0 || data.len > limit) return CT_INVALID_ARGUMENT;
    const auto slash = path.rfind('/');
    const std::string directory = path.substr(0, slash);
    std::error_code error;
    bool created = std::filesystem::create_directories(directory, error);
    if (error || (created && chmod(directory.c_str(), 0700) != 0)) return CT_FAILED;
    int parent = open(directory.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat st{};
    if (parent < 0) return CT_FAILED;
    if (fstat(parent, &st) != 0 || st.st_uid != geteuid() || (st.st_mode & 0077) != 0) {
        close(parent); return CT_REJECTED;
    }
    const std::string name = path.substr(slash + 1);
    // A run is immutable. linkat publishes without replacing an earlier commit,
    // including when two processes accidentally choose the same run identity.
    std::string pending = directory + "/.pending-XXXXXX";
    int fd = mkstemp(pending.data());
    if (fd < 0) { close(parent); return CT_FAILED; }
    bool ok = fchmod(fd, 0600) == 0;
    int64_t n = 0;
    while (ok && n < data.len) {
        ssize_t written = write(fd, data.data + n, static_cast<size_t>(data.len - n));
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) ok = false;
        else n += written;
    }
    if (ok) ok = fsync(fd) == 0;
    if (close(fd) != 0) ok = false;
    if (ok) ok = linkat(AT_FDCWD, pending.c_str(), parent, name.c_str(), 0) == 0;
    // Only our own unpublished staging name is removed; no prior artifact is
    // overwritten or removed. A process crash may leave an inert staging file.
    if (unlink(pending.c_str()) != 0) ok = false;
    if (ok) ok = fsync(parent) == 0;
    close(parent);
    return ok ? CT_OK : CT_FAILED;
}
}
