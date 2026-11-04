// Read-only host evidence. Candidates are observed, on-link private IPv4
// gateways/neighbors, never a list of guessed factory IPs. A probe is one GET
// of '/' on a fixed management port; no credentials, redirects or mutations.
#include "continuum_native.h"

#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <poll.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <unistd.h>
#if defined(__APPLE__)
#include <net/if_dl.h>
#include <mach/mach.h>
#endif
#if defined(__APPLE__)
#include <SystemConfiguration/SystemConfiguration.h>
#include <net/route.h>
#include <sys/sysctl.h>
#endif

#include <algorithm>
#include <chrono>
#include <cctype>
#include <cstdlib>
#include <signal.h>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace {
struct Link {
    std::string name, address, mask, kind = "unknown";
    uint32_t ip = 0, netmask = 0;
    bool up = false, loopback = false;
};
struct Candidate { std::string id, address, interface, bind, source; };
struct Snapshot {
    std::vector<Link> links;
    std::vector<Candidate> candidates;
    std::vector<std::string> default_routes;
    bool routes_known = false;
};
void add_default_route(Snapshot &s, unsigned index, uint32_t gateway) {
    char name[IF_NAMESIZE] = {}, address[INET_ADDRSTRLEN] = {};
    if (s.default_routes.size() < 48 && if_indextoname(index, name) &&
        inet_ntop(AF_INET, &gateway, address, sizeof address))
        s.default_routes.push_back(std::string(name) + ':' + address);
}

std::string quoted(const std::string &s) {
    std::string out = "\"";
    for (unsigned char c : s) {
        if (c == '"' || c == '\\') { out += '\\'; out += char(c); }
        else if (c >= 32 && c < 127) out += char(c);
        else out += '?';
    }
    return out + '"';
}
int put(ct_output out, int64_t *n, const std::string &s) {
    if (!n || !out.data || out.capacity <= 0) return CT_INVALID_ARGUMENT;
    *n = 0;
    if (static_cast<int64_t>(s.size()) > out.capacity) return CT_BUFFER_TOO_SMALL;
    std::memcpy(out.data, s.data(), s.size());
    *n = static_cast<int64_t>(s.size());
    return CT_OK;
}
std::string ip_text(uint32_t address) {
    char buffer[INET_ADDRSTRLEN] = {};
    return inet_ntop(AF_INET, &address, buffer, sizeof buffer) ? buffer : "";
}
bool private_ip(uint32_t raw) {
    uint32_t ip = ntohl(raw);
    return (ip >> 24) == 10 || (ip >> 20) == 0xac1 ||
           (ip >> 16) == 0xc0a8 || (ip >> 16) == 0xa9fe;
}
void add_candidate(Snapshot &s, unsigned index, uint32_t raw, const char *source) {
    if (!private_ip(raw) || s.candidates.size() >= 24) return;
    char name[IF_NAMESIZE] = {};
    if (!if_indextoname(index, name)) return;
    for (const auto &link : s.links) {
        if (link.name != name || !link.up || link.loopback || link.ip == raw || !link.netmask ||
            ((link.ip ^ raw) & link.netmask) != 0) continue;
        std::string address = ip_text(raw);
        std::string id = link.name + ":" + address;
        for (const auto &c : s.candidates) if (c.id == id) return;
        s.candidates.push_back({id, address, link.name, link.address, source});
        return;
    }
}

