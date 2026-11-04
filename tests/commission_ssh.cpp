// Real private-PTY transport with only the ssh executable boundary substituted.
// A non-login router shell may not inherit /sbin or /usr/sbin. The program must
// receive an explicit system PATH, and neither credentials nor its body may be
// passed in argv. No router, host configuration or real credential is touched.
#include "../native/commission_ssh.h"
#include <sys/stat.h>
#include <unistd.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

extern char **environ;

extern "C" int execv(const char *path, char *const arguments[]) {
    if (std::strcmp(path, "/usr/bin/ssh") != 0) _exit(91);
    for (int i = 0; arguments[i]; ++i)
        if (std::strstr(arguments[i], "TransportOnlyPassword") ||
            std::strstr(arguments[i], "path_ready=true")) _exit(92);
    // Keep the controlling terminal/password behavior real. Once authenticated,
    // model the stripped environment supplied by a non-login embedded sshd.
    char program[] = "stty -echo; printf 'Password:'; IFS= read -r password; "
        "[ \"$password\" = TransportOnlyPassword ] || exit 93; "
        "printf 'CT_SSH_READY\\n'; PATH=/nonexistent; export PATH; exec /bin/sh -s";
    char shell[] = "/bin/sh", flag[] = "-c";
    char *replacement[] = {shell, flag, program, nullptr};
    return execve(shell, replacement, environ);
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    const std::string directory = argv[1];
    if (mkdir(directory.c_str(), 0700) != 0) return 3;
    ct_commission_connection connection{"127.0.0.1", "127.0.0.1", "admin",
        "TransportOnlyPassword", directory + "/known_hosts", 22};
    std::string output, reason;
    bool ok = ct_commission_ssh(connection,
        "set -eu\ncommand -v uname >/dev/null || exit 71\n"
        "printf 'CT_DATA_BEGIN\\npath_ready=true\\nCT_DATA_END\\n'\n",
        output, 10, &reason);
    if (!ok || output != "path_ready=true\n") {
        std::fprintf(stderr, "COMMISSION_SSH_PATH_RED reason=%s\n", reason.c_str());
        return 1;
    }
    std::puts("COMMISSION_SSH_PATH_GREEN private password; bounded program; explicit system PATH");
    return 0;
}
