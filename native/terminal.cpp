// POSIX terminal/credential boundary. Goose owns screens and decisions;
// secret input stays native and is never returned through the FFI.
#include "continuum_native.h"
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <termios.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

#include <algorithm>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {
termios previous{};
bool active = false;
volatile sig_atomic_t interrupted = 0;
volatile sig_atomic_t resized = 0;
struct sigaction old_int{}, old_term{}, old_winch{};
pid_t job_pid = -1;
int job_fd = -1;
std::string job_output;
const char *key_ref = "continuum.meta.MODEL_API_KEY";

ct_bytes bytes(const std::string &s) { return {reinterpret_cast<const uint8_t *>(s.data()), static_cast<int64_t>(s.size())}; }
void wipe(std::string &s) { volatile char *p = s.empty() ? nullptr : &s[0]; for (size_t i = 0; i < s.size(); ++i) p[i] = 0; }
int put(ct_output out, int64_t *n, const std::string &s) {
    if (!out.data || !n || out.capacity <= 0) return CT_INVALID_ARGUMENT;
    *n = 0;
    if (static_cast<int64_t>(s.size()) > out.capacity) return CT_BUFFER_TOO_SMALL;
    std::memcpy(out.data, s.data(), s.size()); *n = static_cast<int64_t>(s.size());
    return CT_OK;
}
void stop_job() {
    if (job_pid > 0) {
        // The group belongs to the child we started; cancel its curl too.
        kill(-job_pid, SIGTERM);
        int status = 0;
        for (int i = 0; i < 20; ++i) {
            if (waitpid(job_pid, &status, WNOHANG) == job_pid) { job_pid = -1; break; }
            usleep(10000);
        }
        if (job_pid > 0) { kill(-job_pid, SIGKILL); waitpid(job_pid, &status, 0); job_pid = -1; }
    }
    if (job_fd >= 0) close(job_fd);
    job_fd = -1;
}
void restore() {
    stop_job();
    if (!active) return;
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &previous);
    std::fputs("\033[0m\033[?25h\033[?1049l", stdout);
    std::fflush(stdout);
    active = false;
    sigaction(SIGINT, &old_int, nullptr);
    sigaction(SIGTERM, &old_term, nullptr);
    sigaction(SIGWINCH, &old_winch, nullptr);
}
void on_signal(int) { interrupted = 1; }
void on_resize(int) { resized = 1; }
int key(int timeout) {
    if (interrupted) return 3;
    if (resized) { resized = 0; return 256; }
    pollfd fd{STDIN_FILENO, POLLIN, 0};
    int ready = poll(&fd, 1, timeout);
    if (interrupted) return 3;
    if (resized) { resized = 0; return 256; }
    if (ready <= 0) return ready == 0 ? 0 : -1;
    unsigned char c = 0;
    if (read(STDIN_FILENO, &c, 1) != 1) return -1;
    if (c == 3) interrupted = 1;
    if (c != 27) return c;
    // Escape alone cancels in forms; CSI sequences (arrows, PgUp/PgDn) must
    // collapse to one code so their digits never act as section keys.
    pollfd next{STDIN_FILENO, POLLIN, 0};
    if (poll(&next, 1, 50) <= 0) return 27;
    unsigned char b = 0;
    if (next.revents & POLLIN) read(STDIN_FILENO, &b, 1);
    if (b != '[') return 27;
    pollfd fin{STDIN_FILENO, POLLIN, 0};
    if (poll(&fin, 1, 50) <= 0 || !(fin.revents & POLLIN)) return 27;
    unsigned char f = 0;
    read(STDIN_FILENO, &f, 1);
    if (f == 'A') return 261;
    if (f == 'B') return 262;
    if (f == 'C') return 263;
    if (f == 'D') return 264;
    if (f == 'H') return 260;
    if (f == 'F') return 267;
    if (f == '5' || f == '6' || f == '3') {
        pollfd tilde{STDIN_FILENO, POLLIN, 0};
        if (poll(&tilde, 1, 50) <= 0 || !(tilde.revents & POLLIN)) return 0;
        unsigned char t = 0;
        read(STDIN_FILENO, &t, 1);
        if (t != '~') return 0;
        if (f == '5') return 258;
        if (f == '6') return 259;
        return 265;
    }
    return 0;
}
std::vector<std::string> lines(const std::string &frame, int width) {
    std::vector<std::string> result;
    std::string logical;
    auto flush = [&]() {
        // Greedy word wrap: break at the last space within width so words
        // never split; hard-break only for space-free runs longer than width.
        size_t pos = 0;
        while (logical.size() - pos > static_cast<size_t>(width)) {
            size_t cut = logical.find_last_of(' ', pos + static_cast<size_t>(width));
            if (cut == std::string::npos || cut <= pos) cut = pos + static_cast<size_t>(width);
            result.push_back(logical.substr(pos, cut - pos));
            pos = cut;
            while (pos < logical.size() && logical[pos] == ' ') ++pos;
        }
        result.push_back(logical.substr(pos));
        logical.clear();
    };
    for (unsigned char c : frame) {
        if (c == '\n') { flush(); continue; }
        // Terminal/device/model data is not terminal code. ASCII is deliberate
        // here: fixed-width clipping must not cut a UTF-8 control sequence.
        logical += c >= 32 && c < 127 ? char(c) : '?';
    }
    if (!logical.empty()) flush();
    return result;
}
void draw(const std::string &frame, int scroll = 0) {
    winsize size{};
    ioctl(STDOUT_FILENO, TIOCGWINSZ, &size);
    int columns = size.ws_col ? size.ws_col : 80;
    int rows = size.ws_row ? size.ws_row : 24;
    std::fputs("\033[H\033[2J", stdout);
    if (columns < 60 || rows < 18) {
        std::fputs("Continuum needs at least 60 columns x 18 rows.\r\nResize the terminal; q exits.\r\n", stdout);
        std::fflush(stdout); return;
    }
    auto content = lines(frame, columns - 2);
    bool color = !std::getenv("NO_COLOR");
    // Pin the header and footer; only the detail region scrolls.
    // Goose footers are 3 logical lines (nav hints + 2 contextual rows).
    size_t head = std::min<size_t>(4, content.size());
    size_t foot = content.size() > head + 2 ? 3 : 0;
    auto row = [&](const std::string &s, bool accent) {
        if (accent && color) std::fputs("\033[1;36m", stdout);
        std::printf(" %s\r\n", s.c_str());
        if (accent && color) std::fputs("\033[0m", stdout);
    };
    for (size_t i = 0; i < head; ++i) row(content[i], i == 0);
    int room = rows - static_cast<int>(head + foot) - 1;
    size_t end = content.size() - foot;
    size_t first = std::min(head + static_cast<size_t>(std::max(0, scroll)), end);
    int shown = 0;
    for (size_t i = first; i < end && shown < room; ++i, ++shown) row(content[i], false);
    while (shown++ < room) row("", false);
    for (size_t i = end; i < content.size(); ++i) row(content[i], false);
    std::fflush(stdout);
}
int edit(const std::string &label, const std::string &initial, bool secret, std::string &value, size_t max_bytes = 128) {
    value = initial;
    bool invalid = false;
    for (;;) {
        draw(std::string("CONTINUUM / ") + (secret ? "PRIVATE INPUT" : "INPUT") + "\n----------------------------------------\n" + label +
             (secret ? "\nPrivate local input; never sent to the model.\n\n " :
                       "\nNon-secret input. Do not enter passwords or API keys.\n\n ") +
             (secret ? std::string(value.size(), '*') : value) +
             "\n\n[Enter] submit   [Esc] cancel\n[Ctrl-U] clear   [Backspace] edit");
        int c = key(-1);
        if (c == 3 || c == 27 || c < 0) { wipe(value); return CT_REJECTED; }
        if (c == '\r' || c == '\n') {
            tcflush(STDIN_FILENO, TCIFLUSH);
            if (invalid || value.empty()) { wipe(value); return CT_INVALID_ARGUMENT; }
            return CT_OK;
        }
        if (c == 21) { wipe(value); value.clear(); invalid = false; }
        else if (c == 127 || c == 8) { if (!value.empty()) { value.back() = 0; value.pop_back(); } }
        else if (c >= 32 && c < 127 && (!secret || c > 32)) {
            size_t limit = secret ? 4096 : max_bytes;
            if (value.size() < limit) value += char(c); else invalid = true;
        } else if (c) invalid = true;
    }
}
std::string executable() {
    char path[4096] = {};
#if defined(__APPLE__)
    uint32_t n = sizeof path;
    if (_NSGetExecutablePath(path, &n) != 0) return "";
#else
    if (readlink("/proc/self/exe", path, sizeof path - 1) <= 0) return "";
#endif
    return path;
}
} // namespace