#if defined(__APPLE__)
std::string cf_text(CFStringRef text) {
    char buffer[128] = {};
    return text && CFStringGetCString(text, buffer, sizeof buffer, kCFStringEncodingUTF8) ? buffer : "";
}
void link_kinds(Snapshot &s) {
    CFArrayRef interfaces = SCNetworkInterfaceCopyAll();
    if (!interfaces) return;
    for (CFIndex i = 0; i < CFArrayGetCount(interfaces); ++i) {
        auto iface = static_cast<SCNetworkInterfaceRef>(CFArrayGetValueAtIndex(interfaces, i));
        auto name = cf_text(SCNetworkInterfaceGetBSDName(iface));
        auto type = SCNetworkInterfaceGetInterfaceType(iface);
        for (auto &link : s.links) {
            if (link.name != name || !type) continue;
            if (CFEqual(type, kSCNetworkInterfaceTypeIEEE80211)) link.kind = "wifi";
            else if (CFEqual(type, kSCNetworkInterfaceTypeEthernet)) link.kind = "ethernet";
        }
    }
    CFRelease(interfaces);
}
void routes(Snapshot &s) {
    int mib[] = {CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0};
    size_t size = 0;
    if (sysctl(mib, 6, nullptr, &size, nullptr, 0) != 0 || size > 4 * 1024 * 1024) return;
    std::vector<char> data(size);
    if (sysctl(mib, 6, data.data(), &size, nullptr, 0) != 0) return;
    s.routes_known = true;
    // Default routes first so a full neighbor cache cannot crowd them out.
    for (int pass = 0; pass < 2; ++pass) {
        size_t offset = 0;
        while (offset + sizeof(rt_msghdr) <= size) {
            const auto *message = reinterpret_cast<const rt_msghdr *>(data.data() + offset);
            if (message->rtm_msglen < sizeof(rt_msghdr) || offset + message->rtm_msglen > size) break;
            const sockaddr *addresses[RTAX_MAX] = {};
            const char *p = reinterpret_cast<const char *>(message + 1);
            const char *end = data.data() + offset + message->rtm_msglen;
            bool valid = true;
            for (unsigned a = 0; a < RTAX_MAX; ++a) {
                if (!(message->rtm_addrs & (1 << a))) continue;
                if (p + 2 > end) { valid = false; break; }
                auto *sa = reinterpret_cast<const sockaddr *>(p);
                // Darwin route messages align sockaddr records to 32-bit words,
                // including a zero-length netmask, even in a 64-bit process.
                constexpr size_t alignment = sizeof(uint32_t);
                size_t length = sa->sa_len ? ((sa->sa_len + alignment - 1) & ~(alignment - 1)) : alignment;
                if (p + length > end) { valid = false; break; }
                addresses[a] = sa;
                p += length;
            }
            auto *dst = addresses[RTAX_DST];
            auto *gateway = addresses[RTAX_GATEWAY];
            if (valid && dst && dst->sa_family == AF_INET && dst->sa_len >= sizeof(sockaddr_in) &&
                (message->rtm_flags & RTF_UP)) {
                auto target = reinterpret_cast<const sockaddr_in *>(dst)->sin_addr.s_addr;
                if (pass == 0 && target == 0 && gateway && gateway->sa_family == AF_INET &&
                    gateway->sa_len >= sizeof(sockaddr_in)) {
                    auto address = reinterpret_cast<const sockaddr_in *>(gateway)->sin_addr.s_addr;
                    add_default_route(s, message->rtm_index, address);
                    add_candidate(s, message->rtm_index, address, "default_route");
                } else if (pass == 1 && (message->rtm_flags & RTF_LLINFO)) {
                    add_candidate(s, message->rtm_index, target, "neighbor_cache");
                }
            }
            offset += message->rtm_msglen;
        }
    }
}
#else
void link_kinds(Snapshot &) {}
void routes(Snapshot &s) {
    std::ifstream file("/proc/net/route");
    std::string line;
    s.routes_known = bool(file);
    std::getline(file, line);
    while (std::getline(file, line)) {
        std::istringstream row(line);
        std::string name;
        unsigned long destination = 0, gateway = 0, flags = 0;
        if (row >> name >> std::hex >> destination >> gateway >> flags) {
            if (!destination && gateway && (flags & 1)) {
                add_default_route(s, if_nametoindex(name.c_str()), static_cast<uint32_t>(gateway));
                add_candidate(s, if_nametoindex(name.c_str()), static_cast<uint32_t>(gateway), "default_route");
            }
        }
    }
    std::ifstream arp("/proc/net/arp");
    std::getline(arp, line);
    while (std::getline(arp, line)) {
        std::istringstream row(line);
        std::string address, type, flags, mac, mask, name;
        in_addr ip{};
        if (row >> address >> type >> flags >> mac >> mask >> name &&
            inet_pton(AF_INET, address.c_str(), &ip) == 1 && flags != "0x0")
            add_candidate(s, if_nametoindex(name.c_str()), ip.s_addr, "neighbor_cache");
    }
}
#endif

