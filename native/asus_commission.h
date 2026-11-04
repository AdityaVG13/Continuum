// Private implementation included once by asus_web.cpp, after its scoped HTTP
// and vault primitives. The allowlist below is an independent native safety
// boundary; Goose chooses the profile, but cannot submit arbitrary shell/NVRAM.
#ifndef CONTINUUM_ASUS_COMMISSION_H
#define CONTINUUM_ASUS_COMMISSION_H

using CommissionSnapshot = std::map<std::string, std::string>;
// The device layer owns this table. A device that is not one of the built-in
// models declares its own primitives in a manifest (one feature per line:
// id class key settable stop start process1 process2). Core, policy and prompts
// never see these values; they only ever handle the id and the class.
struct CommissionFeature {
    std::string id, cls, key, stop, start, process1, process2;
    bool settable = true;
};
const std::vector<CommissionFeature> &commission_features() {
    static const std::vector<CommissionFeature> builtin = {
        {"samba", "file_sharing", "enable_samba", "stop_samba", "restart_samba", "smbd", "nmbd"},
        {"ftp", "file_sharing", "enable_ftp", "stop_ftpd", "restart_ftpd", "vsftpd", ""},
        {"dlna", "media_server", "dms_enable", "stop_dms", "restart_dms", "minidlna", ""},
        {"daap", "media_server", "daapd_enable", "stop_mt_daapd", "restart_mt_daapd", "mt-daapd", ""},
        {"webdav", "file_sharing", "enable_webdav", "stop_webdav", "restart_webdav", "lighttpd", "webdav_client"},
    };
    static const std::vector<CommissionFeature> active = [&] {
        const char *path = std::getenv("CONTINUUM_CAPABILITY_MANIFEST");
        if (!path || !*path) return builtin;
        std::ifstream in(path);
        std::vector<CommissionFeature> loaded;
        std::string line;
        while (std::getline(in, line)) {
            if (line.empty() || line[0] == '#') continue;
            std::istringstream row(line);
            CommissionFeature f;
            std::string settable;
            if (!(row >> f.id >> f.cls >> f.key >> settable >> f.stop >> f.start >> f.process1)) return builtin;
            row >> f.process2;
            f.settable = settable == "1";
            loaded.push_back(f);
        }
        if (loaded.empty() || loaded.size() > 8) return builtin;
        return loaded;
    }();
    return active;
}
const std::vector<std::string> kCommissionKeys = {
    "productid", "firmver", "buildno", "extendno", "lan_hwaddr",
    "x_Setting", "sw_mode", "http_username", "lan_ipaddr", "lan_netmask",
    "dhcp_enable_x", "fw_enable_x", "wan_proto", "wan0_ipaddr",
    "wan0_state_t", "wan0_sbstate_t", "wan0_auxstate_t",
    "ctf_disable", "fc_disable", "qos_enable", "qos_type",
    "enable_samba", "enable_ftp", "dms_enable", "daapd_enable", "enable_webdav",
    "sshd_enable", "sshd_port", "sshd_pass",
    "wl0_ssid", "wl0_auth_mode_x", "wl1_ssid", "wl1_auth_mode_x",
    "wl2_ssid", "wl2_auth_mode_x"};
const std::vector<std::string> kCommissionCore = {
    "productid", "firmver", "buildno", "extendno", "lan_hwaddr", "x_Setting",
    "sw_mode", "http_username", "lan_ipaddr", "lan_netmask", "dhcp_enable_x",
    "fw_enable_x", "wan_proto", "ctf_disable", "fc_disable", "qos_enable",
    "qos_type", "wl0_ssid", "wl0_auth_mode_x", "wl1_ssid", "wl1_auth_mode_x",
    "wl2_ssid", "wl2_auth_mode_x"};

std::string commission_identity(const CommissionSnapshot &values) {
    auto field = [&](const char *key) {
        auto it = values.find(key);
        return it == values.end() ? std::string() : it->second;
    };
    std::string out = "{\"productid\":\"";
    json_escape(field("productid"), out);
    out += "\",\"mac\":\"";
    json_escape(field("lan_hwaddr"), out);
    return out + "\"}";
}

// The device adapter owns the only mapping from its own primitives to the
// product's capability classes. Core, policy and prompts never see these keys.
std::string commission_capabilities(const CommissionSnapshot &values) {
    std::string out = "[";
    bool first = true;
    auto emit = [&](const std::string &id, const std::string &cls, const std::string &key,
                    bool settable, bool boolean) {
        auto it = values.find(key);
        std::string state = "unknown";
        if (it != values.end() && !it->second.empty()) {
            if (!boolean) state = "present";
            else if (it->second == "0") state = "disabled";
            else state = "enabled";
        }
        if (!first) out += ",";
        first = false;
        out += "{\"id\":\"" + id + "\",\"class\":\"" + cls + "\",\"state\":\"" + state + "\",\"settable\":";
        out += settable ? "true" : "false";
        out += ",\"evidence\":\"device_reported\"}";
    };
    for (const auto &f : commission_features()) emit(f.id, f.cls, f.key, f.settable, true);
    emit("vendor_qos", "traffic_control", "qos_enable", false, true);
    emit("ssh", "remote_access", "sshd_enable", false, true);
    emit("vendor_firmware", "update_channel", "firmver", false, false);
    return out + "]";
}

std::string commission_object(const CommissionSnapshot &values) {
    std::string out = "{";
    for (const auto &[key, value] : values) {
        if (out.size() > 1) out += ",";
        out += "\"" + key + "\":\"";
        json_escape(value, out);
        out += "\"";
    }
    return out + "}";
}

bool commission_snapshot(Session &s, CommissionSnapshot &values) {
    // The device's own table decides which settings exist, so a declared
    // device is observed through the same transaction as a built-in model.
    std::vector<std::string> keys = kCommissionKeys;
    for (const auto &feature : commission_features()) {
        bool known = false;
        for (const auto &key : keys) if (key == feature.key) known = true;
        if (!known) keys.push_back(feature.key);
    }
    std::string path = "/appGet.cgi?hook=";
    for (const auto &key : keys) {
        if (path.back() != '=') path += "%3B";
        path += "nvram_get(" + key + ")";
    }
    int status = 0;
    std::string response;
    if (http_round(s, request_head(s, "GET", path, index_referer(s.ref), nullptr),
                   status, response) != RoundRc::Ok || status != 200 ||
        response.find("Main_Login") != std::string::npos ||
        response.find("AUTHFAIL") != std::string::npos) return false;
    values.clear();
    for (const auto &key : keys) {
        std::string value;
        if (!json_str(response, key.c_str(), value)) return false;
        values[key] = value;
    }
    return !values["productid"].empty();
}

bool commission_same_core(const CommissionSnapshot &a, const CommissionSnapshot &b) {
    for (const auto &key : kCommissionCore)
        if (a.at(key) != b.at(key)) return false;
    return true;
}

bool commission_small_setting(const std::string &value, bool port = false) {
    if (value.empty() || value.size() > 5) return false;
    for (char c : value) if (c < '0' || c > '9') return false;
    long n = std::strtol(value.c_str(), nullptr, 10);
    return port ? n >= 1 && n <= 65535 : value == "0" || value == "1" || value == "2";
}

