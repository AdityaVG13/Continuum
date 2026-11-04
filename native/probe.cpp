// Network measurement for the optimization loop. One process probes a named
// target twice: idle, then while a sustained bulk transfer fills the same path.
// The deltas are evidence, not a claim: the caller decides what counts as a
// measurable change and refuses to compare when the sample count is too low.
//
// Every probe is a plain HTTP GET over TCP, timed with a monotonic clock and
// closed before the next sample, so no connection reuse hides queueing delay.
// The load generator is a forked child that loops on the same client until its
// deadline; it reports bytes on a pipe so goodput is measured, not asserted.
#include "continuum_native.h"

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

#include <arpa/inet.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/wait.h>
#include <unistd.h>

namespace {

double mono_ms() {
    return std::chrono::duration<double, std::milli>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

bool write_all(int fd, const char *data, size_t len) {
    size_t sent = 0;
    while (sent < len) {
        ssize_t n = send(fd, data + sent, len - sent, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        sent += static_cast<size_t>(n);
    }
    return true;
}

// One exchange: connect, request, drain to EOF. Returns the bytes that actually
// moved and the wall time from connect to the last byte. A refused or stalled
// probe fails the sample instead of contributing a synthetic number.
//
// GET is the latency probe. POST is the load generator for the direction that
// matters on a router: egress shaping only sees traffic the client sends, so an
// upload load is what puts a queue in front of the delay-sensitive flow. A POST
// counts as load only when the server accepted it with a 2xx status; a rejected
// upload is not a filled pipe.
bool http_probe(const std::string &host, int port, const std::string &path,
        int64_t &bytes, double &elapsed_ms, bool upload = false) {
    struct addrinfo hints {};
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *resolved = nullptr;
    const std::string service = std::to_string(port);
    if (getaddrinfo(host.c_str(), service.c_str(), &hints, &resolved) != 0 || !resolved) return false;
    int fd = socket(resolved->ai_family, resolved->ai_socktype, resolved->ai_protocol);
    if (fd < 0) { freeaddrinfo(resolved); return false; }
    struct timeval timeout {};
    timeout.tv_sec = 2;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
    const double started = mono_ms();
    bool ok = connect(fd, resolved->ai_addr, resolved->ai_addrlen) == 0;
    freeaddrinfo(resolved);
    static const std::string upload_body(262144, 'x');
    int64_t sent_body = 0;
    if (ok) {
        std::string request;
        if (upload) {
            request = "POST " + path + " HTTP/1.1\r\nHost: " + host +
                "\r\nContent-Length: " + std::to_string(upload_body.size()) +
                "\r\nConnection: close\r\nUser-Agent: ContinuumProbe/1\r\n\r\n";
            request += upload_body;
            sent_body = static_cast<int64_t>(upload_body.size());
        } else {
            request = "GET " + path + " HTTP/1.1\r\nHost: " + host +
                "\r\nConnection: close\r\nUser-Agent: ContinuumProbe/1\r\n\r\n";
        }
        ok = write_all(fd, request.data(), request.size());
    }
    int64_t total = 0;
    int64_t body = 0;
    bool headers_done = false;
    bool accepted = true;
    std::string head;
    char buffer[8192];
    while (ok) {
        ssize_t n = recv(fd, buffer, sizeof(buffer), 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        total += n;
        if (!headers_done) {
            head.append(buffer, static_cast<size_t>(n));
            const size_t split = head.find("\r\n\r\n");
            if (split != std::string::npos) {
                headers_done = true;
                const size_t space = head.find(' ');
                accepted = !upload || (space != std::string::npos && space + 1 < head.size() &&
                    head[space + 1] == '2');
                body += static_cast<int64_t>(head.size() - (split + 4));
                head.clear();
            } else if (head.size() > 16384) {
                // Not HTTP as expected; count what arrived rather than losing it.
                headers_done = true;
                accepted = !upload;
                body += static_cast<int64_t>(head.size());
                head.clear();
            }
        } else {
            body += n;
        }
    }
    elapsed_ms = mono_ms() - started;
    close(fd);
    if (!ok || total <= 0) return false;
    bytes = upload ? (accepted ? sent_body : 0) : body;
    return true;
}

bool split_target(const std::string &target, std::string &host, int &port, std::string &path) {
    const auto slash = target.find('/');
    const std::string authority = target.substr(0, slash);
    path = slash == std::string::npos ? "/" : target.substr(slash);
    const auto colon = authority.rfind(':');
    if (colon == std::string::npos || colon == 0) return false;
    host = authority.substr(0, colon);
    const std::string port_text = authority.substr(colon + 1);
    if (host.empty() || host.size() > 253 || port_text.empty() || port_text.size() > 5) return false;
    port = std::atoi(port_text.c_str());
    return port >= 1 && port <= 65535 && path.size() <= 1024;
}

double percentile(const std::vector<double> &sorted, double fraction) {
    if (sorted.empty()) return 0.0;
    size_t index = static_cast<size_t>(std::ceil(fraction * static_cast<double>(sorted.size()))) ;
    if (index == 0) index = 1;
    if (index > sorted.size()) index = sorted.size();
    return sorted[index - 1];
}

void append_json_string(std::string &out, const std::string &value) {
    out += '"';
    for (char c : value) {
        if (c == '"' || c == '\\') { out += '\\'; out += c; }
        else if (static_cast<unsigned char>(c) < 0x20) out += ' ';
        else out += c;
    }
    out += '"';
}

std::string fixed(double value, int places = 3) {
    char text[64];
    std::snprintf(text, sizeof(text), "%.*f", places, value);
    return std::string(text);
}

}  // namespace

extern "C" int32_t ct_probe_run(ct_bytes host_bytes, int64_t port, ct_bytes path_bytes,
        int64_t samples, ct_bytes load_path_bytes, int64_t load_ms, int64_t upload,
        ct_output out, int64_t *length) {
    if (!length) return CT_INVALID_ARGUMENT;
    *length = 0;
    if (!host_bytes.data || host_bytes.len <= 0 || host_bytes.len > 253 ||
        !path_bytes.data || path_bytes.len <= 0 || path_bytes.len > 1024 ||
        !load_path_bytes.data || load_path_bytes.len <= 0 || load_path_bytes.len > 1024 ||
        !out.data || out.capacity < 1024 || samples < 1 || samples > 500 ||
        port < 1 || port > 65535 || load_ms < 0 || load_ms > 60000 ||
        (upload != 0 && upload != 1)) return CT_INVALID_ARGUMENT;

    const std::string host(reinterpret_cast<const char *>(host_bytes.data), static_cast<size_t>(host_bytes.len));
    const std::string path(reinterpret_cast<const char *>(path_bytes.data), static_cast<size_t>(path_bytes.len));
    const std::string load_path(reinterpret_cast<const char *>(load_path_bytes.data),
        static_cast<size_t>(load_path_bytes.len));

    std::vector<double> idle;
    std::vector<double> loaded;
    int64_t idle_failures = 0, loaded_failures = 0;
    idle.reserve(static_cast<size_t>(samples));
    loaded.reserve(static_cast<size_t>(samples));

    // Idle window: no competing transfer.
    for (int64_t i = 0; i < samples; i++) {
        int64_t bytes = 0; double ms = 0.0;
        if (http_probe(host, static_cast<int>(port), path, bytes, ms)) idle.push_back(ms);
        else idle_failures += 1;
    }

    // Loaded window: a forked child offers a bulk transfer for the whole window.
    int pipe_fds[2] = {-1, -1};
    pid_t child = -1;
    const int64_t total_load_ms = std::max<int64_t>(load_ms > 0 ? load_ms : 1500,
        samples * 80 + 600);
    if (pipe(pipe_fds) == 0) {
        child = fork();
        if (child == 0) {
            close(pipe_fds[0]);
            const double deadline = mono_ms() + static_cast<double>(total_load_ms);
            int64_t total = 0;
            while (mono_ms() < deadline) {
                int64_t bytes = 0; double ms = 0.0;
                if (http_probe(host, static_cast<int>(port), load_path, bytes, ms, upload == 1)) total += bytes;
                else usleep(20000);
            }
            ssize_t written = write(pipe_fds[1], &total, sizeof(total));
            (void)written;
            close(pipe_fds[1]);
            _exit(0);
        }
        close(pipe_fds[1]);
        if (child > 0) {
            // Let the transfer occupy the path before the first loaded sample.
            usleep(150000);
            for (int64_t i = 0; i < samples; i++) {
                int64_t bytes = 0; double ms = 0.0;
                if (http_probe(host, static_cast<int>(port), path, bytes, ms)) loaded.push_back(ms);
                else loaded_failures += 1;
            }
        }
    }

    int64_t load_bytes = 0;
    if (child > 0) {
        ssize_t got = read(pipe_fds[0], &load_bytes, sizeof(load_bytes));
        close(pipe_fds[0]);
        int status = 0;
        waitpid(child, &status, 0);
        if (got != sizeof(load_bytes)) load_bytes = 0;
    } else if (pipe_fds[0] >= 0) {
        close(pipe_fds[0]);
    }

    if (idle.empty() || loaded.empty()) return CT_FAILED;
    std::sort(idle.begin(), idle.end());
    std::sort(loaded.begin(), loaded.end());
    const double idle_p50 = percentile(idle, 0.50), idle_p95 = percentile(idle, 0.95);
    const double loaded_p50 = percentile(loaded, 0.50), loaded_p95 = percentile(loaded, 0.95);

    std::string json = "{\"schema_version\":1,\"target\":";
    append_json_string(json, host + ":" + std::to_string(port) + path);
    json += ",\"idle_samples\":" + std::to_string(idle.size());
    json += ",\"loaded_samples\":" + std::to_string(loaded.size());
    json += ",\"idle_failures\":" + std::to_string(idle_failures);
    json += ",\"loaded_failures\":" + std::to_string(loaded_failures);
    json += ",\"idle_p50_ms\":" + fixed(idle_p50);
    json += ",\"idle_p95_ms\":" + fixed(idle_p95);
    json += ",\"loaded_p50_ms\":" + fixed(loaded_p50);
    json += ",\"loaded_p95_ms\":" + fixed(loaded_p95);
    json += ",\"p50_delta_ms\":" + fixed(loaded_p50 - idle_p50);
    json += ",\"p95_delta_ms\":" + fixed(loaded_p95 - idle_p95);
    json += ",\"load_bytes\":" + std::to_string(load_bytes);
    json += ",\"load_ms\":" + std::to_string(total_load_ms);
    json += ",\"load_direction\":";
    json += upload == 1 ? "\"upload\"" : "\"download\"";
    json += ",\"load_goodput_kbps\":" + fixed(static_cast<double>(load_bytes) * 8.0 /
        static_cast<double>(total_load_ms), 1);
    json += "}";

    if (json.size() > static_cast<size_t>(out.capacity)) return CT_FAILED;
    std::memcpy(out.data, json.data(), json.size());
    *length = static_cast<int64_t>(json.size());
    return CT_OK;
}