Snapshot snapshot(bool with_kinds = true) {
    Snapshot s;
    ifaddrs *all = nullptr;
    if (getifaddrs(&all) != 0) return s;
    for (auto *a = all; a && s.links.size() < 48; a = a->ifa_next) {
        if (!a->ifa_addr || !a->ifa_netmask || a->ifa_addr->sa_family != AF_INET) continue;
        Link link;
        link.name = a->ifa_name;
        link.ip = reinterpret_cast<sockaddr_in *>(a->ifa_addr)->sin_addr.s_addr;
        link.netmask = reinterpret_cast<sockaddr_in *>(a->ifa_netmask)->sin_addr.s_addr;
        link.address = ip_text(link.ip);
        link.mask = ip_text(link.netmask);
        link.up = (a->ifa_flags & IFF_UP) != 0;
        link.loopback = (a->ifa_flags & IFF_LOOPBACK) != 0;
        if (link.loopback) link.kind = "loopback";
        s.links.push_back(link);
    }
    freeifaddrs(all);
    if (with_kinds) link_kinds(s);
    std::sort(s.links.begin(), s.links.end(), [](const Link &a, const Link &b) {
        return a.name == b.name ? a.address < b.address : a.name < b.name;
    });
    routes(s);
    return s;
}
std::string describe(const Snapshot &s) {
    std::string out = "{\"provenance\":\"live_host\",\"scope\":\"read_only\",\"routes_known\":";
    out += s.routes_known ? "true" : "false";
    out += ",\"ipv6_management\":\"not_collected\",\"interfaces\":[";
    bool comma = false;
    for (const auto &link : s.links) {
        if (comma) out += ',';
        comma = true;
        out += "{\"name\":" + quoted(link.name) + ",\"address\":" + quoted(link.address) +
               ",\"netmask\":" + quoted(link.mask) + ",\"kind\":" + quoted(link.kind) +
               ",\"up\":" + (link.up ? "true" : "false") + '}';
    }
    out += "],\"candidates\":[";
    comma = false;
    for (const auto &c : s.candidates) {
        if (comma) out += ',';
        comma = true;
        out += "{\"candidate_id\":" + quoted(c.id) + ",\"address\":" + quoted(c.address) +
               ",\"interface\":" + quoted(c.interface) + ",\"source\":" + quoted(c.source) +
               ",\"identity\":\"unverified\"}";
    }
    return out + "],\"note\":\"A gateway is a candidate, not proof of the intended router. No active scan was performed.\"}";
}