// Existing directories must already be private and owned. Do not follow a
// symlink, reuse another owner's backup, or truncate an existing baseline.
bool commission_directory(const std::string &path) {
    if (path.empty() || path.size() > 512 || path.find("..") != std::string::npos)
        return false;
    for (unsigned char c : path)
        if (!(std::isalnum(c) || c == '/' || c == '_' || c == '-' || c == '.')) return false;
    if (mkdir(path.c_str(), 0700) != 0 && errno != EEXIST) return false;
    struct stat st{};
    return lstat(path.c_str(), &st) == 0 && S_ISDIR(st.st_mode) &&
        st.st_uid == getuid() && (st.st_mode & 077) == 0;
}

// Baselines are write-once. Observations and the latest event are replaceable,
// never an unbounded history; the directory lock serializes pending records.
bool commission_save(const std::string &path, const std::string &data, bool replace = false) {
    if (replace && data.size() > 65536) return false;
    const std::string target = replace ? path + ".pending" : path;
    int fd = open(target.c_str(), O_WRONLY | O_CREAT | O_NOFOLLOW | O_CLOEXEC |
                  (replace ? 0 : O_EXCL), 0600);
    if (fd < 0) return false;
    struct stat st{};
    bool ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == getuid() &&
        (st.st_mode & 077) == 0 && st.st_nlink == 1;
    if (ok && replace) ok = ftruncate(fd, 0) == 0;
    size_t at = 0;
    while (ok && at < data.size()) {
        ssize_t n = write(fd, data.data() + at, data.size() - at);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { ok = false; break; }
        at += (size_t)n;
    }
    if (ok) ok = fsync(fd) == 0;
    if (close(fd) != 0) ok = false;
    if (ok && replace) ok = rename(target.c_str(), path.c_str()) == 0;
    if (ok) {
        const std::string parent = path.substr(0, path.find_last_of('/'));
        const int directory = open(parent.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        ok = directory >= 0 && fsync(directory) == 0;
        if (directory >= 0) close(directory);
    }
    return ok;
}

bool commission_load(const std::string &path, std::string &data) {
    int fd = open(path.c_str(), O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return false;
    struct stat st{};
    bool ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_uid == getuid() &&
        (st.st_mode & 077) == 0 && st.st_nlink == 1 && st.st_size > 0 && st.st_size <= 16384;
    data.clear();
    char bytes[4096];
    while (ok) {
        ssize_t n = read(fd, bytes, sizeof bytes);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { ok = false; break; }
        if (!n) break;
        data.append(bytes, (size_t)n);
        if (data.size() > 16384) ok = false;
    }
    close(fd);
    return ok;
}

bool commission_form(Session &s, const std::vector<std::pair<std::string, std::string>> &values) {
    auto fields = values;
    fields.push_back({"action_mode", "apply"});
    std::string form = form_join(fields), response;
    int status = 0;
    RoundRc rc = http_round(s, request_head(s, "POST", "/applyapp.cgi",
                             index_referer(s.ref), &form), status, response);
    // A restart can cut the reply; only the subsequent protected read is proof.
    if (rc != RoundRc::Ok && rc != RoundRc::Cut) return false;
    if (rc == RoundRc::Ok && (status != 200 ||
        response.find("Main_Login") != std::string::npos ||
        response.find("AUTHFAIL") != std::string::npos)) return false;
    return true;
}

// The nvram readback after restart_sshd proves the setting, not that the
// daemon is listening: on a GT-AX11000 the first ssh right after it was
// refused (exit 255). After a connection-phase failure, wait for the port to
// accept a TCP connection from the same source address, bounded by seconds.
bool commission_wait_port(const std::string &host, const std::string &source, int port, int seconds) {
    sockaddr_in remote{};
    remote.sin_family = AF_INET;
    remote.sin_port = htons((uint16_t)port);
    if (port < 1 || port > 65535 || inet_pton(AF_INET, host.c_str(), &remote.sin_addr) != 1) return false;
    const auto until = std::chrono::steady_clock::now() + std::chrono::seconds(seconds);
    while (std::chrono::steady_clock::now() < until) {
        int fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return false;
        bool ok = true;
        if (!source.empty()) {
            sockaddr_in local{};
            local.sin_family = AF_INET;
            ok = inet_pton(AF_INET, source.c_str(), &local.sin_addr) == 1 &&
                 bind(fd, (sockaddr *)&local, sizeof local) == 0;
        }
        if (ok) {
            fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
            int rc = connect(fd, (sockaddr *)&remote, sizeof remote);
            if (rc == 0) { close(fd); return true; }
            if (errno == EINPROGRESS) {
                pollfd p{fd, POLLOUT, 0};
                int error = 0;
                socklen_t length = sizeof error;
                if (poll(&p, 1, 500) == 1 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0) {
                    close(fd); return true;
                }
            }
        }
        close(fd);
        poll(nullptr, 0, 500);
    }
    return false;
}

bool commission_ssh_settings(Session &s, const CommissionSnapshot &desired,
                             const std::string &user, const std::string &password) {
    if (!commission_form(s, {{"sshd_enable", desired.at("sshd_enable")},
        {"sshd_port", desired.at("sshd_port")}, {"sshd_pass", desired.at("sshd_pass")},
        {"rc_service", "restart_sshd"}})) return false;
    for (int i = 0; i < 5; ++i) {
        if (i) poll(nullptr, 0, 1000);
        CommissionSnapshot now;
        if (asus_login(s, user, password) == LoginRc::Ok && commission_snapshot(s, now) &&
            now["sshd_enable"] == desired.at("sshd_enable") &&
            now["sshd_port"] == desired.at("sshd_port") &&
            now["sshd_pass"] == desired.at("sshd_pass")) return true;
    }
    return false;
}

// This helper only closes the pre-router-watchdog SSH bootstrap window. It is
// not presented as recovery for an unreachable target. The real cleanup lease
// below runs on the router and never depends on this host or a model response.
struct CommissionBootstrapGuard {
    int signal_fd = -1;
    pid_t child = -1;
    bool start(Session s, const CommissionSnapshot &before,
               const std::string &user, const std::string &password) {
        int fds[2];
        if (socketpair(AF_UNIX, SOCK_STREAM, 0, fds) != 0) return false;
#if defined(__APPLE__)
        int suppress_sigpipe = 1;
        if (setsockopt(fds[1], SOL_SOCKET, SO_NOSIGPIPE, &suppress_sigpipe, sizeof suppress_sigpipe) != 0) {
            close(fds[0]); close(fds[1]); return false;
        }
#endif
        child = fork();
        if (child < 0) { close(fds[0]); close(fds[1]); return false; }
        if (child == 0) {
            close(fds[1]); close(0); close(1); close(2);
            pollfd p{fds[0], POLLIN | POLLHUP, 0};
            int rc;
            do { rc = poll(&p, 1, 120000); } while (rc < 0 && errno == EINTR);
            char verdict = 0;
            ssize_t n = rc > 0 ? read(fds[0], &verdict, 1) : 0;
            close(fds[0]);
            if (n != 1 || verdict != 'C')
                (void)commission_ssh_settings(s, before, user, password);
            _exit(0);
        }
        close(fds[0]); signal_fd = fds[1];
        fcntl(signal_fd, F_SETFD, FD_CLOEXEC);
        return true;
    }
    void done(bool restored) {
        if (signal_fd < 0) return;
        if (restored) {
            char c = 'C';
#if defined(__APPLE__)
            (void)send(signal_fd, &c, 1, 0);
#else
            (void)send(signal_fd, &c, 1, MSG_NOSIGNAL);
#endif
        }
        close(signal_fd); signal_fd = -1;
        int status;
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
        child = -1;
    }
    ~CommissionBootstrapGuard() { done(false); }
};

std::string commission_runtime_program() {
    // comm/status, not cmdline: process arguments can contain owner secrets.
    // VmRSS sums are explicitly RSS observations, not reclaimed physical RAM.
    return R"CT(set -eu
# Prove the tool with a harmless read. Some embedded ash builds omit the
# optional `command` introspection builtin even though nvram itself exists.
nvram get productid >/dev/null || exit 71
ct_uid=unknown
while read ct_key ct_real ct_effective ct_saved ct_filesystem; do
 if [ "$ct_key" = Uid: ]; then
  ct_uid=$ct_effective
  [ "$ct_real" = 0 ] && [ "$ct_saved" = 0 ] && [ "$ct_filesystem" = 0 ] || exit 75
  break
 fi
done < /proc/self/status
[ "$ct_uid" = 0 ] || exit 75
printf 'CT_DATA_BEGIN\n'
printf 'uid=0\n'
read ct_boot < /proc/sys/kernel/random/boot_id || exit 76
printf 'boot_id=%s\n' "$ct_boot"
while read ct_key ct_value ct_unit; do
 case "$ct_key" in MemTotal:|MemAvailable:|MemFree:) printf '%s=%s\n' "$ct_key" "$ct_value";; esac
done < /proc/meminfo || exit 77
read ct_cpu ct_user ct_nice ct_system ct_idle ct_iowait ct_irq ct_softirq ct_rest < /proc/stat || exit 78
printf 'cpu_busy_ticks=%s\ncpu_idle_ticks=%s\n' "$((ct_user+ct_nice+ct_system+ct_irq+ct_softirq))" "$((ct_idle+ct_iowait))"
ct_count=0
for ct_dir in /proc/[0-9]*; do
 [ -r "$ct_dir/comm" ] || continue
 IFS= read -r ct_name < "$ct_dir/comm" || continue
 # A process may retire between directory enumeration and opening status.
 if ! { exec 3< "$ct_dir/status"; } 2>/dev/null; then continue; fi
 ct_rss=0
 while read ct_key ct_value ct_unit <&3; do
  if [ "$ct_key" = VmRSS: ]; then ct_rss=$ct_value; break; fi
 done
 exec 3<&-
 ct_count=$((ct_count+1))
 [ "$ct_count" -le 512 ] || exit 80
 printf 'process=%s,%s,%s\n' "${ct_dir##*/}" "$ct_name" "$ct_rss"
done
printf 'CT_DATA_END\n'
)CT";
}

