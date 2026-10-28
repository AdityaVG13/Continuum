// Continuum virtual stock router (C++ test double): the target the
// native transports are exercised against before any real hardware.
//
// Two surfaces, ported from the retired Python lab double:
//   - the item-6 JSON API (/api/login, /api/qos, /api/status,
//     /api/clients, /api/reboot, /api/setup) behind a Bearer session;
//   - the ASUS QIS wizard fixture (/login.cgi, /chpass.cgi,
//     /applyapp.cgi, /appGet.cgi) with factory NVRAM, the wizard-open
//     vs session-first branches, the MaxLen_http_passwd=16 cap, and
//     honest connection cuts where the real httpd cuts.
//
// Deliberate differences from the Python original: state lives in
// memory only (a fresh process is a fresh router; tests used to point
// ROUTER_STATE at scratch files to get exactly that), and secrets are
// still never persisted -- apply drops *_wpa_psk and http_passwd from
// NVRAM exactly like the original, keeping only password hashes.
//
//   ROUTER_PASSWORD=test-only-pw [ROUTER_WIZARD=1|session]
//       router_double [port]        (bind: ROUTER_BIND, default 127.0.0.1)
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

#include <array>
#include <cerrno>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace {

// ---------------------------------------------------------------- hashes
// MD5 (RFC 1321) and SHA-256 (FIPS 180-4), hex digests. Present only
// because the fixture protocols name them; nothing here is a
// production security use.
struct Md5 {
    uint32_t h[4] = {0x67452301u, 0xefcdab89u, 0x98badcfeu, 0x10325476u};
    static uint32_t rol(uint32_t x, int n) {
        return (x << n) | (x >> (32 - n));
    }
    void block(const uint8_t *p) {
        static const uint32_t K[64] = {
            0xd76aa478, 0xe8c7b756, 0x242070db, 0xc1bdceee, 0xf57c0faf,
            0x4787c62a, 0xa8304613, 0xfd469501, 0x698098d8, 0x8b44f7af,
            0xffff5bb1, 0x895cd7be, 0x6b901122, 0xfd987193, 0xa679438e,
            0x49b40821, 0xf61e2562, 0xc040b340, 0x265e5a51, 0xe9b6c7aa,
            0xd62f105d, 0x02441453, 0xd8a1e681, 0xe7d3fbc8, 0x21e1cde6,
            0xc33707d6, 0xf4d50d87, 0x455a14ed, 0xa9e3e905, 0xfcefa3f8,
            0x676f02d9, 0x8d2a4c8a, 0xfffa3942, 0x8771f681, 0x6d9d6122,
            0xfde5380c, 0xa4beea44, 0x4bdecfa9, 0xf6bb4b60, 0xbebfbc70,
            0x289b7ec6, 0xeaa127fa, 0xd4ef3085, 0x04881d05, 0xd9d4d039,
            0xe6db99e5, 0x1fa27cf8, 0xc4ac5665, 0xf4292244, 0x432aff97,
            0xab9423a7, 0xfc93a039, 0x655b59c3, 0x8f0ccc92, 0xffeff47d,
            0x85845dd1, 0x6fa87e4f, 0xfe2ce6e0, 0xa3014314, 0x4e0811a1,
            0xf7537e82, 0xbd3af235, 0x2ad7d2bb, 0xeb86d391};
        static const int S[64] = {7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
                                  7, 12, 17, 22, 5, 9,  14, 20, 5, 9,  14, 20,
                                  5, 9,  14, 20, 5, 9,  14, 20, 4, 11, 16, 23,
                                  4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
                                  6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
                                  6, 10, 15, 21};
        uint32_t m[16];
        for (int i = 0; i < 16; i++)
            m[i] = (uint32_t)p[i * 4] | ((uint32_t)p[i * 4 + 1] << 8) |
                   ((uint32_t)p[i * 4 + 2] << 16) |
                   ((uint32_t)p[i * 4 + 3] << 24);
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3];
        for (int i = 0; i < 64; i++) {
            uint32_t f;
            int g;
            if (i < 16) {
                f = (b & c) | (~b & d);
                g = i;
            } else if (i < 32) {
                f = (d & b) | (~d & c);
                g = (5 * i + 1) % 16;
            } else if (i < 48) {
                f = b ^ c ^ d;
                g = (3 * i + 5) % 16;
            } else {
                f = c ^ (b | ~d);
                g = (7 * i) % 16;
            }
            uint32_t tmp = d;
            d = c;
            c = b;
            b = b + rol(a + f + K[i] + m[g], S[i]);
            a = tmp;
        }
        h[0] += a;
        h[1] += b;
        h[2] += c;
        h[3] += d;
    }
};