// curl has a strict time/byte ceiling, no shell, no proxy/config, no redirect,
// and binds the observed interface's address. Only public title/server data
// survives into the receipt; cookies and raw HTML never reach model context.
std::string probe(const Candidate &c, int port) {
    int fds[2];
    if (pipe(fds) != 0) return "";
    std::string url = std::string(port == 443 || port == 8443 ? "https://" : "http://") +
                      c.address + ':' + std::to_string(port) + '/';
    pid_t pid = fork();
    if (pid == 0) {
        dup2(fds[1], STDOUT_FILENO);
        close(fds[0]); close(fds[1]);
        if (!std::freopen("/dev/null", "w", stderr)) _exit(126);
        execl("/usr/bin/curl", "curl", "-q", "-sS", "--noproxy", "*", "--proto", "=http,https",
              "--connect-timeout", "1", "--max-time", "2", "--max-filesize", "32768",
              "--interface", c.bind.c_str(), "-A", "OpenAI File Downloader, XaiImageApiFetch/1.0",
              "-D", "-", "-w", "\n%{http_code}", url.c_str(), static_cast<char *>(nullptr));
        _exit(127);
    }
    close(fds[1]);
    if (pid < 0) { close(fds[0]); return ""; }
    std::string response;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(3);
    bool eof = false;
    while (std::chrono::steady_clock::now() < deadline && response.size() <= 40000) {
        pollfd fd{fds[0], POLLIN, 0};
        if (poll(&fd, 1, 100) <= 0) continue;
        char buffer[2048];
        ssize_t n = read(fds[0], buffer, sizeof buffer);
        if (n <= 0) { eof = true; break; }
        response.append(buffer, static_cast<size_t>(n));
    }
    close(fds[0]);
    if (!eof) kill(pid, SIGKILL);
    int status = 0;
    waitpid(pid, &status, 0);
    return eof && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? response : "";
}
std::string title(const std::string &body) {
    std::string lower = body;
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) { return std::tolower(c); });
    auto start = lower.find("<title");
    if (start == std::string::npos) return "";
    start = lower.find('>', start);
    auto end = lower.find("</title>", start);
    if (start == std::string::npos || end == std::string::npos) return "";
    return body.substr(start + 1, std::min<size_t>(end - start - 1, 256));
}
// Advisory vendor label from public markers in the unauthenticated landing
// page and its headers. It decides which backend to offer and what to tell
// the owner; it is never identity evidence (enrollment proves that).
std::string vendor(const std::string &response) {
    if (response.empty()) return "";
    std::string lower = response;
    std::transform(lower.begin(), lower.end(), lower.begin(), [](unsigned char c) { return std::tolower(c); });
    auto has = [&](const char *marker) { return lower.find(marker) != std::string::npos; };
    if (has("asus") || has("qis_wizard") || has("main_login.asp") || has("server: httpd/2.0")) return "asus";
    if (has("openwrt") || has("luci")) return "openwrt";
    if (has("netgear") || has("routerlogin")) return "netgear";
    if (has("tp-link") || has("tplink")) return "tp-link";
    if (has("linksys")) return "linksys";
    if (has("unifi") || has("ubiquiti") || has("ubnt")) return "ubiquiti";
    if (has("mikrotik") || has("routeros")) return "mikrotik";
    if (has("fritz!box") || has("fritz")) return "avm";
    if (has("eero")) return "eero";
    if (has("synology")) return "synology";
    return "unknown";
}
} // namespace

extern "C" int32_t ct_host_sample(ct_output out, int64_t *n) {
    auto s = snapshot(false);
    std::sort(s.default_routes.begin(), s.default_routes.end());
    s.default_routes.erase(std::unique(s.default_routes.begin(), s.default_routes.end()), s.default_routes.end());
    std::string signature;
    std::vector<std::string> names;
    for (const auto &route : s.default_routes) {
        if (!signature.empty()) signature += ';';
        signature += route;
        auto name = route.substr(0, route.find(':'));
        if (std::find(names.begin(), names.end(), name) == names.end()) names.push_back(name);
    }
    uint64_t rx = 0, tx = 0, faults = 0;
    size_t collected = 0;
#if defined(__APPLE__)
    ifaddrs *all = nullptr;
    if (getifaddrs(&all) == 0) {
        for (auto *a = all; a; a = a->ifa_next) {
            if (!a->ifa_addr || a->ifa_addr->sa_family != AF_LINK || !a->ifa_data ||
                std::find(names.begin(), names.end(), a->ifa_name) == names.end()) continue;
            const auto *data = static_cast<const if_data *>(a->ifa_data);
            rx += data->ifi_ibytes; tx += data->ifi_obytes;
            faults += uint64_t(data->ifi_ierrors) + data->ifi_oerrors + data->ifi_iqdrops;
            ++collected;
        }
        freeifaddrs(all);
    }
    mach_task_basic_info_data_t info{};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    uint64_t rss = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
        reinterpret_cast<task_info_t>(&info), &count) == KERN_SUCCESS ? info.resident_size : 0;