bool commission_runtime_valid(const std::string &data) {
    return data.find("uid=0\n") != std::string::npos &&
        data.find("boot_id=") != std::string::npos &&
        data.find("MemTotal:") != std::string::npos &&
        data.find(",dnsmasq,") != std::string::npos &&
        data.find(",httpd,") != std::string::npos;
}

std::string commission_boot_id(const std::string &data) {
    const std::string key = "\nboot_id=";
    size_t begin = data.find(key);
    if (begin == std::string::npos) return "";
    begin += key.size();
    size_t end = data.find('\n', begin);
    if (end == std::string::npos || end == begin || end - begin > 64) return "";
    std::string value = data.substr(begin, end - begin);
    for (unsigned char c : value)
        if (!std::isalnum(c) && c != '-') return "";
    return value;
}

bool commission_process_present(const std::string &data, const std::string &name) {
    return !name.empty() && data.find("," + name + ",") != std::string::npos;
}

// --- qdisc profile boundary -------------------------------------------------
// Every command below is generated from a validated enum or integer. The model
// chooses a profile, never a shell string. The same bounds are rechecked in
// Goose (src/device_agent.goose) because this adapter is not the only caller.

std::string qdisc_root_kind(const std::string &show) {
    size_t line = 0;
    while (line < show.size()) {
        size_t end = show.find('\n', line);
        if (end == std::string::npos) end = show.size();
        const std::string text = show.substr(line, end - line);
        if (text.find(" root") != std::string::npos) {
            size_t p = text.find("qdisc ");
            if (p == std::string::npos) return "";
            p += 6;
            size_t e = p;
            while (e < text.size() && text[e] != ' ' && text[e] != '\r') e++;
            return text.substr(p, e - p);
        }
        line = end + 1;
    }
    return "";
}

// Kernel-default roots are the only state Continuum will replace, and they are
// exactly what `tc qdisc del dev X root` restores. A root managed by the vendor
// QoS or another agent is refused rather than stomped.
bool qdisc_default_kind(const std::string &show) {
    const std::string kind = qdisc_root_kind(show);
    return kind == "pfifo_fast" || kind == "noqueue" || kind == "mq" || kind == "pfifo";
}

// `tc` prints rates with %g in the largest unit (90000kbit -> "90Mbit" or
// "90000Kbit"), so compare normalized kilobits rather than display text.
bool qdisc_cake_rate_kbit(const std::string &show, double &kbit) {
    size_t p = show.find("bandwidth ");
    if (p == std::string::npos) return false;
    p += 10;
    size_t e = p;
    while (e < show.size() && (std::isdigit((unsigned char)show[e]) || show[e] == '.')) e++;
    if (e == p) return false;
    double value = std::strtod(show.substr(p, e - p).c_str(), nullptr);
    std::string unit = show.substr(e, 4);
    for (auto &c : unit) c = (char)std::tolower((unsigned char)c);
    if (unit.rfind("gbit", 0) == 0) value *= 1000000.0;
    else if (unit.rfind("mbit", 0) == 0) value *= 1000.0;
    else if (unit.rfind("kbit", 0) == 0) { /* already kbit */ }
    else if (unit.rfind("bit", 0) == 0) value /= 1000.0;
    else return false;
    kbit = value;
    return true;
}

// Absence is data, not a shell exit code the caller has to decode: the probe
// prints qdisc_tool=absent so an unsupported unit refuses honestly.
std::string commission_qdisc_probe(const std::string &iface) {
    return "set -eu\n"
        "if ! tc -V >/dev/null 2>&1; then\n"
        " printf 'CT_DATA_BEGIN\\nqdisc_tool=absent\\nCT_DATA_END\\n'\n"
        " exit 0\n"
        "fi\n"
        "printf 'CT_DATA_BEGIN\\n'\n"
        "tc qdisc show dev " + iface + "\n"
        "printf 'CT_DATA_END\\n'\n";
}

std::string commission_qdisc_apply(const std::string &iface, const std::string &mode,
                                   long kbps, long overhead) {
    const std::string shape = mode == "cake"
        ? "cake bandwidth " + std::to_string(kbps) + "kbit overhead " + std::to_string(overhead)
        : "fq_codel limit 10240";
    return "set -eu\n"
        "tc qdisc replace dev " + iface + " root " + shape + "\n"
        "printf 'CT_DATA_BEGIN\\n'\n"
        "tc qdisc show dev " + iface + "\n"
        "printf 'CT_DATA_END\\n'\n";
}

