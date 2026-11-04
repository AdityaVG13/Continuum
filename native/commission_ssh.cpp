// Fixed-program ASUS management transport. A failed/closed local connection
// cannot cancel a router-local rollback worker started by the program.
#include "commission_ssh.h"
#include <arpa/inet.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <util.h>
#else
#include <pty.h>
#endif
#include <cerrno>
#include <chrono>
#include <cstdlib>
#include <string>
#include <vector>

namespace {
using Clock = std::chrono::steady_clock;

bool private_regular(const std::string &path) {
    int fd = open(path.c_str(), O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return false;
    struct stat st{};
    bool ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) &&
        st.st_uid == getuid() && (st.st_mode & 077) == 0 && st.st_nlink == 1;
    close(fd);
    return ok;
}

bool safe_user(const std::string &s) {
    if (s.empty() || s.size() > 32) return false;
    for (unsigned char c : s)
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.'))
            return false;
    return true;
}

bool send_private(int fd, const std::string &data, Clock::time_point deadline) {
    size_t sent = 0;
    while (sent < data.size() && Clock::now() < deadline) {
        ssize_t n = write(fd, data.data() + sent, data.size() - sent);
        if (n > 0) { sent += (size_t)n; continue; }
        if (n < 0 && errno != EINTR && errno != EAGAIN) return false;
        pollfd p{fd, POLLOUT, 0};
        if (poll(&p, 1, 50) < 0 && errno != EINTR) return false;
    }
    return sent == data.size();
}

void reap_owned(pid_t child, int &status) {
    if (waitpid(child, &status, WNOHANG) == child) return;
    // Only this function's unreaped child can be signalled; no pid discovery.
    kill(child, SIGTERM);
    for (int i = 0; i < 10; ++i) {
        if (waitpid(child, &status, WNOHANG) == child) return;
        poll(nullptr, 0, 20);
    }
    kill(child, SIGKILL);
    while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
}
}  // namespace