#else
    std::ifstream devices("/proc/net/dev");
    std::string line;
    while (std::getline(devices, line)) {
        auto colon = line.find(':');
        if (colon == std::string::npos) continue;
        auto name = line.substr(0, colon);
        name.erase(0, name.find_first_not_of(" \t"));
        if (std::find(names.begin(), names.end(), name) == names.end()) continue;
        std::istringstream row(line.substr(colon + 1));
        uint64_t v[16]{}; bool valid = true;
        for (auto &value : v) if (!(row >> value)) { valid = false; break; }
        if (valid) { rx += v[0]; tx += v[8]; faults += v[2] + v[3] + v[10] + v[11]; ++collected; }
    }
    std::ifstream memory("/proc/self/statm");
    uint64_t virtual_pages = 0, resident_pages = 0;
    uint64_t rss = (memory >> virtual_pages >> resident_pages) ?
        resident_pages * static_cast<uint64_t>(sysconf(_SC_PAGESIZE)) : 0;
#endif
    rusage usage{};
    getrusage(RUSAGE_SELF, &usage);
    const int64_t cpu = (usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * int64_t(1000000) +
        usage.ru_utime.tv_usec + usage.ru_stime.tv_usec;
    std::string result = "{\"provenance\":\"live_host\",\"routes_known\":";
    result += s.routes_known ? "true" : "false";
    result +=        ",\"route_signature\":" + quoted(static_cast<const std::string &>(signature)) +
        ",\"ipv4_default_routes\":" + std::to_string(s.default_routes.size()) +
        ",\"counters_known\":" + (collected == names.size() && collected > 0 ? "true" : "false") +
        ",\"rx_bytes\":" + std::to_string(rx) + ",\"tx_bytes\":" + std::to_string(tx) +
        ",\"interface_faults\":" + std::to_string(faults) +
        ",\"process_cpu_us\":" + std::to_string(cpu) + ",\"process_rss_bytes\":" + std::to_string(rss) +
        ",\"latency_ms\":null,\"internet_reachability\":\"not_probed\",\"ipv6\":\"not_collected\"}";
    return put(out, n, result);
}

extern "C" int32_t ct_discover_full(ct_bytes req, ct_output out, int64_t *n) {
    if (!req.data || req.len != 2 || std::memcmp(req.data, "{}", 2)) return CT_INVALID_ARGUMENT;
    return put(out, n, describe(snapshot()));
}
extern "C" int32_t ct_discover_probe(ct_bytes id, int64_t port, ct_output out, int64_t *n) {
    if (!id.data || id.len <= 0 || id.len > 64 ||
        !(port == 80 || port == 443 || port == 8080 || port == 8443)) return CT_INVALID_ARGUMENT;
    std::string candidate(reinterpret_cast<const char *>(id.data), static_cast<size_t>(id.len));
    // Revalidate against current routes: the model cannot substitute an IP,
    // and a disappeared/changed management path does not retain authority.
    for (const auto &c : snapshot().candidates) {
        if (c.id != candidate) continue;
        std::string body = probe(c, static_cast<int>(port));
        auto at = body.rfind('\n');
        int status = at == std::string::npos ? 0 : std::atoi(body.c_str() + at + 1);
        std::string result = "{\"candidate_id\":" + quoted(c.id) + ",\"port\":" + std::to_string(port) +
            ",\"http_status\":" + (status > 0 ? std::to_string(status) : "null") +
            ",\"title\":" + quoted(title(body)) + ",\"vendor\":" + quoted(vendor(body)) +
            ",\"authenticated\":false,\"network_changed\":false,\"content_trust\":\"untrusted_device_data\"}";
        return put(out, n, result);
    }
    return CT_REJECTED;
}
