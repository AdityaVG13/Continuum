// Execute authored local logic, never device effects. Stdout describes intents
// that Goose validates and sends through its ordinary capability guardian.
// macOS uses Seatbelt; Linux requires bubblewrap with user/PID/network namespaces.
// Missing isolation is a refusal, not a fallback to an unrestricted shell.
#include "continuum_native.h"
#include <algorithm>
#include <cerrno>
#include <csignal>
#include <cstring>
#include <fcntl.h>
#include <poll.h>
#include <string>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>
#if defined(__APPLE__)
#include <sys/sysctl.h>
#include <libproc.h>
#elif defined(__linux__)
#include <filesystem>
#include <fstream>
#endif

namespace {
// These utilities cannot create a session or run arbitrary bytecode. In
// particular, general-purpose interpreters/osascript/ssh are not executable.
// Shell control flow and text processing remain model-authored, not recipes.
const char *const tools[] = {"/bin/sh", "/bin/bash", "/bin/cat", "/usr/bin/awk", "/usr/bin/wc",
    "/usr/bin/sed", "/usr/bin/tr", "/usr/bin/cut", "/usr/bin/sort",
    "/usr/bin/uniq", "/usr/bin/grep", "/usr/bin/printf", "/usr/bin/env",
    "/usr/bin/true", "/usr/bin/false", "/usr/bin/sleep", "/usr/bin/head"};
rlim_t process_ceiling() {
    // RLIMIT_NPROC is UID-wide but inherited per process. Give this tree a
    // small allowance above current usage without limiting unrelated parents.
    rlim_t count = 1;
#if defined(__APPLE__)
    int mib[] = {CTL_KERN, KERN_PROC, KERN_PROC_UID, static_cast<int>(geteuid())};
    size_t bytes = 0;
    if (sysctl(mib, 4, nullptr, &bytes, nullptr, 0) != 0) return 0;
    count = bytes / sizeof(kinfo_proc);
#elif defined(__linux__)
    std::error_code error;
    for (const auto &entry : std::filesystem::directory_iterator("/proc", error)) {
        const auto name = entry.path().filename().string();
        if (name.empty() || name.find_first_not_of("0123456789") != std::string::npos) continue;
        struct stat st{};
        if (stat(entry.path().c_str(), &st) != 0 || st.st_uid != geteuid()) continue;
        std::ifstream status(entry.path() / "status"); std::string line;
        while (std::getline(status, line)) if (line.rfind("Threads:", 0) == 0) {
            try { count += std::stoul(line.substr(8)); } catch (...) { return 0; }
            break;
        }
    }
    if (error) return 0;
#else
    return 0;
#endif
    struct rlimit old{};
    if (getrlimit(RLIMIT_NPROC, &old) != 0) return 0;
    return std::min(count + 16, old.rlim_max);
}
bool memory_admitted(pid_t group) {
#if defined(__APPLE__)
    // Darwin does not implement DATA/AS limits. Bound the process tree's RSS
    // at the same 10 ms observation boundary as cancellation, not a fake rlimit.
    pid_t members[32] = {};
    const int bytes = proc_listpgrppids(group, members, sizeof members);
    if (bytes < 0 || bytes >= static_cast<int>(sizeof members)) return false;
    uint64_t retained = 0;
    for (int i = 0; i < bytes / static_cast<int>(sizeof(pid_t)); ++i) {
        struct proc_taskinfo info{};
        if (proc_pidinfo(members[i], PROC_PIDTASKINFO, 0, &info, sizeof info) == sizeof info)
            retained += info.pti_resident_size;
    }
    return retained <= 64 * 1024 * 1024;
#else
    (void)group; return true; // Linux applies the kernel DATA bound below.
#endif
}
bool limit(int resource, rlim_t value) {
    const struct rlimit bound{value, value};
    return setrlimit(resource, &bound) == 0;
}
}
extern "C" int32_t ct_program_execute(ct_bytes source, ct_bytes input, int64_t timeout_ms,
                                       ct_output out, int64_t *length) {
    if (!length || !source.data || source.len < 1 || source.len > 1024 ||
            !input.data || input.len < 1 || input.len > 16384 || !out.data || out.capacity < 4096 ||
            timeout_ms < 100 || timeout_ms > 10000 ||
            std::memchr(source.data, 0, static_cast<size_t>(source.len)) ||
            std::memchr(input.data, 0, static_cast<size_t>(input.len))) return CT_INVALID_ARGUMENT;
    *length = 0;
    const std::string code(reinterpret_cast<const char *>(source.data), static_cast<size_t>(source.len));
    const std::string context = "CONTINUUM_INPUT=" + std::string(reinterpret_cast<const char *>(input.data), static_cast<size_t>(input.len));
    std::vector<std::string> arguments;
#if defined(__APPLE__)
    if (access("/usr/bin/sandbox-exec", X_OK) != 0) return CT_NOT_IMPLEMENTED;
    std::string profile = "(version 1)(deny default)(allow process-fork)(allow sysctl-read)"
        "(allow file-read-metadata)(allow file-read* (subpath \"/System\") (subpath \"/usr/lib\")"
        " (subpath \"/usr/share\") (subpath \"/Library/Apple\") (literal \"/\")"
        " (literal \"/dev/null\") (literal \"/dev/urandom\"))"
        "(allow file-write-data (literal \"/dev/null\"))";
    for (const auto *tool : tools) {
        profile += "(allow process-exec file-read* (literal \"" + std::string(tool) + "\"))";
    }
    arguments = {"/usr/bin/sandbox-exec", "-p", profile, "/bin/sh", "-c", code};
#elif defined(__linux__)
    if (access("/usr/bin/bwrap", X_OK) != 0) return CT_NOT_IMPLEMENTED;
    arguments = {"/usr/bin/bwrap", "--unshare-all", "--die-with-parent", "--new-session",
        "--cap-drop", "ALL", "--clearenv", "--setenv", "PATH", "/usr/bin:/bin",
        "--setenv", "LC_ALL", "C", "--setenv", "CONTINUUM_INPUT", context.substr(16),
        "--proc", "/proc", "--dev", "/dev", "--dir", "/bin", "--dir", "/usr",
        "--dir", "/usr/bin", "--dir", "/etc"};
    for (const auto *path : {"/usr/lib", "/lib", "/lib64", "/etc/ld.so.cache"}) {
        if (access(path, R_OK) == 0) arguments.insert(arguments.end(), {"--ro-bind", path, path});
    }
    for (const auto *tool : tools) if (access(tool, X_OK) == 0)
        arguments.insert(arguments.end(), {"--ro-bind", tool, tool});
    arguments.insert(arguments.end(), {"--chdir", "/", "/bin/sh", "-c", code});
#else
    return CT_NOT_IMPLEMENTED;
#endif
    std::vector<char *> argv;
    for (auto &argument : arguments) argv.push_back(argument.data());
    argv.push_back(nullptr);
    char path[] = "PATH=/usr/bin:/bin", locale[] = "LC_ALL=C";
    char *const environment[] = {path, locale, const_cast<char *>(context.c_str()), nullptr};
    const rlim_t processes = process_ceiling();
    if (!processes) return CT_FAILED;
    const long descriptor_limit = sysconf(_SC_OPEN_MAX);
    if (descriptor_limit < 3) return CT_FAILED;
    int fds[2];
    if (pipe(fds) != 0) return CT_FAILED;
    for (int fd : fds) fcntl(fd, F_SETFD, FD_CLOEXEC);
    const pid_t child = fork();
    if (child == 0) {
        if (setpgid(0, 0) != 0 || chdir("/") != 0) _exit(126);
        int null = open("/dev/null", O_RDWR);
        if (null < 0 || dup2(null, STDIN_FILENO) < 0 || dup2(fds[1], STDOUT_FILENO) < 0 ||
                dup2(null, STDERR_FILENO) < 0) _exit(126);
        // The sandbox cannot inherit a vault/device socket or the parent's
        // API credential. A failed limit must not run less-constrained code.
        for (int fd = 3; fd < descriptor_limit; ++fd) close(fd);
        if (!limit(RLIMIT_CORE, 0) || !limit(RLIMIT_FSIZE, 0) || !limit(RLIMIT_NOFILE, 64) ||
                !limit(RLIMIT_NPROC, processes) || !limit(RLIMIT_CPU, 1 + timeout_ms / 1000)) _exit(126);
#if defined(__linux__)
        if (!limit(RLIMIT_DATA, 64 * 1024 * 1024)) _exit(126);
#endif
        execve(argv[0], argv.data(), environment);
        _exit(127);
    }
    close(fds[1]);
    if (child < 0) { close(fds[0]); return CT_FAILED; }
    setpgid(child, child);
    fcntl(fds[0], F_SETFL, O_NONBLOCK);
    const int64_t deadline = ct_service_now_ms() + timeout_ms;
    int status = 0; bool done = false, failed = false, eof = false;
    while (!done || !eof) {
        char buffer[4096];
        const ssize_t count = read(fds[0], buffer, sizeof buffer);
        if (count > 0) {
            if (*length + count > 4096) { failed = true; break; }
            std::memcpy(out.data + *length, buffer, static_cast<size_t>(count)); *length += count;
        } else if (count == 0) { eof = true; }
        else if (errno != EAGAIN && errno != EINTR) { failed = true; break; }
        if (!done) {
            const pid_t ended = waitpid(child, &status, WNOHANG);
            if (ended == child) done = true;
            else if (ended < 0 && errno != EINTR) { failed = true; break; }
        }
        if (done && eof) break;
        // Also drain on service cancellation, without changing foreground
        // signal handlers or leaving a second resident execution mechanism.
        if (ct_service_now_ms() >= deadline || ct_service_wait(0) == CT_EXPIRED || !memory_admitted(child)) { failed = true; break; }
        pollfd ready{fds[0], POLLIN, 0}; poll(&ready, 1, 10);
    }
    // No child may outlive its invocation, including a shell background job.
    kill(-child, SIGKILL);
    if (!done) while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    close(fds[0]);
    return !failed && WIFEXITED(status) && WEXITSTATUS(status) == 0 && *length > 0 ? CT_OK : CT_FAILED;
}