bool ct_commission_ssh(const ct_commission_connection &c,
                       const std::string &program, std::string &output,
                       int timeout_seconds, std::string *diagnostic) {
    output.clear();
    auto reject = [&](const std::string &reason) {
        if (diagnostic) *diagnostic = reason;
        return false;
    };
    in_addr host{}, source{};
    if (inet_pton(AF_INET, c.host.c_str(), &host) != 1 ||
        inet_pton(AF_INET, c.source.c_str(), &source) != 1 || !safe_user(c.user) ||
        c.port < 1 || c.port > 65535 || c.password.empty() || c.password.size() > 256 ||
        c.password.find_first_of("\r\n") != std::string::npos ||
        program.empty() || program.size() > 24576 || timeout_seconds < 1 ||
        timeout_seconds > 120 || !private_regular(c.known_hosts))
        return reject("ssh_transport_configuration_invalid");

    // No credential or generated program is present in the process list.
    // No user ssh_config, multiplexed connection, agent, forwarding or proxy.
    std::vector<std::string> args = {
        "/usr/bin/ssh", "-F", "/dev/null", "-T", "-a", "-x", "-b", c.source,
        "-p", std::to_string(c.port), "-l", c.user,
        "-o", "ConnectTimeout=5", "-o", "ConnectionAttempts=1",
        "-o", "NumberOfPasswordPrompts=1", "-o", "PubkeyAuthentication=no",
        "-o", "PreferredAuthentications=password,keyboard-interactive",
        "-o", "StrictHostKeyChecking=accept-new",
        "-o", "UserKnownHostsFile=" + c.known_hosts,
        "-o", "GlobalKnownHostsFile=/dev/null", "-o", "LogLevel=ERROR",
        "-o", "ClearAllForwardings=yes", "-o", "PermitLocalCommand=no",
        c.host, "printf 'CT_SSH_READY\\n'; /bin/sh -s"};
    std::vector<char *> argv;
    // The pinned Goose sidecar uses the compiler's pre-C++17 default. execv
    // does not modify these owned argument strings, but its ABI takes char **.
    for (auto &arg : args) argv.push_back(const_cast<char *>(arg.c_str()));
    argv.push_back(nullptr);
    int master = -1;
    pid_t child = forkpty(&master, nullptr, nullptr, nullptr);
    if (child < 0) return reject("ssh_private_channel_unavailable");
    if (child == 0) {
        long maximum = sysconf(_SC_OPEN_MAX);
        if (maximum < 0) _exit(125);
        for (long fd = 3; fd < maximum; ++fd) close((int)fd);
        unsetenv("SSH_ASKPASS");
        unsetenv("SSH_AUTH_SOCK");
        unsetenv("DISPLAY");
        setenv("SSH_ASKPASS_REQUIRE", "never", 1);
        execv(argv[0], argv.data());
        _exit(127);
    }
    fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK);
    const auto deadline = Clock::now() + std::chrono::seconds(timeout_seconds);
    std::string incoming;
    bool password_sent = false, program_sent = false, failed = false;
    bool exited = false;
    int status = 0;
    while (Clock::now() < deadline && !failed) {
        pollfd p{master, POLLIN, 0};
        int ready = poll(&p, 1, 50);
        if (ready < 0 && errno != EINTR) { failed = true; break; }
        if (ready > 0 && (p.revents & (POLLIN | POLLHUP))) {
            char bytes[4096];
            ssize_t n = read(master, bytes, sizeof bytes);
            if (n > 0) {
                incoming.append(bytes, (size_t)n);
                if (incoming.size() > 65536) { failed = true; break; }
                if (!program_sent && incoming.find("CT_SSH_READY") != std::string::npos) {
                    // Disable local PTY echo before sending the program. Output
                    // before this authenticated marker is deliberately discarded.
                    termios tty{};
                    if (tcgetattr(master, &tty) != 0) { failed = true; break; }
                    tty.c_lflag &= ~(ECHO | ICANON);
                    tty.c_oflag &= ~ONLCR;
                    // sshd's non-login shell can omit the vendor's /sbin and
                    // /usr/sbin. Never depend on an interactive profile or the
                    // caller's environment to locate privileged executables.
                    const std::string wire_program =
                        "PATH=/usr/sbin:/usr/bin:/sbin:/bin\nexport PATH\n" + program + "\nexit\n";
                    if (tcsetattr(master, TCSANOW, &tty) != 0 ||
                        !send_private(master, wire_program, deadline)) {
                        failed = true; break;
                    }
                    incoming.clear();
                    program_sent = true;
                } else if (!program_sent && !password_sent &&
                           (incoming.find("password:") != std::string::npos ||
                            incoming.find("Password:") != std::string::npos)) {
                    termios tty{};
                    if (tcgetattr(master, &tty) != 0 || (tty.c_lflag & ECHO) ||
                        !send_private(master, c.password + "\n", deadline)) {
                        failed = true; break;
                    }
                    password_sent = true;
                    incoming.clear();
                }
            } else if (n == 0 || (n < 0 && errno == EIO)) {
                break;
            } else if (errno != EAGAIN && errno != EINTR) {
                failed = true; break;
            }
        }
        if (waitpid(child, &status, WNOHANG) == child) {
            exited = true;
            // Drain bytes already queued on the PTY after process exit.
            char bytes[4096];
            ssize_t n;
            while ((n = read(master, bytes, sizeof bytes)) > 0 && incoming.size() <= 65536)
                incoming.append(bytes, (size_t)n);
            break;
        }
    }
    close(master);
    if (!exited) reap_owned(child, status);
    if (failed) return reject("ssh_private_channel_failed");
    if (!program_sent) return reject(WIFEXITED(status) ?
        "ssh_before_program_exit_" + std::to_string(WEXITSTATUS(status)) : "ssh_before_program_interrupted");
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0)
        return reject(WIFEXITED(status) ? "ssh_program_exit_" + std::to_string(WEXITSTATUS(status)) : "ssh_program_interrupted");
    if (incoming.size() > 65536 || incoming.find(c.password) != std::string::npos)
        return reject("ssh_output_rejected");
    // Data framing is emitted only by our fixed program, never a login banner.
    size_t begin = incoming.find("CT_DATA_BEGIN\r\n");
    size_t skip = 15;
    if (begin == std::string::npos) {
        begin = incoming.find("CT_DATA_BEGIN\n");
        skip = 14;
    }
    if (begin == std::string::npos) return reject("ssh_data_frame_missing");
    size_t end = incoming.find("CT_DATA_END", begin + skip);
    if (end == std::string::npos) return reject("ssh_data_frame_incomplete");
    for (size_t i = begin + skip; i < end; ++i)
        if (incoming[i] != '\r') output += incoming[i];
    return true;
}
