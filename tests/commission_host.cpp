// The real generated router program executes against a modeled device OS.
// Only /proc, the transaction /tmp prefix and nvram/service/id are substituted;
// lease expiry is a real detached shell process, not a canned success receipt.
#include "../native/commission_ssh.h"
#include <sys/wait.h>
#include <fcntl.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <string>

namespace {
std::string quote(const std::string &s) {
    std::string out = "'";
    for (char c : s) out += c == '\'' ? "'\\''" : std::string(1, c);
    return out + "'";
}
void remap(std::string &s, const std::string &from, const std::string &to) {
    size_t at = 0;
    while ((at = s.find(from, at)) != std::string::npos) {
        s.replace(at, from.size(), to);
        at += to.size();
    }
}
}

bool ct_commission_ssh(const ct_commission_connection &,
                       const std::string &program, std::string &output, int, std::string *) {
    output.clear();
    const char *environment = std::getenv("CT_COMMISSION_DEVICE_ROOT");
    if (!environment || !*environment) return false;
    const std::string root(environment);
    std::string script = program;
    remap(script, "/sbin/reboot", root + "/bin/reboot");
    remap(script, "/proc/", root + "/proc/");
    remap(script, "/tmp/continuum-commission-", root + "/tmp/continuum-commission-");
    // Embedded ash builds need not include the optional `command` builtin.
    // The real vendor tools still exist: capability proof must execute a
    // harmless read, not equate a missing shell introspection builtin with it.
    script = "PATH=" + quote(root + "/bin") + ":/usr/bin:/bin\nexport PATH\n"
        "command() { return 127; }\n" + script;
    static unsigned sequence = 0;
    std::string path = root + "/program-" + std::to_string(getpid()) + "-" + std::to_string(++sequence) + ".sh";
    int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (fd < 0) return false;
    bool written = write(fd, script.data(), script.size()) == (ssize_t)script.size();
    close(fd);
    if (!written) return false;
    FILE *pipe = popen(("/bin/sh " + quote(path)).c_str(), "r");
    if (!pipe) return false;
    std::string data;
    char buffer[4096];
    while (fgets(buffer, sizeof buffer, pipe)) {
        data += buffer;
        if (data.size() > 65536) break;
    }
    int status = pclose(pipe);
    if (!WIFEXITED(status) || WEXITSTATUS(status) != 0) return false;
    const std::string begin = "CT_DATA_BEGIN\n";
    size_t first = data.find(begin);
    if (first == std::string::npos) return false;
    first += begin.size();
    size_t last = data.find("CT_DATA_END", first);
    if (last == std::string::npos) return false;
    output = data.substr(first, last - first);
    return true;
}