extern "C" {
int32_t ct_tui_open() {
    const char *term = std::getenv("TERM");
    if (active || !isatty(STDIN_FILENO) || !isatty(STDOUT_FILENO) ||
        (term && std::strcmp(term, "dumb") == 0) || std::getenv("NO_TUI")) return CT_REJECTED;
    if (tcgetattr(STDIN_FILENO, &previous) != 0) return CT_FAILED;
    termios raw = previous;
    raw.c_lflag &= ~(ICANON | ECHO | ISIG);
    raw.c_iflag &= ~(IXON | ICRNL);
    raw.c_cc[VMIN] = 1; raw.c_cc[VTIME] = 0;
    if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) != 0) return CT_FAILED;
    active = true; interrupted = 0;
    struct sigaction action{};
    action.sa_handler = on_signal;
    sigemptyset(&action.sa_mask);
    sigaction(SIGINT, &action, &old_int);
    sigaction(SIGTERM, &action, &old_term);
    action.sa_handler = on_resize;
    sigaction(SIGWINCH, &action, &old_winch);
    std::atexit(restore);
    std::fputs("\033[?1049h\033[?25l", stdout);
    return CT_OK;
}
int32_t ct_tui_close() { restore(); return CT_OK; }
int32_t ct_tui_draw(ct_bytes frame, int64_t scroll) {
    if (!active || !frame.data || frame.len < 0 || frame.len > 40000) return CT_INVALID_ARGUMENT;
    draw(std::string(reinterpret_cast<const char *>(frame.data), static_cast<size_t>(frame.len)), static_cast<int>(std::min<int64_t>(scroll, 1000)));
    return CT_OK;
}
int32_t ct_tui_key(int64_t timeout_ms) { return key(static_cast<int>(std::clamp<int64_t>(timeout_ms, -1, 1000))); }
int32_t ct_tui_key_load() {
    const char *current = std::getenv("MODEL_API_KEY");
    if (current && *current) return 1;
    uint8_t buffer[4096] = {};
    int64_t n = 0;
    int result = 0;
    if (ct_vault_fetch(bytes(key_ref), {buffer, sizeof buffer}, &n) == CT_OK && n > 0 && n <= 4096) {
        std::string value(reinterpret_cast<char *>(buffer), static_cast<size_t>(n));
        // Reject header/control injection rather than silently repairing keys.
        bool valid = std::all_of(value.begin(), value.end(), [](unsigned char c) { return c > 32 && c < 127; });
        if (valid && setenv("MODEL_API_KEY", value.c_str(), 1) == 0) result = 2;
        wipe(value);
    }
    volatile uint8_t *p = buffer; for (size_t i = 0; i < sizeof buffer; ++i) p[i] = 0;
    return result;
}
int32_t ct_tui_key_setup() {
    if (!active) return CT_REJECTED;
    std::string value;
    int rc = edit("MODEL_API_KEY", "", true, value);
    if (rc != CT_OK) return rc;
#if defined(__APPLE__)
    draw("CONTINUUM / META SETUP\n----------------------------------------\nSave in Keychain? [y/N]\nThe key will never be written to settings or logs.\n\nNo keeps it only in this process and its jobs.\nYes stores it in this device's macOS login Keychain.\n\n[y] save securely   [n/Enter] session only\n[Esc] cancel");
#else
    draw("CONTINUUM / META SETUP\n----------------------------------------\nSecure persistence unavailable on this platform.\nThe key will never be written to settings or logs.\n\nKeep it only in this process and its jobs?\n\n[n/Enter] session only\n[Esc] cancel");
#endif
    int choice = 0;
    while (!(choice == 'y' || choice == 'Y' || choice == 'n' || choice == 'N' || choice == '\r' || choice == '\n' || choice == 3 || choice == 27 || choice < 0)) choice = key(-1);
    if (choice == 3 || choice == 27 || choice < 0) { wipe(value); return CT_REJECTED; }
    bool save = choice == 'y' || choice == 'Y';
    if (save) {
        uint8_t back[4096] = {};
        int64_t n = 0;
        rc = ct_vault_store(bytes(key_ref), bytes(value));
        if (rc == CT_OK) rc = ct_vault_fetch(bytes(key_ref), {back, sizeof back}, &n);
        bool equal = n == static_cast<int64_t>(value.size()) && n > 0 && std::memcmp(back, value.data(), value.size()) == 0;
        volatile uint8_t *p = back; for (size_t i = 0; i < sizeof back; ++i) p[i] = 0;
        if (rc != CT_OK || !equal) { wipe(value); return CT_FAILED; }
    }
    rc = setenv("MODEL_API_KEY", value.c_str(), 1);
    wipe(value);
    return rc == 0 ? (save ? 1 : 2) : CT_FAILED;
}
int32_t ct_tui_input(ct_bytes label, ct_bytes initial, ct_output out, int64_t *n) {
    if (!active || !label.data || label.len < 1 || label.len > 128 || initial.len < 0 || initial.len > 128) return CT_INVALID_ARGUMENT;
    std::string value;
    int rc = edit(std::string(reinterpret_cast<const char *>(label.data), static_cast<size_t>(label.len)),
                  std::string(initial.data ? reinterpret_cast<const char *>(initial.data) : "", static_cast<size_t>(initial.len)), false, value,
                  static_cast<size_t>(std::clamp<int64_t>(out.capacity, 1, 1024)));
    return rc == CT_OK ? put(out, n, value) : rc;
}
// Hidden single-line input that returns the value to the caller instead of
// binding it to an environment variable: used when the owner supplies an
// existing device credential (takeover of an already-configured unit).
int32_t ct_tui_secret(ct_bytes label, ct_output out, int64_t *n) {
    if (!active || !label.data || label.len < 1 || label.len > 128) return CT_INVALID_ARGUMENT;
    std::string value;
    int rc = edit(std::string(reinterpret_cast<const char *>(label.data), static_cast<size_t>(label.len)),
                  "", true, value,
                  static_cast<size_t>(out.capacity > 256 ? 256 : out.capacity));
    if (rc != CT_OK) { wipe(value); return rc; }
    rc = put(out, n, value);
    wipe(value);
    return rc;
}
int64_t ct_tui_service_start(ct_bytes directory) {
    if (!active || !directory.data || directory.len <= 0 || directory.len > 1024 ||
        directory.data[0] != '/' || std::memchr(directory.data, 0, static_cast<size_t>(directory.len))) return CT_INVALID_ARGUMENT;
    char path[4096] = {};
    if (!realpath(executable().c_str(), path)) return CT_FAILED;
    const std::string status_path = std::string(reinterpret_cast<const char *>(directory.data),
        static_cast<size_t>(directory.len)) + "/service/status.json";
    int fds[2];
    if (pipe(fds) != 0) return CT_FAILED;
    fcntl(fds[0], F_SETFD, FD_CLOEXEC); fcntl(fds[1], F_SETFD, FD_CLOEXEC);
    const pid_t child = fork();
    if (child == 0) {
        close(fds[0]);
        if (setsid() < 0) _exit(126);
        const pid_t monitor = fork();
        if (monitor != 0) {
            const auto ignored = write(fds[1], &monitor, sizeof monitor); (void)ignored;
            _exit(monitor > 0 ? 0 : 126);
        }
        close(fds[1]);
        // This is a separate session, not a cancellable TUI job. No inherited
        // terminal or parent pipe may keep either process alive after UI exit.
        if (!std::freopen("/dev/null", "r", stdin) || !std::freopen("/dev/null", "w", stdout) ||
                !std::freopen("/dev/null", "w", stderr)) _exit(126);
        unsetenv("META_CONTROLLER_MODEL"); unsetenv("META_TASK_MODEL");
        unsetenv("ROUTER_HOST"); unsetenv("ROUTER_PORT"); unsetenv("ROUTER_PASSWORD");
        execl(path, path, "--serve", static_cast<char *>(nullptr));
        _exit(127);
    }
    close(fds[1]);
    if (child < 0) { close(fds[0]); return CT_FAILED; }
    pid_t monitor = -1;
    const ssize_t got = read(fds[0], &monitor, sizeof monitor);
    close(fds[0]);
    int status = 0;
    while (waitpid(child, &status, 0) < 0) if (errno != EINTR) return CT_FAILED;
    if (got != sizeof monitor || monitor <= 0) return CT_FAILED;
    const std::string identity = "\"pid\":" + std::to_string(monitor) + ',';
    for (int attempt = 0; attempt < 40; ++attempt) {
        int fd = open(status_path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        struct stat st{};
        char data[16384];
        if (fd >= 0) {
            const bool private_state = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) &&
                st.st_uid == geteuid() && !(st.st_mode & 0077) && st.st_size > 0 &&
                st.st_size < static_cast<off_t>(sizeof data);
            const ssize_t n = private_state ? read(fd, data, sizeof data) : -1;
            close(fd);
            if (n > 0) {
                const std::string record(data, static_cast<size_t>(n));
                if (record.find(identity) != std::string::npos &&
                    record.find("\"phase\":\"monitoring\"") != std::string::npos && kill(monitor, 0) == 0)
                    return monitor;
            }
        }
        poll(nullptr, 0, 50);
    }
    // A delayed start is unknown, not permission to kill a PID or retry blindly.
    return 0;
}
int32_t ct_tui_job_start(ct_bytes mode) {
    if (!active || job_pid > 0 || !mode.data || mode.len < 1 || mode.len > 1029 ||
        std::memchr(mode.data, 0, static_cast<size_t>(mode.len))) return CT_REJECTED;
    std::string task(reinterpret_cast<const char *>(mode.data), static_cast<size_t>(mode.len));
    const bool device = task == "device-inspect" || task == "device-authorize" ||
                        task == "device-enroll" || task == "device-setup" ||
                        task == "device-restore" || task == "device-reboot";
    const bool talk = task.size() > 5 && task.compare(0, 5, "talk:") == 0;
    const char *arg = talk ? "--talk" : device ? "--device-step" : task == "discover" ? "--discover" : task == "agent" ? "--discover-model" :
                      task == "test-key" ? "--test-meta" : task == "lab" ? "--loop" : nullptr;
    if (!arg) return CT_REJECTED;
    auto path = executable();
    int fds[2];
    if (path.empty() || pipe(fds) != 0) return CT_FAILED;
    job_output.clear();
    job_pid = fork();
    if (job_pid == 0) {
        setpgid(0, 0);
        dup2(fds[1], STDOUT_FILENO); dup2(fds[1], STDERR_FILENO);
        close(fds[0]); close(fds[1]);
        if (!std::freopen("/dev/null", "r", stdin)) _exit(126);
        if (task == "lab") { unsetenv("ROUTER_HOST"); unsetenv("ROUTER_PORT"); unsetenv("ROUTER_PASSWORD"); }
        // The TUI displays persisted settings, not shell-only CLI overrides.
        // Its workers must use the same models the operator just configured.
        unsetenv("META_CONTROLLER_MODEL");
        unsetenv("META_TASK_MODEL");
        if (device) {
            const char *step = task.c_str() + 7;
            if (task == "device-setup" || task == "device-restore" || task == "device-reboot" ||
                task == "device-enroll")
                execl(path.c_str(), path.c_str(), arg, step, "--execute", static_cast<char *>(nullptr));
            else execl(path.c_str(), path.c_str(), arg, step, static_cast<char *>(nullptr));
        } else if (talk) execl(path.c_str(), path.c_str(), arg, task.c_str() + 5, static_cast<char *>(nullptr));
        else execl(path.c_str(), path.c_str(), arg, static_cast<char *>(nullptr));
        _exit(127);
    }
    close(fds[1]);
    if (job_pid < 0) { close(fds[0]); return CT_FAILED; }
    setpgid(job_pid, job_pid);
    job_fd = fds[0];
    fcntl(job_fd, F_SETFL, fcntl(job_fd, F_GETFL) | O_NONBLOCK);
    return CT_OK;
}
int32_t ct_tui_job_poll(ct_output out, int64_t *n) {
    if (job_pid <= 0 || !n) return CT_REJECTED;
    char buffer[4096];
    for (;;) {
        ssize_t count = read(job_fd, buffer, sizeof buffer);
        if (count <= 0) break;
        if (job_output.size() + static_cast<size_t>(count) > 32768) { stop_job(); return CT_BUFFER_TOO_SMALL; }
        job_output.append(buffer, static_cast<size_t>(count));
    }
    int status = 0;
    pid_t done = waitpid(job_pid, &status, WNOHANG);
    if (done == 0) return CT_PENDING;
    if (done < 0) { stop_job(); return CT_FAILED; }
    job_pid = -1;
    close(job_fd); job_fd = -1;
    int rc = put(out, n, job_output);
    if (rc != CT_OK) return rc;
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? CT_OK : CT_FAILED;
}
int32_t ct_tui_job_cancel() { stop_job(); return CT_OK; }
} // extern C