std::string commission_qdisc_restore(const std::string &iface) {
    return "set -eu\n"
        "tc qdisc del dev " + iface + " root 2>/dev/null || true\n"
        "printf 'CT_DATA_BEGIN\\n'\n"
        "tc qdisc show dev " + iface + "\n"
        "printf 'CT_DATA_END\\n'\n";
}

std::string qdisc_excerpt(const std::string &text) {
    std::string out;
    json_escape(text.size() > 512 ? text.substr(0, 512) : text, out);
    return out;
}

// A root qdisc may be replaced only when it is the kernel default or the exact
// profile Continuum last verified here. Retuning our own qdisc is allowed;
// stomping a vendor QoS hierarchy is not. The durable marker is a claim this
// host wrote after a verified readback, never model input.
bool qdisc_owned(const std::string &directory, const std::string &iface,
                 const std::string &kind) {
    std::string saved;
    if (!commission_load(directory + "/qos-owned.txt", saved)) return false;
    return saved == iface + "\n" + kind + "\n";
}

// Restore can name the interface it installed without a model-supplied value:
// the durable marker records the last interface Continuum verified here.
std::string qos_owned_interface(const std::string &directory) {
    std::string saved;
    if (!commission_load(directory + "/qos-owned.txt", saved)) return "";
    const size_t nl = saved.find('\n');
    const std::string iface = nl == std::string::npos ? "" : saved.substr(0, nl);
    return (iface == "eth0" || iface == "ppp0") ? iface : "";
}


std::string commission_quote(const std::string &text) {
    std::string out = "'";
    for (char c : text) out += c == '\'' ? "'\\''" : std::string(1, c);
    return out + "'";
}

// A lease is armed before any feature mutation. The worker is detached on the
// device; closing SSH or killing the commissioning process cannot cancel it.
// It exits within a second after confirmation. No file/firmware deletion.
std::string commission_trial_program(const std::string &lease,
    const CommissionSnapshot &before, const std::vector<size_t> &selected, int seconds) {
    std::string restore = "#!/bin/sh\ntrap '' HUP\nset +e\nct_n=0\nwhile [ \"$ct_n\" -lt " +
        std::to_string(seconds) + " ]; do\n IFS= read -r ct_state < " + lease +
        "/lease\n [ \"$ct_state\" = confirmed ] && exit 0\n [ \"$ct_state\" = rollback ] && break\n sleep 1\n ct_n=$((ct_n+1))\ndone\n";
    for (size_t i : selected) {
        const auto &f = commission_features()[i];
        // Refuse to overwrite an intervening owner's nonzero choice.
        restore += "ct_v=$(nvram get " + std::string(f.key) + ")\n";
        restore += "if [ \"$ct_v\" = 0 ]; then nvram set " + std::string(f.key) + "=" +
            before.at(f.key) + "; service " + f.start + "; fi\n";
    }
    restore += "nvram set sshd_port=" + before.at("sshd_port") +
        "\nnvram set sshd_pass=" + before.at("sshd_pass") +
        "\nnvram set sshd_enable=" + before.at("sshd_enable") +
        "\nnvram commit\nprintf 'restored\\n' > " + lease +
        "/result\nservice restart_sshd\n";
    std::string program = "set -eu\numask 077\nmkdir " + lease +
        "\nprintf 'pending\\n' > " + lease + "/lease\nprintf '%s' " +
        commission_quote(restore) + " > " + lease + "/watchdog.sh\n(trap '' HUP; exec /bin/sh " +
        lease + "/watchdog.sh) </dev/null >" + lease + "/watchdog.log 2>&1 &\n";
    // Roll back on this command's own failure as well as controller loss. The
    // worker remains pending until a separate verified commit request.
    for (size_t i : selected) {
        const auto &f = commission_features()[i];
        program += "[ \"$(nvram get " + std::string(f.key) + ")\" = " +
            before.at(f.key) + " ]\nnvram set " + f.key + "=0\nservice " + f.stop + "\n";
    }
    program += "printf 'CT_DATA_BEGIN\\narmed=true\\nCT_DATA_END\\n'\n";
    return program;
}

int32_t commission_emit(ct_output out, int64_t *out_len, const std::string &text,
                        int32_t status = CT_OK) {
    int32_t copied = CT_OK;
    put_receipt(out, out_len, text, copied);
    return copied == CT_OK ? status : copied;
}

int32_t commission_fail(ct_output out, int64_t *out_len, const char *reason,
                        bool changed = false) {
    return commission_emit(out, out_len,
        std::string("{\"phase\":\"failed\",\"commissioned\":false,\"changed\":") +
        (changed ? "true" : "false") + ",\"reason\":\"" + reason + "\"}", CT_REJECTED);
}

std::string commission_nonce() {
    unsigned char bytes[12];
    arc4random_buf(bytes, sizeof bytes);
    std::string out;
    char hex[3];
    for (unsigned char c : bytes) {
        std::snprintf(hex, sizeof hex, "%02x", c);
        out += hex;
    }
    return out;
}

bool commission_profile_matches(const CommissionSnapshot &now, const CommissionSnapshot &before,
                                const std::vector<size_t> &selected, bool restored) {
    if (!commission_same_core(now, before)) return false;
    for (size_t i : selected) {
        const auto &key = commission_features()[i].key;
        if (now.at(key) != (restored ? before.at(key) : "0")) return false;
    }
    return true;
}