std::string md5_hex(const std::string &in) {
    std::vector<uint8_t> msg(in.begin(), in.end());
    uint64_t bits = (uint64_t)in.size() * 8;
    msg.push_back(0x80);
    while (msg.size() % 64 != 56) msg.push_back(0);
    for (int i = 0; i < 8; i++) msg.push_back((uint8_t)(bits >> (8 * i)));
    Md5 md;
    for (size_t off = 0; off < msg.size(); off += 64) md.block(&msg[off]);
    char out[33];
    char *w = out;
    for (int i = 0; i < 4; i++)
        for (int j = 0; j < 4; j++)
            w += std::snprintf(w, 3, "%02x", (md.h[i] >> (8 * j)) & 0xff);
    return std::string(out, 32);
}

struct Sha256 {
    uint32_t h[8] = {0x6a09e667u, 0xbb67ae85u, 0x3c6ef372u, 0xa54ff53au,
                     0x510e527fu, 0x9b05688cu, 0x1f83d9abu, 0x5be0cd19u};
    static uint32_t ror(uint32_t x, int n) {
        return (x >> n) | (x << (32 - n));
    }
    void block(const uint8_t *p) {
        static const uint32_t K[64] = {
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b,
            0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01,
            0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7,
            0xc19bf174, 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
            0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152,
            0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
            0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc,
            0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819,
            0xd6990624, 0xf40e3585, 0x106aa070, 0x19a4c116, 0x1e376c08,
            0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f,
            0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
            0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2};
        uint32_t w[64];
        for (int i = 0; i < 16; i++)
            w[i] = ((uint32_t)p[i * 4] << 24) | ((uint32_t)p[i * 4 + 1] << 16) |
                   ((uint32_t)p[i * 4 + 2] << 8) | (uint32_t)p[i * 4 + 3];
        for (int i = 16; i < 64; i++) {
            uint32_t s0 = ror(w[i - 15], 7) ^ ror(w[i - 15], 18) ^ (w[i - 15] >> 3);
            uint32_t s1 = ror(w[i - 2], 17) ^ ror(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5],
                 g = h[6], hh = h[7];
        for (int i = 0; i < 64; i++) {
            uint32_t s1 = ror(e, 6) ^ ror(e, 11) ^ ror(e, 25);
            uint32_t ch = (e & f) ^ (~e & g);
            uint32_t t1 = hh + s1 + ch + K[i] + w[i];
            uint32_t s0 = ror(a, 2) ^ ror(a, 13) ^ ror(a, 22);
            uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
            uint32_t t2 = s0 + mj;
            hh = g;
            g = f;
            f = e;
            e = d + t1;
            d = c;
            c = b;
            b = a;
            a = t1 + t2;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d;
        h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }
};

std::string sha256_hex(const std::string &in) {
    std::vector<uint8_t> msg(in.begin(), in.end());
    uint64_t bits = (uint64_t)in.size() * 8;
    msg.push_back(0x80);
    while (msg.size() % 64 != 56) msg.push_back(0);
    for (int i = 7; i >= 0; i--) msg.push_back((uint8_t)(bits >> (8 * i)));
    Sha256 sh;
    for (size_t off = 0; off < msg.size(); off += 64) sh.block(&msg[off]);
    std::string out;
    char buf[9];
    for (int i = 0; i < 8; i++) {
        std::snprintf(buf, sizeof buf, "%08x", sh.h[i]);
        out += buf;
    }
    return out;
}

// ------------------------------------------------------------- codecs
std::string b64_decode(const std::string &in) {
    static const std::string alpha =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    int val = 0, bits = -8;
    for (char c : in) {
        size_t p = alpha.find(c);
        if (p == std::string::npos) {
            if (c == '=') break;
            continue;
        }
        val = (val << 6) | (int)p;
        bits += 6;
        if (bits >= 0) {
            out += (char)((val >> bits) & 0xff);
            bits -= 8;
        }
    }
    return out;
}

int hex_val(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

std::string url_decode(const std::string &in) {
    std::string out;
    for (size_t i = 0; i < in.size(); i++) {
        if (in[i] == '%' && i + 2 < in.size() && hex_val(in[i + 1]) >= 0 &&
            hex_val(in[i + 2]) >= 0) {
            out += (char)(hex_val(in[i + 1]) * 16 + hex_val(in[i + 2]));
            i += 2;
        } else if (in[i] == '+') {
            out += ' ';
        } else {
            out += in[i];
        }
    }
    return out;
}

std::map<std::string, std::string> parse_qs(const std::string &raw) {
    std::map<std::string, std::string> out;
    size_t at = 0;
    while (at <= raw.size()) {
        size_t amp = raw.find('&', at);
        std::string pair =
            raw.substr(at, amp == std::string::npos ? amp : amp - at);
        size_t eq = pair.find('=');
        if (eq != std::string::npos && !pair.empty())
            out[url_decode(pair.substr(0, eq))] =
                url_decode(pair.substr(eq + 1));
        if (amp == std::string::npos) break;
        at = amp + 1;
    }
    return out;
}

// Minimal flat-JSON field access, same substring discipline as the
// transports: exact for the fixed request shapes our clients emit.
bool json_str(const std::string &body, const char *key, std::string &out) {
    std::string pat = "\"" + std::string(key) + "\":";
    size_t p = body.find(pat);
    if (p == std::string::npos) return false;
    size_t a = p + pat.size();
    while (a < body.size() && (body[a] == ' ' || body[a] == '\t')) a++;
    if (a >= body.size() || body[a] != '"') return false;
    size_t b = body.find('"', a + 1);
    if (b == std::string::npos) return false;
    out = body.substr(a + 1, b - a - 1);
    return true;
}

bool json_int(const std::string &body, const char *key, long &out) {
    std::string pat = "\"" + std::string(key) + "\":";
    size_t p = body.find(pat);
    if (p == std::string::npos) return false;
    size_t a = p + pat.size();
    while (a < body.size() && (body[a] == ' ' || body[a] == '\t')) a++;
    if (a >= body.size()) return false;
    char *end = nullptr;
    long v = std::strtol(body.c_str() + a, &end, 10);
    if (end == body.c_str() + a) return false;
    out = v;
    return true;
}

bool json_bool(const std::string &body, const char *key, bool &out) {
    std::string pat = "\"" + std::string(key) + "\":";
    size_t p = body.find(pat);
    if (p == std::string::npos) return false;
    size_t a = p + pat.size();
    while (a < body.size() && (body[a] == ' ' || body[a] == '\t')) a++;
    if (body.compare(a, 4, "true") == 0) { out = true; return true; }
    if (body.compare(a, 5, "false") == 0) { out = false; return true; }
    return false;
}

std::string json_escape(const std::string &in) {
    std::string out;
    for (char c : in) {
        if (c == '"' || c == '\\') out += '\\';
        if ((unsigned char)c < 0x20) {
            char buf[8];
            std::snprintf(buf, sizeof buf, "\\u%04x", (unsigned char)c);
            out += buf;
        } else {
            out += c;
        }
    }
    return out;
}

std::string random_hex(int nbytes) {
    static uint64_t counter = 0;
    std::string seed;
    std::FILE *f = std::fopen("/dev/urandom", "rb");
    if (f) {
        char buf[32];
        size_t n = std::fread(buf, 1, sizeof buf, f);
        seed.assign(buf, n);
        std::fclose(f);
    }
    seed += std::to_string((long long)std::time(nullptr)) +
            std::to_string((long long)++counter);
    return sha256_hex(seed).substr(0, (size_t)nbytes * 2);
}

bool const_eq(const std::string &a, const std::string &b) {
    if (a.size() != b.size()) return false;
    unsigned diff = 0;
    for (size_t i = 0; i < a.size(); i++) diff |= (unsigned)(a[i] ^ b[i]);
    return diff == 0;
}

// ---------------------------------------------------------------- state
const long kSessionTtl = 3600;
const long kMaxAdminLen = 16;

struct State {
    long revision = 1;
    long boot_id = 0;
    bool qos_on = false;
    long qos_rate = 100;
    bool setup_done = true;
    std::string ssid = "LAB-OPEN";
    std::string admin_pw_sha256;
    std::string admin_pw_md5;
    bool has_nvram = false;
    bool wizard_open = false;
    std::map<std::string, std::string> nvram;
} G;

std::map<std::string, long> g_sessions;       // Bearer token -> expiry
std::map<std::string, long> g_asus_sessions;  // asus_token -> expiry
std::string g_password;                       // ROUTER_PASSWORD

std::map<std::string, std::string> factory_nvram() {
    std::map<std::string, std::string> nv = {
        {"productid", "RT-TEST"}, {"x_Setting", "0"}, {"w_Setting", "0"},
        {"sw_mode", "1"},         {"wlc_psta", "0"},  {"wlc_dpsta", "0"},
        {"smart_connect_x", "0"}, {"wan_unit", "0"},  {"wan_proto", "dhcp"},
        {"wan_dhcpenable_x", "1"}, {"wan_dnsenable_x", "1"},
        {"http_username", "admin"}};
    const char *suf[3] = {"_2G", "_5G", "_5G2"};
    for (int i = 0; i < 3; i++) {
        std::string p = "wl" + std::to_string(i) + "_";
        nv[p + "ssid"] = std::string("TEST") + suf[i];
        nv[p + "auth_mode_x"] = "open";
        nv[p + "crypto"] = "aes";
        nv[p + "mfp"] = "0";
        nv[p + "11ax"] = "1";
    }
    nv["wl3_ssid"] = "";
    return nv;
}

bool password_ok(const std::string &pw) {
    // After setup the stored hash is the credential and the
    // environment (factory) password is dead, like real firmware.
    if (!G.admin_pw_sha256.empty())
        return const_eq(sha256_hex(pw), G.admin_pw_sha256);
    return !g_password.empty() && const_eq(pw, g_password);
}

// ---------------------------------------------------------------- http
struct Request {
    std::string method;
    std::string path;
    std::string query;
    std::string cookie;
    std::string authorization;
    std::string body;
};

bool read_request(int fd, Request &rq) {
    std::string raw;
    char buf[8192];
    size_t hdr_end = std::string::npos;
    while ((hdr_end = raw.find("\r\n\r\n")) == std::string::npos) {
        if (raw.size() > 32768) return false;
        ssize_t n = recv(fd, buf, sizeof buf, 0);
        if (n <= 0) return false;
        raw.append(buf, (size_t)n);
    }
    std::string head = raw.substr(0, hdr_end);
    size_t eol = head.find("\r\n");
    std::string line = head.substr(0, eol);
    char method[16] = {0};
    char target[4096] = {0};
    if (std::sscanf(line.c_str(), "%15s %4095s", method, target) != 2)
        return false;
    rq.method = method;
    std::string tgt = target;
    size_t q = tgt.find('?');
    rq.path = q == std::string::npos ? tgt : tgt.substr(0, q);
    rq.query = q == std::string::npos ? "" : tgt.substr(q + 1);
    long content_len = 0;
    size_t at = eol == std::string::npos ? head.size() : eol + 2;
    while (at < head.size()) {
        size_t e = head.find("\r\n", at);
        std::string h =
            head.substr(at, e == std::string::npos ? e : e - at);
        size_t colon = h.find(':');
        if (colon != std::string::npos) {
            std::string name = h.substr(0, colon);
            std::string val = h.substr(colon + 1);
            size_t s = val.find_first_not_of(" \t");
            if (s != std::string::npos) val = val.substr(s);
            std::string low;
            for (char c : name)
                low += (char)tolower((unsigned char)c);
            if (low == "content-length")
                content_len = std::atol(val.c_str());
            else if (low == "cookie")
                rq.cookie = val;
            else if (low == "authorization")
                rq.authorization = val;
        }
        if (e == std::string::npos) break;
        at = e + 2;
    }
    if (content_len < 0 || content_len > 65536) return false;
    std::string body = raw.substr(hdr_end + 4);
    while ((long)body.size() < content_len) {
        ssize_t n = recv(fd, buf, sizeof buf, 0);
        if (n <= 0) return false;
        body.append(buf, (size_t)n);
    }
    rq.body = body.substr(0, (size_t)content_len);
    return true;
}

void send_all(int fd, const std::string &data) {
    size_t sent = 0;
    while (sent < data.size()) {
        ssize_t n = send(fd, data.data() + sent, data.size() - sent, 0);
        if (n <= 0) return;
        sent += (size_t)n;
    }
}

const char *reason(int code) {
    switch (code) {
        case 200: return "OK";
        case 400: return "Bad Request";
        case 401: return "Unauthorized";
        case 403: return "Forbidden";
        case 404: return "Not Found";
        case 409: return "Conflict";
        default: return "Error";
    }
}

void respond(int fd, int code, const std::string &body,
             const std::string &content_type,
             const std::string &cookie = "") {
    std::string r = "HTTP/1.0 " + std::to_string(code) + " " + reason(code) +
                    "\r\nContent-Type: " + content_type +
                    "\r\nContent-Length: " + std::to_string(body.size()) +
                    "\r\n";
    if (!cookie.empty()) r += "Set-Cookie: " + cookie + "\r\n";
    r += "Connection: close\r\n\r\n" + body;
    send_all(fd, r);
}

void json(int fd, int code, const std::string &body) {
    respond(fd, code, body, "application/json");
}

void text(int fd, int code, const std::string &body,
          const std::string &cookie = "") {
    respond(fd, code, body, "text/html", cookie);
}

// The real httpd cuts the connection on a refused wizard-open chpass
// and while restarting for a credential change; model the cut
// honestly instead of inventing an error body.
void cut(int fd) { close(fd); }

bool bearer_authed(const Request &rq) {
    if (rq.authorization.compare(0, 7, "Bearer ") != 0) return false;
    std::string tok = rq.authorization.substr(7);
    auto it = g_sessions.find(tok);
    if (it == g_sessions.end()) return false;
    if (it->second < (long)std::time(nullptr)) {
        g_sessions.erase(it);
        return false;
    }
    return true;
}

bool asus_authed(const Request &rq) {
    size_t at = 0;
    while (at <= rq.cookie.size()) {
        size_t sc = rq.cookie.find(';', at);
        std::string part =
            rq.cookie.substr(at, sc == std::string::npos ? sc : sc - at);
        size_t s = part.find_first_not_of(" \t");
        if (s != std::string::npos) part = part.substr(s);
        if (part.compare(0, 11, "asus_token=") == 0) {
            auto it = g_asus_sessions.find(part.substr(11));
            return it != g_asus_sessions.end() &&
                   it->second >= (long)std::time(nullptr);
        }
        if (sc == std::string::npos) break;
        at = sc + 1;
    }
    return false;
}

// --------------------------------------------------------- ASUS surface
void asus_login(int fd, const Request &rq) {
    auto form = parse_qs(rq.body);
    std::string auth = b64_decode(form["login_authorization"]);
    size_t colon = auth.find(':');
    std::string user = colon == std::string::npos ? "" : auth.substr(0, colon);
    std::string pw = colon == std::string::npos ? "" : auth.substr(colon + 1);
    bool ok = G.has_nvram && user == G.nvram["http_username"] &&
              const_eq(sha256_hex(pw), G.admin_pw_sha256);
    if (!ok) {
        // Firmware answers 200 with the login page and no token.
        text(fd, 200, "<html>Main_Login</html>");
        return;
    }
    std::string tok = random_hex(16);
    g_asus_sessions[tok] = (long)std::time(nullptr) + kSessionTtl;
    text(fd, 200, "<html>index</html>",
         "asus_token=" + tok + "; HttpOnly; path=/");
}

void asus_chpass(int fd, const Request &rq) {
    if (!G.has_nvram) {
        json(fd, 404, "{\"error\": \"no wizard state\"}");
        return;
    }
    auto form = parse_qs(rq.body);
    std::string new_user = b64_decode(form["new_username"]);
    std::string new_pw = b64_decode(form["new_passwd"]);
    if (form.count("cur_passwd")) {
        // Authenticated rotation: session + hex-MD5 current creds.
        if (!asus_authed(rq)) {
            text(fd, 200, "<html>Main_Login</html>");
            return;
        }
        if (!const_eq(form["cur_username"], md5_hex(G.nvram["http_username"])) ||
            !const_eq(form["cur_passwd"], G.admin_pw_md5)) {
            json(fd, 403, "{\"error\": \"current credential refused\"}");
            return;
        }
    } else if (!G.wizard_open) {
        // Open chpass on a session-first box: refused by cut, and the
        // unit drops passwordless trust (x_Setting flips) -- as live.
        G.nvram["x_Setting"] = "1";
        cut(fd);
        return;
    }
    if ((long)new_pw.size() > kMaxAdminLen) {
        cut(fd);
        return;
    }
    G.nvram["http_username"] = new_user;
    G.admin_pw_sha256 = sha256_hex(new_pw);
    G.admin_pw_md5 = md5_hex(new_pw);
    g_asus_sessions.clear();
    const char *cut_env = std::getenv("ROUTER_WIZARD_CUT_CHPASS");
    if (cut_env && std::string(cut_env) == "1") {
        cut(fd);  // stored, then httpd restarts mid-reply (live)
        return;
    }
    json(fd, 200, "{}");
}

void asus_apply(int fd, const Request &rq) {
    if (!G.has_nvram) {
        json(fd, 404, "{\"error\": \"no wizard state\"}");
        return;
    }
    if (!asus_authed(rq) && !G.wizard_open) {
        text(fd, 200, "<html>Main_Login</html>");
        return;
    }
    auto form = parse_qs(rq.body);
    for (int i = 0; i < 4; i++) {
        auto it = form.find("wl" + std::to_string(i) + "_wpa_psk");
        if (it != form.end() &&
            (it->second.size() < 8 || it->second.size() > 63)) {
            json(fd, 400, "{\"error\": \"psk 8..63\"}");
            return;
        }
    }
    for (auto &[k, v] : form) {
        bool psk_key = k.size() >= 8 && k.compare(k.size() - 8, 8, "_wpa_psk") == 0;
        if (psk_key || k == "http_passwd")
            continue;  // secrets are never persisted by the double
        G.nvram[k] = v;
    }
    G.setup_done = true;
    G.wizard_open = false;  // passwordless trust ends with setup
    G.ssid = G.nvram["wl0_ssid"];
    G.revision += 1;
    json(fd, 200, "{}");
}

void asus_appget(int fd, const Request &rq) {
    if (!G.has_nvram) {
        json(fd, 404, "{\"error\": \"no wizard state\"}");
        return;
    }
    if (!asus_authed(rq) && !G.wizard_open) {
        text(fd, 200, "<html>Main_Login.asp</html>");
        return;
    }
    auto qs = parse_qs(rq.query);
    std::string hook = qs["hook"];
    std::string out = "{";
    bool first = true;
    size_t at = 0;
    while (at <= hook.size()) {
        size_t sc = hook.find(';', at);
        std::string call =
            hook.substr(at, sc == std::string::npos ? sc : sc - at);
        size_t s = call.find_first_not_of(" \t");
        size_t e = call.find_last_not_of(" \t");
        if (s != std::string::npos) call = call.substr(s, e - s + 1);
        std::string entry;
        if (call.rfind("nvram_get(", 0) == 0 && !call.empty() &&
            call.back() == ')') {
            std::string key = call.substr(10, call.size() - 11);
            auto it = G.nvram.find(key);
            entry = "\"" + json_escape(key) + "\": \"" +
                    json_escape(it == G.nvram.end() ? "" : it->second) + "\"";
        } else if (call == "get_ui_support()") {
            entry = "\"get_ui_support\": {\"MaxLen_http_passwd\": \"" +
                    std::to_string(kMaxAdminLen) + "\"}";
        } else if (call == "get_clientlist()") {
            entry = "\"get_clientlist\": {}";
        }
        if (!entry.empty()) {
            if (!first) out += ", ";
            out += entry;
            first = false;
        }
        if (sc == std::string::npos) break;
        at = sc + 1;
    }
    out += "}";
    json(fd, 200, out);
}

// ------------------------------------------------------------ API surface
std::string qos_json() {
    return "{\"qos\": {\"on\": " + std::string(G.qos_on ? "true" : "false") +
           ", \"rate_mbit\": " + std::to_string(G.qos_rate) +
           "}, \"revision\": " + std::to_string(G.revision) + "}";
}

void handle(int fd, const Request &rq) {
    const std::string &path = rq.path;
    if (rq.method == "GET" && path == "/appGet.cgi") {
        asus_appget(fd, rq);
        return;
    }
    if (rq.method == "POST") {
        if (path == "/login.cgi") { asus_login(fd, rq); return; }
        if (path == "/chpass.cgi") { asus_chpass(fd, rq); return; }
        if (path == "/applyapp.cgi") { asus_apply(fd, rq); return; }
        if (path == "/api/setup") {
            // First-run setup is unauthenticated on factory firmware;
            // it exists exactly until setup lands.
            if (G.setup_done) {
                json(fd, 409, "{\"error\": \"setup already done\"}");
                return;
            }
            std::string admin_pw, ssid, psk;
            if (!json_str(rq.body, "admin_password", admin_pw) ||
                admin_pw.size() < 8 || admin_pw.size() > 64) {
                json(fd, 400, "{\"error\": \"admin_password 8..64\"}");
                return;
            }
            if (!json_str(rq.body, "ssid", ssid) || ssid.empty() ||
                ssid.size() > 32) {
                json(fd, 400, "{\"error\": \"ssid 1..32\"}");
                return;
            }
            if (!json_str(rq.body, "psk", psk) || psk.size() < 8 ||
                psk.size() > 63) {
                json(fd, 400, "{\"error\": \"psk 8..63\"}");
                return;
            }
            G.admin_pw_sha256 = sha256_hex(admin_pw);
            G.ssid = ssid;
            G.setup_done = true;
            G.revision += 1;
            g_sessions.clear();
            json(fd, 200,
                 "{\"setup_done\": true, \"ssid\": \"" + json_escape(ssid) +
                     "\", \"revision\": " + std::to_string(G.revision) + "}");
            return;
        }
        if (path == "/api/login") {
            if (!G.setup_done) {
                json(fd, 409, "{\"error\": \"setup pending\"}");
                return;
            }
            std::string pw;
            if (!json_str(rq.body, "password", pw) || !password_ok(pw)) {
                json(fd, 401, "{\"error\": \"bad credentials\"}");
                return;
            }
            std::string tok = random_hex(16);
            g_sessions[tok] = (long)std::time(nullptr) + kSessionTtl;
            json(fd, 200,
                 "{\"session\": \"" + tok +
                     "\", \"expires_in\": " + std::to_string(kSessionTtl) + "}");
            return;
        }
        if (!bearer_authed(rq)) {
            json(fd, 401, "{\"error\": \"auth required\"}");
            return;
        }
        if (path == "/api/qos") {
            bool on = false;
            if (!json_bool(rq.body, "on", on)) {
                json(fd, 400, "{\"error\": \"need bool 'on'\"}");
                return;
            }
            long rate = G.qos_rate;
            long given = 0;
            if (json_int(rq.body, "rate_mbit", given)) rate = given;
            if (rate < 1 || rate > 1000) {
                json(fd, 400, "{\"error\": \"rate_mbit 1..1000\"}");
                return;
            }
            G.qos_on = on;
            G.qos_rate = rate;
            G.revision += 1;
            json(fd, 200, qos_json());
            return;
        }
        if (path == "/api/reboot") {
            G.revision += 1;
            G.boot_id += 1;
            g_sessions.clear();
            json(fd, 200,
                 "{\"rebooting\": true, \"revision\": " +
                     std::to_string(G.revision) + "}");
            return;
        }
        json(fd, 404, "{\"error\": \"unknown endpoint\"}");
        return;
    }
    if (rq.method == "GET") {
        if (path == "/api/status") {
            json(fd, 200,
                 "{\"revision\": " + std::to_string(G.revision) +
                     ", \"boot_id\": " + std::to_string(G.boot_id) +
                     ", \"setup_done\": " +
                     std::string(G.setup_done ? "true" : "false") +
                     ", \"ssid\": \"" + json_escape(G.ssid) +
                     "\", \"model\": \"ContRouter v0.1 (virtual)\"}");
            return;
        }
        if (!bearer_authed(rq)) {
            json(fd, 401, "{\"error\": \"auth required\"}");
            return;
        }
        if (path == "/api/qos") {
            json(fd, 200, qos_json());
            return;
        }
        if (path == "/api/clients") {
            json(fd, 200,
                 "{\"clients\": [{\"mac\": \"aa:bb:cc:dd:ee:01\", \"ip\": "
                 "\"192.168.1.101\", \"hostname\": \"lab-cli\"}, {\"mac\": "
                 "\"aa:bb:cc:dd:ee:02\", \"ip\": \"192.168.1.102\", "
                 "\"hostname\": \"lab-phone\"}]}");
            return;
        }
        json(fd, 404, "{\"error\": \"unknown endpoint\"}");
        return;
    }
    json(fd, 404, "{\"error\": \"unknown endpoint\"}");
}

}  // namespace

int main(int argc, char **argv) {
    int port = argc > 1 ? std::atoi(argv[1]) : 18080;
    const char *pw = std::getenv("ROUTER_PASSWORD");
    if (!pw || !*pw) {
        std::printf("ROUTER_PASSWORD is empty: refusing to serve\n");
        return 2;
    }
    g_password = pw;
    const char *wiz = std::getenv("ROUTER_WIZARD");
    if (wiz && (std::string(wiz) == "1" || std::string(wiz) == "session")) {
        G.nvram = factory_nvram();
        G.has_nvram = true;
        G.setup_done = false;
        G.admin_pw_sha256 = sha256_hex("admin");
        G.admin_pw_md5 = md5_hex("admin");
        // "session": wizard-open access is already closed (the live
        // post-refused-chpass state); factory login still works.
        G.wizard_open = std::string(wiz) == "1";
    }
    // Localhost by default; ROUTER_BIND only for a deliberate lab LAN.
    const char *bind_env = std::getenv("ROUTER_BIND");
    std::string bind = bind_env && *bind_env ? bind_env : "127.0.0.1";
    int srv = socket(AF_INET, SOCK_STREAM, 0);
    if (srv < 0) return 1;
    int one = 1;
    setsockopt(srv, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    if (inet_pton(AF_INET, bind.c_str(), &addr.sin_addr) != 1) return 1;
    if (::bind(srv, (sockaddr *)&addr, sizeof addr) != 0) return 1;
    if (listen(srv, 16) != 0) return 1;
    std::printf("virtual router on %s:%d (password sha256 prefix %s)\n",
                bind.c_str(), port,
                sha256_hex(g_password).substr(0, 8).c_str());
    std::fflush(stdout);
    for (;;) {
        int fd = accept(srv, nullptr, nullptr);
        if (fd < 0) continue;
        timeval tv{};
        tv.tv_sec = 10;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        Request rq;
        if (read_request(fd, rq)) handle(fd, rq);
        close(fd);
    }
}