struct CommissionLock {
    int fd = -1;
    ~CommissionLock() { if (fd >= 0) close(fd); }
    bool acquire(const std::string &directory) {
        fd = open((directory + "/owner.lock").c_str(), O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
        struct stat st{};
        return fd >= 0 && fstat(fd, &st) == 0 && S_ISREG(st.st_mode) &&
            st.st_uid == getuid() && (st.st_mode & 077) == 0 && st.st_nlink == 1 &&
            flock(fd, LOCK_EX | LOCK_NB) == 0;
    }
};

int32_t commission_execute(Session &s, const std::string &body, const std::string &action,
    const std::string &user, const std::string &password, const std::string &ref,
    CommissionSnapshot current, ct_output out, int64_t *out_len) {
    bool execute = false;
    if (!json_bool(body, "execute", execute) || !execute)
        return commission_fail(out, out_len, "standing_execute_permission_required");
    if (current["x_Setting"] != "1" || current["sw_mode"] != "1" ||
        current["lan_hwaddr"].empty() || current["firmver"].empty() ||
        current["dhcp_enable_x"] != "1" || current["fw_enable_x"] != "1")
        return commission_fail(out, out_len, "router_identity_or_core_baseline_unqualified");
    if (!commission_small_setting(current["sshd_enable"]) || current["sshd_enable"] == "2" ||
        (!current["sshd_port"].empty() && !commission_small_setting(current["sshd_port"], true)) ||
        (current["sshd_pass"] != "0" && current["sshd_pass"] != "1"))
        return commission_fail(out, out_len, "lan_only_ssh_bootstrap_unqualified");
    std::string directory;
    if (!str_field(body, "directory", 512, false, directory))
        return commission_fail(out, out_len, "private_recovery_directory_required");
    if (directory.empty() && action == "apply") {
        const char *home = std::getenv("HOME");
        if (!home || home[0] != '/')
            return commission_fail(out, out_len, "private_recovery_directory_required");
        // Each enrollment keeps its own immutable recovery baseline. Report the
        // chosen directory; never overwrite an older router's saved state.
        directory = std::string(home) + "/.continuum-commission-" + commission_nonce();
    }
    if (!commission_directory(directory))
        return commission_fail(out, out_len, "private_recovery_directory_required");
    CommissionLock lock;
    if (!lock.acquire(directory)) return commission_fail(out, out_len, "recovery_directory_already_owned");
    CommissionSnapshot before = current;
    std::vector<size_t> selected, requested;
    if (action != "apply") {
        std::string saved;
        if (!commission_load(directory + "/baseline.json", saved))
            return commission_fail(out, out_len, "private_baseline_unavailable");
        std::string target, saved_ref;
        long port = 0;
        if (!json_str(saved, "target_host", target) || target != s.ref.host ||
            !json_int(saved, "target_port", port) || port != s.ref.port ||
            !json_str(saved, "admin_ref", saved_ref) || saved_ref != ref)
            return commission_fail(out, out_len, "baseline_target_binding_mismatch");
        std::vector<std::string> baseline_keys = kCommissionKeys;
        for (const auto &feature : commission_features()) {
            bool known = false;
            for (const auto &key : baseline_keys) if (key == feature.key) known = true;
            if (!known) baseline_keys.push_back(feature.key);
        }
        for (const auto &key : baseline_keys)
            if (!json_str(saved, key.c_str(), before[key]))
                return commission_fail(out, out_len, "baseline_schema_invalid");
        if (!commission_same_core(current, before))
            return commission_fail(out, out_len, "core_or_device_changed_since_backup");
        for (size_t i = 0; i < commission_features().size(); ++i) {
            bool owned = false;
            if (!json_bool(saved, ("owns_" + std::string(commission_features()[i].key)).c_str(), owned))
                return commission_fail(out, out_len, "baseline_ownership_missing");
            if (!owned) continue;
            const auto &key = commission_features()[i].key;
            if (!commission_small_setting(before[key]) ||
                (current[key] != "0" && current[key] != before[key]))
                return commission_fail(out, out_len, "service_changed_by_another_owner");
            selected.push_back(i);
        }
    } else {
        std::string disable;
        if (!json_str(body, "disable", disable) || disable.empty() || disable.size() > 128)
            return CT_INVALID_ARGUMENT;
        size_t cursor = 0;
        while (cursor <= disable.size()) {
            size_t comma = disable.find(',', cursor);
            std::string id = disable.substr(cursor, comma == std::string::npos ? std::string::npos : comma - cursor);
            if (id.empty() || id.size() > 32) return CT_INVALID_ARGUMENT;
            size_t index = commission_features().size();
            for (size_t i = 0; i < index; ++i)
                if (id == commission_features()[i].id) index = i;
            if (index == commission_features().size())
                return commission_fail(out, out_len, "capability_unknown");
            const auto &key = commission_features()[index].key;
            if (current[key].empty()) { cursor = comma == std::string::npos ? disable.size() + 1 : comma + 1; continue; }
            if (!commission_small_setting(current[key]))
                return commission_fail(out, out_len, "unsupported_optional_service_value");
            requested.push_back(index);
            if (current[key] != "0") selected.push_back(index);
            cursor = comma == std::string::npos ? disable.size() + 1 : comma + 1;
        }
        // The baseline is immutable, target-bound, non-secret and durable before
        // any write. The separate opaque vendor backup may contain credentials.
        std::string saved = commission_object(before);
        saved.pop_back();
        saved += ",\"target_host\":\"" + s.ref.host + "\",\"target_port\":" +
            std::to_string(s.ref.port) + ",\"admin_ref\":\"" + ref + "\"";
        for (size_t i = 0; i < commission_features().size(); ++i) {
            bool owns = false;
            for (size_t j : selected) if (i == j) owns = true;
            saved += ",\"owns_" + std::string(commission_features()[i].key) + "\":" + (owns ? "true" : "false");
        }
        saved += "}";
        if (!commission_save(directory + "/baseline.json", saved))
            return commission_fail(out, out_len, "immutable_baseline_not_stored");
        int status = 0;
        std::string backup;
        if (http_round(s, request_head(s, "GET", "/backup.CFG", index_referer(s.ref), nullptr),
                       status, backup, false) != RoundRc::Ok || status != 200 || backup.size() < 8 ||
            (backup.compare(0, 4, "HDR1") != 0 && backup.compare(0, 4, "HDR2") != 0 &&
             backup.compare(0, 4, "HDR3") != 0) ||
            !commission_save(directory + "/router-backup.CFG", backup))
            return commission_fail(out, out_len, "private_vendor_backup_not_verified");
    }
    if (!commission_small_setting(before["sshd_enable"]) || before["sshd_enable"] == "2" ||
        (!before["sshd_port"].empty() && !commission_small_setting(before["sshd_port"], true)) ||
        (before["sshd_pass"] != "0" && before["sshd_pass"] != "1"))
        return commission_fail(out, out_len, "baseline_ssh_values_invalid");
    std::string applied_boot;
    const bool qualification = action == "reboot" || action == "verify";
    if (qualification) {
        if (!commission_profile_matches(current, before, selected, false))
            return commission_fail(out, out_len, "applied_baseline_changed");
        for (const auto &feature : commission_features()) {
            bool owned = false;
            for (size_t i : selected) if (feature.key == commission_features()[i].key) owned = true;
            if (current[feature.key] != (owned ? "0" : before[feature.key]))
                return commission_fail(out, out_len, "applied_service_profile_changed");
        }
        for (const char *key : {"sshd_enable", "sshd_port", "sshd_pass"})
            if (current[key] != before[key])
                return commission_fail(out, out_len, "management_settings_changed_since_baseline");
        std::string applied_runtime;
        if (!commission_load(directory + "/runtime-after.txt", applied_runtime) ||
            !commission_runtime_valid(applied_runtime) ||
            (applied_boot = commission_boot_id(applied_runtime)).empty())
            return commission_fail(out, out_len, "applied_runtime_boot_unavailable");
    }
    CommissionBootstrapGuard bootstrap;
    if (!bootstrap.start(s, current, user, password))
        return commission_fail(out, out_len, "independent_bootstrap_guard_unavailable");
    CommissionSnapshot access = current;
    access["sshd_enable"] = "1";
    access["sshd_pass"] = "1";
    // Empty is the observed stock setting, not an invalid source token to
    // normalize. Explicitly stage port 22, then restore the original empty value.
    if (access["sshd_port"].empty()) access["sshd_port"] = "22";
    if (!commission_ssh_settings(s, access, user, password))
        return commission_fail(out, out_len, "lan_ssh_bootstrap_failed", true);
    ct_commission_connection connection{s.ref.host, s.ref.bind_addr, user, password,
        directory + "/known_hosts", (int)std::strtol(access["sshd_port"].c_str(), nullptr, 10)};
    std::string runtime_before, runtime_after, ignored;
    std::string lease;
    bool armed = false;
    auto fail = [&](const char *reason) -> int32_t {
        if (armed) {
            std::string rollback = "set -eu\nprintf 'rollback\\n' > " + lease +
                "/lease\nprintf 'CT_DATA_BEGIN\\nrollback_requested=true\\nCT_DATA_END\\n'\n";
            (void)ct_commission_ssh(connection, rollback, ignored, 10);
            // If this channel is lost, the device worker still owns expiry.
            for (int i = 0; i < 8; ++i) {
                CommissionSnapshot now;
                if (commission_snapshot(s, now) && commission_profile_matches(now, before, selected, true)) break;
                poll(nullptr, 0, 1000);
            }
        }
        bool restored_access = commission_ssh_settings(s, current, user, password);
        bootstrap.done(restored_access);
        (void)commission_save(directory + "/events.jsonl",
            "{\"phase\":\"failed\",\"reason\":\"" + std::string(reason) + "\"}\n", true);
        return commission_fail(out, out_len, reason, true);
    };
    std::string transport_diagnostic;
    // Only a failure before any password reached the router (refused, timed
    // out, unroutable, closed before the prompt) is retried: it had no effect,
    // and it is what a still-restarting daemon produces. Anything after the
    // password is not retried, so a wrong password never becomes repeated
    // login failures. Retries stop 30 s after the first attempt: the bootstrap
    // guard above restores SSH on its own 120 s clock, and the apply path
    // after this inventory still needs its share of that window.
    bool inventoried = false;
    const auto retry_until = std::chrono::steady_clock::now() + std::chrono::seconds(30);
    for (int attempt = 0; attempt < 4 && !inventoried; ++attempt) {
        if (attempt) {
            auto left = std::chrono::duration_cast<std::chrono::seconds>(
                retry_until - std::chrono::steady_clock::now()).count();
            if (left < 1) break;
            // Wait for the daemon only after a failure, so a transport that
            // answers at once never pays for the probe.
            if (!commission_wait_port(connection.host, connection.source, connection.port, left < 10 ? (int)left : 10))
                poll(nullptr, 0, 1000);
        }
        transport_diagnostic.clear();
        inventoried = ct_commission_ssh(connection, commission_runtime_program(), runtime_before, 20, &transport_diagnostic);
        auto ends = [&](const char *suffix) {
            size_t n = std::char_traits<char>::length(suffix);
            return transport_diagnostic.size() >= n &&
                transport_diagnostic.compare(transport_diagnostic.size() - n, n, suffix) == 0;
        };
        if (inventoried || transport_diagnostic.rfind("ssh_before_program_exit_", 0) != 0 ||
            !(ends("_connection_refused") || ends("_timeout") || ends("_no_route") || ends("_closed_by_router")))
            break;
    }
    if (!inventoried)
        return fail(transport_diagnostic.empty() ? "privileged_runtime_inventory_unavailable" : transport_diagnostic.c_str());
    if (!commission_runtime_valid(runtime_before)) return fail("privileged_runtime_inventory_unqualified");
    if (action == "qos") {
        // QoS is a distinct effect class from optional-service cleanup: its
        // baseline is the interface's own qdisc state, and its restore is the
        // kernel default. It never rewrites nvram or service flags.
        std::string op, iface, mode;
        long kbps = 0, overhead = 0;
        if (!str_field(body, "qos_op", 8, true, op) ||
            !str_field(body, "qos_interface", 8, false, iface))
            return fail("qos_profile_invalid");
        if (op != "apply" && op != "restore" && op != "status") return fail("qos_operation_unsupported");
        if (iface.empty() && (op == "restore" || op == "status")) iface = qos_owned_interface(directory);
        if (iface.empty() && op == "status") iface = "eth0";
        if (iface != "eth0" && iface != "ppp0") return fail("qos_interface_unsupported");
        if (op == "apply") {
            if (!str_field(body, "qos_mode", 16, true, mode) ||
                !json_int(body, "qos_bandwidth_kbps", kbps) ||
                !json_int(body, "qos_overhead_bytes", overhead))
                return fail("qos_profile_invalid");
            if (mode != "cake" && mode != "fq_codel") return fail("qos_mode_unsupported");
            if (kbps < 256 || kbps > 100000) return fail("qos_bandwidth_out_of_range");
            if (overhead < 0 || overhead > 200) return fail("qos_overhead_out_of_range");
        }
        std::string probe;
        if (!ct_commission_ssh(connection, commission_qdisc_probe(iface), probe, 20,
                               &transport_diagnostic))
            return fail(transport_diagnostic.empty() ? "qdisc_probe_unavailable"
                                                     : transport_diagnostic.c_str());
        if (probe.find("qdisc_tool=absent") != std::string::npos)
            return fail("qdisc_tool_unavailable");
        if (qdisc_root_kind(probe).empty()) return fail("qdisc_root_unreadable");
        // events.jsonl is last-write-wins for the whole directory, so a later
        // unrelated restore would erase the qdisc record. Keep it in its own
        // file as well; the before/ownership markers remain the durable state.
        const auto record = [&](const std::string &receipt) -> bool {
            return commission_save(directory + "/qos-last.json", receipt, true) &&
                   commission_save(directory + "/events.jsonl", receipt + "\n", true);
        };
        // Read-only preflight: prove the qdisc tool and the current root kind
        // before the owner commits to a window. It never installs or removes a
        // qdisc and never rewrites a service flag.
        if (op == "status") {
            std::string receipt = "{\"phase\":\"qos_status\",\"authenticated\":true,\"changed\":false,"
                "\"qos_verified\":true,\"qos_interface\":\"" + iface + "\",\"qdisc\":\"" +
                qdisc_excerpt(probe) + "\",\"qdisc_tool\":\"present\",\"owned_interface\":\"" +
                qos_owned_interface(directory) + "\",\"settings\":" + commission_object(current) + "}";
            if (!record(receipt))
                return fail("qos_receipt_not_durable");
            bootstrap.done(commission_ssh_settings(s, current, user, password));
            return commission_emit(out, out_len, receipt);
        }
        if (op == "restore") {
            if (qdisc_default_kind(probe)) {
                if (!commission_save(directory + "/qos-owned.txt", iface + "\nnone\n", true))
                    return fail("qos_ownership_not_durable");
                std::string receipt = "{\"phase\":\"qos_restored\",\"authenticated\":true,"
                    "\"qos_verified\":true,\"changed\":false,\"qos_interface\":\"" + iface +
                    "\",\"qdisc\":\"" + qdisc_excerpt(probe) + "\",\"settings\":" +
                    commission_object(current) + "}";
                if (!record(receipt))
                    return fail("qos_receipt_not_durable");
                bootstrap.done(commission_ssh_settings(s, current, user, password));
                return commission_emit(out, out_len, receipt);
            }
            std::string after;
            if (!ct_commission_ssh(connection, commission_qdisc_restore(iface), after, 20,
                                   &transport_diagnostic))
                return fail(transport_diagnostic.empty() ? "qos_restore_failed"
                                                         : transport_diagnostic.c_str());
            if (!qdisc_default_kind(after)) return fail("qos_restore_unverified");
            if (!commission_save(directory + "/qos-owned.txt", iface + "\nnone\n", true))
                return fail("qos_ownership_not_durable");
            std::string receipt = "{\"phase\":\"qos_restored\",\"authenticated\":true,"
                "\"qos_verified\":true,\"changed\":true,\"qos_interface\":\"" + iface +
                "\",\"qdisc\":\"" + qdisc_excerpt(after) + "\",\"settings\":" +
                commission_object(current) + "}";
            if (!record(receipt))
                return fail("qos_receipt_not_durable");
            bootstrap.done(commission_ssh_settings(s, current, user, password));
            return commission_emit(out, out_len, receipt);
        }
        // Only an unmanaged, kernel-default root — or the qdisc this host last
        // verified — is replaced; a vendor QoS hierarchy belongs to its owner.
        if (!qdisc_default_kind(probe)) {
            if (!qdisc_owned(directory, iface, qdisc_root_kind(probe)))
                return fail("qdisc_root_already_managed");
        } else if (!commission_save(directory + "/qos-before.txt", probe, true)) {
            return fail("qos_baseline_not_durable");
        }
        std::string after;
        bool ran = ct_commission_ssh(connection,
            commission_qdisc_apply(iface, mode, kbps, overhead), after, 30,
            &transport_diagnostic);
        bool verified = false;
        std::string rate = mode == "cake" ? "pending" : "not_applicable";
        if (ran && qdisc_root_kind(after) == mode) {
            if (mode == "fq_codel") {
                verified = true;
            } else {
                double readback = 0;
                if (qdisc_cake_rate_kbit(after, readback) &&
                    std::fabs(readback - (double)kbps) <= 1.0) {
                    rate = "verified";
                    verified = true;
                }
            }
        }
        if (!verified) {
            // A failed or misread apply may still have reached the device.
            // Return it to the kernel default rather than leaving an
            // unverified qdisc in place.
            std::string ignored_restore;
            (void)ct_commission_ssh(connection, commission_qdisc_restore(iface),
                                    ignored_restore, 20);
            return fail(ran ? (rate == "pending" ? "qos_rate_readback_mismatch"
                                                 : "qos_readback_mismatch")
                            : (transport_diagnostic.empty() ? "qos_apply_failed"
                                                            : transport_diagnostic.c_str()));
        }
        if (!commission_save(directory + "/qos-owned.txt", iface + "\n" + mode + "\n", true))
            return fail("qos_ownership_not_durable");
        std::string receipt = "{\"phase\":\"qos_applied\",\"authenticated\":true,"
            "\"qos_verified\":true,\"qos_mode\":\"" + mode + "\",\"qos_interface\":\"" +
            iface + "\",\"bandwidth_kbps\":" + std::to_string(kbps) +
            ",\"overhead_bytes\":" + std::to_string(overhead) +
            ",\"rate_readback\":\"" + rate + "\",\"before_qdisc\":\"" +
            qdisc_excerpt(probe) + "\",\"after_qdisc\":\"" + qdisc_excerpt(after) +
            "\",\"settings\":" + commission_object(current) + "}";
        if (!record(receipt))
            return fail("qos_receipt_not_durable");
        bootstrap.done(commission_ssh_settings(s, current, user, password));
        return commission_emit(out, out_len, receipt);
    }
    if (action == "reboot") {
        const std::string boot = commission_boot_id(runtime_before);
        if (boot.empty()) return fail("current_boot_unavailable");
        // Durably record intent before disruption. Scheduling is not proof of a
        // reboot: only a later protected verification can open persistence.
        std::string receipt = "{\"phase\":\"reboot_requested\",\"authenticated\":true,"
            "\"commissioned\":false,\"persistence_verified\":false,\"boot_id\":\"" + boot + "\"}";
        if (!commission_save(directory + "/events.jsonl", receipt + "\n", true))
            return fail("reboot_intent_not_durable");
        // Restore the original management configuration before reboot, so
        // temporary LAN SSH cannot become a persistent boot setting.
        std::string program = "set -eu\n[ -x /sbin/reboot ] || exit 81\nnvram set sshd_port=" +
            current["sshd_port"] + "\nnvram set sshd_pass=" + current["sshd_pass"] +
            "\nnvram set sshd_enable=" + current["sshd_enable"] +
            "\nnvram commit\n(trap '' HUP; sleep 2; exec /sbin/reboot) </dev/null >/dev/null 2>&1 &\n"
            "printf 'CT_DATA_BEGIN\nreboot_scheduled=true\nCT_DATA_END\n'\n";
        if (!ct_commission_ssh(connection, program, ignored, 20, &transport_diagnostic))
            return fail(transport_diagnostic.empty() ? "reboot_submission_unverified" : transport_diagnostic.c_str());
        bootstrap.done(true);
        return commission_emit(out, out_len, receipt);
    }
    if (action == "runtime" || action == "verify") {
        const std::string path = directory + "/runtime-latest.txt";
        if (!commission_save(path, runtime_before, true)) return fail("runtime_inventory_not_durable");
        if (!commission_ssh_settings(s, current, user, password))
            return fail("original_ssh_postcondition_failed");
        CommissionSnapshot now;
        if (!commission_snapshot(s, now) || !commission_same_core(now, current))
            return fail("runtime_inspection_core_changed");
        for (const auto &feature : commission_features())
            if (now[feature.key] != current[feature.key])
                return fail("runtime_inspection_service_changed");
        bootstrap.done(true);
        const bool persistence = action == "verify";
        if (persistence) {
            std::string boot = commission_boot_id(runtime_before);
            if (boot.empty() || boot == applied_boot)
                return commission_fail(out, out_len, "reboot_not_observed");
            for (const auto &feature : commission_features())
                if (now[feature.key] == "0" &&
                    (commission_process_present(runtime_before, feature.process1) ||
                     commission_process_present(runtime_before, feature.process2)))
                    return commission_fail(out, out_len, "disabled_service_running_after_boot");
        }
        std::string receipt = "{\"phase\":\"" + std::string(persistence ? "persistence_verified" : "runtime_inventory") +
            "\",\"authenticated\":true,\"commissioned\":false,\"runtime_verified\":true,"
            "\"persistence_verified\":" + (persistence ? "true" : "false") +
            ",\"network_load_verified\":false,\"runtime_path\":\"" + path +
            "\",\"settings\":" + commission_object(now) + "}";
        if (!commission_save(directory + "/events.jsonl", receipt + "\n", true))
            return commission_fail(out, out_len, "runtime_receipt_not_durable", true);
        return commission_emit(out, out_len, receipt);
    }
    if (action == "restore") {
        std::string program = "set -eu\n";
        for (size_t i : selected) {
            const auto &f = commission_features()[i];
            program += "nvram set " + std::string(f.key) + "=" + before[f.key] +
                "\nservice " + (before[f.key] == "0" ? f.stop : f.start) + "\n";
        }
        program += "nvram commit\nprintf 'CT_DATA_BEGIN\\nrestored=true\\nCT_DATA_END\\n'\n";
        if (!ct_commission_ssh(connection, program, ignored, 30) ||
            !commission_snapshot(s, current) || !commission_profile_matches(current, before, selected, true))
            return fail("restore_readback_failed");
        if (!commission_ssh_settings(s, before, user, password) ||
            !commission_snapshot(s, current) || !commission_profile_matches(current, before, selected, true))
            return fail("restore_access_readback_failed");
        bootstrap.done(true);
        std::string receipt = "{\"phase\":\"baseline_restored\",\"authenticated\":true,\"commissioned\":false,\"settings\":" +
            commission_object(current) + "}";
        if (!commission_save(directory + "/events.jsonl", receipt + "\n", true))
            return commission_fail(out, out_len, "restore_receipt_not_durable", true);
        return commission_emit(out, out_len, receipt);
    }
    for (size_t i : requested) {
        const auto &f = commission_features()[i];
        if (before[f.key] == "0" && (commission_process_present(runtime_before, f.process1) ||
            commission_process_present(runtime_before, f.process2))) return fail("unqualified_orphaned_service_process");
    }
    if (!commission_save(directory + "/runtime-before.txt", runtime_before))
        return fail("runtime_baseline_not_durable");
    // Failure-first hardware qualification: mutate one approved optional service,
    // close the SSH command, and let the actual device lease expire unaided.
    // The short drill does not rely on a host-issued restore or a model call.
    std::vector<size_t> drill;
    if (!selected.empty()) drill.push_back(selected.front());
    lease = "/tmp/continuum-commission-" + commission_nonce();
    if (!ct_commission_ssh(connection, commission_trial_program(lease, before, drill, 10), ignored, 20))
        return fail("device_recovery_drill_not_armed");
    armed = true;
    bool recovered = false;
    for (int i = 0; i < 17; ++i) {
        poll(nullptr, 0, 1000);
        CommissionSnapshot now;
        if (commission_snapshot(s, now) && commission_profile_matches(now, before, drill, true) &&
            now["sshd_enable"] == before["sshd_enable"] && now["sshd_pass"] == before["sshd_pass"]) {
            recovered = true; break;
        }
    }
    if (!recovered) return fail("device_local_expiry_did_not_restore_trial");
    armed = false;
    if (!commission_ssh_settings(s, access, user, password)) return fail("access_after_recovery_drill_failed");
    std::string after_drill;
    if (!ct_commission_ssh(connection, commission_runtime_program(), after_drill, 20) ||
        !commission_runtime_valid(after_drill)) return fail("runtime_after_recovery_drill_failed");
    for (size_t i : drill) {
        const auto &f = commission_features()[i];
        if ((commission_process_present(runtime_before, f.process1) && !commission_process_present(after_drill, f.process1)) ||
            (commission_process_present(runtime_before, f.process2) && !commission_process_present(after_drill, f.process2)))
            return fail("device_trial_did_not_restore_service_runtime");
    }
    lease = "/tmp/continuum-commission-" + commission_nonce();
    if (!ct_commission_ssh(connection, commission_trial_program(lease, before, selected, 90), ignored, 30))
        return fail("cleanup_lease_not_armed");
    armed = true;
    bool verified = false;
    for (int retry = 0; retry < 5; ++retry) {
        if (retry) poll(nullptr, 0, 1000);
        if (!ct_commission_ssh(connection, commission_runtime_program(), runtime_after, 20) ||
            !commission_runtime_valid(runtime_after)) continue;
        bool clean = true;
        for (size_t i : requested) {
            const auto &f = commission_features()[i];
            if (commission_process_present(runtime_after, f.process1) || commission_process_present(runtime_after, f.process2))
                clean = false;
        }
        if (clean && commission_snapshot(s, current) && commission_profile_matches(current, before, selected, false)) {
            verified = true; break;
        }
    }
    if (!verified) return fail("runtime_or_core_postcondition_failed");
    if (!commission_save(directory + "/runtime-after.txt", runtime_after))
        return fail("runtime_result_not_durable");
    // Commit only while this transaction still owns a pending device lease.
    // A cut after commit but before confirmation intentionally permits rollback.
    std::string commit = "set -eu\nIFS= read -r ct_state < " + lease +
        "/lease\n[ \"$ct_state\" = pending ]\nnvram commit\nprintf 'confirmed\\n' > " + lease +
        "/lease\nprintf 'CT_DATA_BEGIN\\ncommitted=true\\nCT_DATA_END\\n'\n";
    if (!ct_commission_ssh(connection, commit, ignored, 20)) return fail("cleanup_commit_not_verified");
    armed = false;
    if (!commission_ssh_settings(s, before, user, password)) return fail("original_ssh_postcondition_failed");
    bootstrap.done(true);
    if (!commission_snapshot(s, current) || !commission_profile_matches(current, before, selected, false))
        return commission_fail(out, out_len, "final_protected_readback_failed", true);
    std::string receipt = "{\"phase\":\"baseline_applied\",\"authenticated\":true,"
        "\"commissioned\":false,\"runtime_verified\":true,\"recovery_verified\":true,"
        "\"persistent_settings_written\":true,\"persistence_verified\":false,"
        "\"network_load_verified\":false,\"firmware_removed\":false,"
        "\"changed_services\":" + std::to_string(selected.size()) +
        ",\"state_directory\":\"" + directory + "\",\"settings\":" + commission_object(current) + "}";
    if (!commission_save(directory + "/events.jsonl", receipt + "\n", true))
        return commission_fail(out, out_len, "applied_receipt_not_durable", true);
    return commission_emit(out, out_len, receipt);
}

int32_t commission_dispatch(ct_bytes req, ct_output out, int64_t *out_len) {
    if (!out_len || !req.data || !out.data) return CT_INVALID_ARGUMENT;
    *out_len = 0;
    std::string body;
    Session s;
    if (!parse_common((const char *)req.data, req.len, s.ref, body)) return CT_INVALID_ARGUMENT;
    std::string user, ref, action;
    if (!str_field(body, "admin_user", 32, true, user) ||
        !str_field(body, "admin_ref", 128, true, ref) ||
        !str_field(body, "action", 16, true, action)) return CT_INVALID_ARGUMENT;
    if (action != "inspect" && action != "apply" && action != "restore" &&
        action != "authorize" && action != "runtime" && action != "reboot" &&
        action != "verify" && action != "qos" && action != "capabilities")
        return commission_fail(out, out_len, "unsupported_action");
    // Standing setup/optimization permission never authorizes a device reboot.
    // This bit is supplied only by a separately confirmed owner operation, not
    // by the model tool's arguments or any reusable program.
    bool owner_reboot_approved = false;
    if (action == "reboot" && (!json_bool(body, "owner_reboot_approved", owner_reboot_approved) ||
                              !owner_reboot_approved))
        return commission_fail(out, out_len, "owner_reboot_approval_required");
    std::string password;
    // Only the owner's explicit setup action may request Keychain UI. Normal
    // inspection, cleanup and recovery fail closed instead of waiting forever.
    if (!fetch_secret(ref, password, action != "authorize"))
        return commission_fail(out, out_len, "credential_access_requires_owner_authorization");
    if (asus_login(s, user, password) != LoginRc::Ok)
        return commission_fail(out, out_len, "protected_authentication_refused");
    CommissionSnapshot current;
    if (!commission_snapshot(s, current))
        return commission_fail(out, out_len, "protected_inventory_unavailable");
    if (action == "inspect" || action == "authorize")
        return commission_emit(out, out_len,
            "{\"phase\":\"inventory\",\"authenticated\":true,\"commissioned\":false,"
            "\"runtime_verified\":false,\"persistence_verified\":false,"
            "\"recovery_verified\":false,\"settings\":" + commission_object(current) + "}");
    if (action == "capabilities")
        return commission_emit(out, out_len,
            "{\"phase\":\"capabilities\",\"authenticated\":true,\"commissioned\":false,"
            "\"identity\":" + commission_identity(current) +
            ",\"capabilities\":" + commission_capabilities(current) + "}");
    return commission_execute(s, body, action, user, password, ref, current, out, out_len);
}
#endif
