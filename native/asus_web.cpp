// ASUS QIS onboarding transport: the Class B vendor adapter behind
// src/onboarding.goose's leap planner. Speaks the stock-Asuswrt first-
// setup protocol exactly as the firmware's own QIS wizard JS does
// (recipe reverse-mapped read-only from QIS_wizard.htm and proven live
// twice on bench hardware by the local lab script; the wizard fixture
// in tests/router_double.cpp encodes the same wire behavior):
//
//   discover  GET  /appGet.cgi?hook=nvram_get(...)  wizard-open reads
//             gated on the QIS Referer while x_Setting=0; when the unit
//             demands a session (Main_Login shell), log in with the
//             vendor-published factory credential and read again.
//   rotate    POST /chpass.cgi -- wizard-open {new_username:b64,
//             new_passwd:b64}, or authenticated with cur_* as hex MD5
//             when session-first. A cut reply is data (the firmware
//             refuses the open move by cutting, and restarts httpd on
//             the session move): the branch is proven by a fresh login
//             with the staged credential, never by the POST's reply.
//   apply     POST /applyapp.cgi echoing current NVRAM for every key the
//             leap does not intend to change (the wizard's own
//             postDataModel.insert behavior), rc_service derived like
//             getRestartService(). A reply cut by restart_wireless is
//             submitted+reply_cut, not a failure.
//   verify    POST /login.cgi + protected /appGet.cgi read.
//
// Secrets: staged credentials arrive as vault REFS and resolve through
// ct_vault_fetch inside this adapter; they never appear in request JSON,
// receipts, or logs. factory_user/factory_pass in requests are the
// vendor-published defaults. One deliberate tightening over the Python
// transcript: after a wizard-open chpass returns 200, this adapter still
// proves the staged credential by login before CT_OK -- a 200 from that
// firmware family is not evidence the credential stored.
#include "continuum_native.h"

#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

namespace {

const int kTimeoutSec = 10;
const int kMaxRaw = 131072;
const char *kUA = "OpenAI File Downloader, XaiImageApiFetch/1.0";
const char *kBandSuffix[4] = {"_2G", "_5G", "_5G2", "_6G"};

// --- minimal strict JSON subset (same shapes as router_web.cpp) ---
size_t skip_ws(const std::string &body, size_t p) {
    while (p < body.size() &&
           (body[p] == ' ' || body[p] == '\t' || body[p] == '\n' ||
            body[p] == '\r'))
        p++;
    return p;
}
bool json_str(const std::string &body, const char *key, std::string &out) {
    std::string q = std::string("\"") + key + "\":";
    size_t p = body.find(q);
    if (p == std::string::npos) return false;
    p = skip_ws(body, p + q.size());
    if (p >= body.size() || body[p] != '"') return false;
    p++;
    out.clear();
    while (p < body.size()) {
        char c = body[p++];
        if (c == '"') return out.size() <= 512;
        if (c == '\\' && p < body.size()) {
            char e = body[p++];
            if (e == 'n') out += '\n';
            else if (e == 't') out += '\t';
            else if (e == 'r') out += '\r';
            else out += e;
        } else {
            out += c;
        }
    }
    return false;
}
bool json_int(const std::string &body, const char *key, long &out) {
    std::string q = std::string("\"") + key + "\":";
    size_t p = body.find(q);
    if (p == std::string::npos) return false;
    p = skip_ws(body, p + q.size());
    if (p >= body.size() ||
        !(body[p] == '-' || (body[p] >= '0' && body[p] <= '9')))
        return false;
    size_t e = p + (body[p] == '-' ? 1 : 0);
    while (e < body.size() && body[e] >= '0' && body[e] <= '9') e++;
    if (e == p || e - p > 18) return false;
    out = std::stol(body.substr(p, e - p));
    return true;
}
bool json_bool(const std::string &body, const char *key, bool &out) {
    std::string q = std::string("\"") + key + "\":";
    size_t p = body.find(q);
    if (p == std::string::npos) return false;
    p = skip_ws(body, p + q.size());
    if (body.compare(p, 4, "true") == 0) { out = true; return true; }
    if (body.compare(p, 5, "false") == 0) { out = false; return true; }
    return false;
}

// Router-controlled strings (SSIDs) are echoed into receipts: escape.
void json_escape(const std::string &in, std::string &out) {
    for (char c : in) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if ((unsigned char)c < 0x20) {
                    char b[8];
                    std::snprintf(b, sizeof b, "\\u%04x", (unsigned char)c);
                    out += b;
                } else {
                    out += c;
                }
        }
    }
}

void put_receipt(ct_output out, int64_t *out_len, const std::string &s,
                 int32_t &rc) {
    if ((int64_t)s.size() > out.capacity) {
        rc = CT_BUFFER_TOO_SMALL;
        return;
    }
    std::memcpy(out.data, s.data(), s.size());
    *out_len = (int64_t)s.size();
    rc = CT_OK;
}

// --- base64 / form encoding / MD5 (the wizard's three transforms) ---
std::string b64(const std::string &in) {
    static const char T[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string out;
    for (size_t i = 0; i < in.size(); i += 3) {
        uint32_t v = (uint8_t)in[i] << 16;
        int n = 1;
        if (i + 1 < in.size()) { v |= (uint8_t)in[i + 1] << 8; n = 2; }
        if (i + 2 < in.size()) { v |= (uint8_t)in[i + 2]; n = 3; }
        out += T[(v >> 18) & 63];
        out += T[(v >> 12) & 63];
        out += n > 1 ? T[(v >> 6) & 63] : '=';
        out += n > 2 ? T[v & 63] : '=';
    }
    return out;
}

std::string form_escape(const std::string &in) {
    std::string out;
    for (char c : in) {
        if ((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
            (c >= '0' && c <= '9') || c == '_' || c == '.' || c == '-' ||
            c == '~') {
            out += c;
        } else if (c == ' ') {
            out += '+';
        } else {
            char b[4];
            std::snprintf(b, sizeof b, "%%%02X", (unsigned char)c);
            out += b;
        }
    }
    return out;
}

std::string form_join(const std::vector<std::pair<std::string, std::string>> &f) {
    std::string out;
    for (size_t i = 0; i < f.size(); i++) {
        if (i) out += '&';
        out += form_escape(f[i].first);
        out += '=';
        out += form_escape(f[i].second);
    }
    return out;
}

// RFC 1321 MD5, hex digest. Present only because httpApi.chpass sends
// the current credentials as hex MD5; nothing here is a security use.
std::string md5_hex(const std::string &input) {
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
    static const int S[64] = {
        7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22,
        5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
        4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23,
        6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21};
    std::vector<uint8_t> msg(input.begin(), input.end());
    uint64_t bits = (uint64_t)msg.size() * 8;
    msg.push_back(0x80);
    while (msg.size() % 64 != 56) msg.push_back(0);
    for (int i = 0; i < 8; i++) msg.push_back((uint8_t)(bits >> (8 * i)));
    uint32_t a0 = 0x67452301, b0 = 0xefcdab89, c0 = 0x98badcfe,
             d0 = 0x10325476;
    for (size_t off = 0; off < msg.size(); off += 64) {
        uint32_t m[16];
        for (int i = 0; i < 16; i++)
            m[i] = (uint32_t)msg[off + 4 * i] |
                   ((uint32_t)msg[off + 4 * i + 1] << 8) |
                   ((uint32_t)msg[off + 4 * i + 2] << 16) |
                   ((uint32_t)msg[off + 4 * i + 3] << 24);
        uint32_t a = a0, b = b0, c = c0, d = d0;
        for (int i = 0; i < 64; i++) {
            uint32_t f;
            int g;
            if (i < 16) { f = (b & c) | (~b & d); g = i; }
            else if (i < 32) { f = (d & b) | (~d & c); g = (5 * i + 1) % 16; }
            else if (i < 48) { f = b ^ c ^ d; g = (3 * i + 5) % 16; }
            else { f = c ^ (b | ~d); g = (7 * i) % 16; }
            f += a + K[i] + m[g];
            a = d; d = c; c = b;
            b += (f << S[i]) | (f >> (32 - S[i]));
        }
        a0 += a; b0 += b; c0 += c; d0 += d;
    }
    std::string out;
    const uint32_t hs[4] = {a0, b0, c0, d0};
    for (uint32_t h : hs)
        for (int i = 0; i < 4; i++) {
            char b[3];
            std::snprintf(b, sizeof b, "%02x", (h >> (8 * i)) & 0xff);
            out += b;
        }
    return out;
}

// --- request shape ---
struct AsusRef {
    std::string host;
    int port = 0;
    std::string bind_addr;
};

bool parse_common(const char *data, int64_t len, AsusRef &r,
                  std::string &body) {
    if (len <= 0 || len > 8192) return false;
    body.assign(data, (size_t)len);
    if (!json_str(body, "host", r.host) || r.host.empty() ||
        r.host.size() > 253)
        return false;
    long port = 0;
    if (!json_int(body, "port", port) || port <= 0 || port > 65535)
        return false;
    r.port = (int)port;
    if (!json_str(body, "bind_addr", r.bind_addr) || r.bind_addr.size() > 64)
        return false;
    return true;
}

// --- bound HTTP/1.0 round trip with cookie capture and cut detection ---
enum class RoundRc { Ok, Failed, Cut };

struct Session {
    AsusRef ref;
    std::string cookie;  // "asus_token=..." once logged in
};

RoundRc http_round(Session &s, const std::string &req, int &status,
                   std::string &body) {
    addrinfo hints{};
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char port_s[16];
    std::snprintf(port_s, sizeof port_s, "%d", s.ref.port);
    addrinfo *ai = nullptr;
    if (getaddrinfo(s.ref.host.c_str(), port_s, &hints, &ai) != 0 || !ai)
        return RoundRc::Failed;
    int fd = -1;
    for (addrinfo *a = ai; a; a = a->ai_next) {
        fd = socket(a->ai_family, a->ai_socktype, a->ai_protocol);
        if (fd < 0) continue;
        timeval tv{};
        tv.tv_sec = kTimeoutSec;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
        // Bind to the router-facing address so control traffic never
        // leaves via another interface's default route (multihomed host).
        if (!s.ref.bind_addr.empty()) {
            sockaddr_in la{};
            la.sin_family = AF_INET;
            la.sin_port = 0;
            if (inet_pton(AF_INET, s.ref.bind_addr.c_str(), &la.sin_addr) != 1 ||
                bind(fd, (sockaddr *)&la, sizeof la) != 0) {
                close(fd);
                fd = -1;
                continue;
            }
        }
        if (connect(fd, a->ai_addr, a->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(ai);
    if (fd < 0) return RoundRc::Failed;
    size_t sent = 0;
    while (sent < req.size()) {
        ssize_t n = send(fd, req.data() + sent, req.size() - sent, 0);
        if (n <= 0) {
            close(fd);
            return RoundRc::Failed;
        }
        sent += (size_t)n;
    }
    std::string raw;
    char buf[8192];
    for (;;) {
        ssize_t n = recv(fd, buf, sizeof buf, 0);
        if (n < 0) {
            close(fd);
            // Connected and sent, then cut with nothing back: this
            // firmware's way of refusing / restarting (see header).
            return raw.empty() ? RoundRc::Cut : RoundRc::Failed;
        }
        if (n == 0) break;
        if (raw.size() + (size_t)n > (size_t)kMaxRaw) {
            close(fd);
            return RoundRc::Failed;
        }
        raw.append(buf, (size_t)n);
    }
    close(fd);
    if (raw.empty()) return RoundRc::Cut;
    if (raw.compare(0, 5, "HTTP/") != 0) return RoundRc::Failed;
    size_t sp = raw.find(' ', 5);
    if (sp == std::string::npos || sp + 1 >= raw.size())
        return RoundRc::Failed;
    status = std::atoi(raw.c_str() + sp + 1);
    if (status <= 0 || status > 599) return RoundRc::Failed;
    size_t hdr_end = raw.find("\r\n\r\n");
    if (hdr_end == std::string::npos) return RoundRc::Failed;
    // Capture the session token whenever the router (re)issues one.
    std::string hdrs = raw.substr(0, hdr_end);
    size_t sc = 0;
    while ((sc = hdrs.find("asus_token=", sc)) != std::string::npos) {
        size_t e = hdrs.find_first_of(";\r\n", sc);
        if (e == std::string::npos) e = hdrs.size();
        std::string tok = hdrs.substr(sc, e - sc);
        if (tok.size() > 11) {  // has a value, not a deletion stub
            s.cookie = tok;
            break;
        }
        sc = e;
    }
    body = raw.substr(hdr_end + 4);
    // This httpd wraps some replies in a shell page repeating the raw
    // response; unwrap to the last header/body split (live-observed).
    size_t wrap = body.rfind("\r\n\r\n");
    if (wrap != std::string::npos) body = body.substr(wrap + 4);
    return RoundRc::Ok;
}

std::string request_head(Session &s, const char *method,
                         const std::string &path, const std::string &referer,
                         const std::string *form) {
    std::string r = std::string(method) + " " + path + " HTTP/1.0\r\nHost: " +
                    s.ref.host + "\r\nUser-Agent: " + kUA + "\r\n";
    if (!referer.empty()) r += "Referer: " + referer + "\r\n";
    if (!s.cookie.empty()) r += "Cookie: " + s.cookie + "\r\n";
    if (form) {
        r += "Content-Type: application/x-www-form-urlencoded\r\n";
        r += "Content-Length: " + std::to_string(form->size()) + "\r\n";
    }
    r += "Connection: close\r\n\r\n";
    if (form) r += *form;
    return r;
}

std::string qis_referer(const AsusRef &r) {
    return "http://" + r.host + "/QIS_wizard.htm";
}
std::string index_referer(const AsusRef &r) {
    return "http://" + r.host + "/index.asp";
}

// --- ASUS primitives ---
enum class ReadRc { Ok, SessionRequired, Rejected, Failed };

const std::vector<std::string> &discover_keys() {
    static const std::vector<std::string> keys = [] {
        std::vector<std::string> k = {
            "productid", "x_Setting", "sw_mode", "wlc_psta", "wlc_dpsta",
            "smart_connect_x", "wan_unit", "wan_proto", "wan_dhcpenable_x",
            "wan_dnsenable_x", "http_username"};
        for (int i = 0; i < 4; i++) {
            std::string p = "wl" + std::to_string(i) + "_";
            k.push_back(p + "ssid");
            k.push_back(p + "auth_mode_x");
            k.push_back(p + "crypto");
            k.push_back(p + "mfp");
            k.push_back(p + "11ax");
        }
        return k;
    }();
    return keys;
}

ReadRc read_nvram(Session &s, std::string &body_out) {
    std::string path = "/appGet.cgi?hook=";
    const auto &keys = discover_keys();
    for (size_t i = 0; i < keys.size(); i++) {
        if (i) path += "%3B";
        path += "nvram_get(" + keys[i] + ")";
    }
    int status = 0;
    std::string req = request_head(s, "GET", path, qis_referer(s.ref), nullptr);
    RoundRc rc = http_round(s, req, status, body_out);
    if (rc != RoundRc::Ok) return ReadRc::Failed;
    if (body_out.find("Main_Login") != std::string::npos)
        return ReadRc::SessionRequired;
    if (status != 200 || body_out.find("AUTHFAIL") != std::string::npos)
        return ReadRc::Rejected;
    return ReadRc::Ok;
}

// Login by token capture: this firmware answers 200 either way, so the
// asus_token cookie is the only honest success signal.
enum class LoginRc { Ok, Refused, Failed };
LoginRc asus_login(Session &s, const std::string &user, const std::string &pw) {
    s.cookie.clear();
    std::vector<std::pair<std::string, std::string>> f = {
        {"login_authorization", b64(user + ":" + pw)},
        {"login_captcha", ""},
        {"captcha_text", ""}};
    std::string form = form_join(f);
    std::string req = request_head(
        s, "POST", "/login.cgi", "http://" + s.ref.host + "/Main_Login.asp",
        &form);
    int status = 0;
    std::string body;
    if (http_round(s, req, status, body) != RoundRc::Ok)
        return LoginRc::Failed;
    return s.cookie.empty() ? LoginRc::Refused : LoginRc::Ok;
}

// MaxLen_http_passwd, 0 when the unit will not say (caller proceeds
// uncapped, matching the wizard transcript).
long max_admin_len(Session &s) {
    std::string req = request_head(s, "GET", "/appGet.cgi?hook=get_ui_support()",
                                   index_referer(s.ref), nullptr);
    int status = 0;
    std::string body;
    if (http_round(s, req, status, body) != RoundRc::Ok || status != 200)
        return 0;
    std::string v;
    if (!json_str(body, "MaxLen_http_passwd", v)) return 0;
    long n = std::atol(v.c_str());
    return n > 0 && n <= 256 ? n : 0;
}

bool fetch_secret(const std::string &ref, std::string &out) {
    char buf[257];
    int64_t len = 0;
    ct_bytes r{reinterpret_cast<const uint8_t *>(ref.data()),
               (int64_t)ref.size()};
    ct_output o{reinterpret_cast<uint8_t *>(buf), 256};
    if (ct_vault_fetch(r, o, &len) != CT_OK || len <= 0 || len > 256)
        return false;
    out.assign(buf, (size_t)len);
    return true;
}

void band_lists(const std::string &nv, std::vector<int> &bands,
                std::vector<std::string> &ssids, std::vector<int> &secured) {
    for (int i = 0; i < 4; i++) {
        std::string p = "wl" + std::to_string(i) + "_";
        std::string ssid, auth;
        if (json_str(nv, (p + "ssid").c_str(), ssid) && !ssid.empty()) {
            bands.push_back(i);
            ssids.push_back(ssid);
            if (json_str(nv, (p + "auth_mode_x").c_str(), auth) &&
                auth != "open")
                secured.push_back(i);
        }
    }
}

std::string ints_json(const std::vector<int> &v) {
    std::string out = "[";
    for (size_t i = 0; i < v.size(); i++) {
        if (i) out += ",";
        out += std::to_string(v[i]);
    }
    return out + "]";
}
std::string strs_json(const std::vector<std::string> &v) {
    std::string out = "[";
    for (size_t i = 0; i < v.size(); i++) {
        if (i) out += ",";
        out += "\"";
        json_escape(v[i], out);
        out += "\"";
    }
    return out + "]";
}

bool str_field(const std::string &body, const char *key, size_t max,
               bool non_empty, std::string &out) {
    if (!json_str(body, key, out)) return false;
    if (out.size() > max) return false;
    if (non_empty && out.empty()) return false;
    return true;
}

}  // namespace

extern "C" {

int32_t ct_asus_discover(ct_bytes req, ct_output out, int64_t *out_len) {
    if (!out_len || !req.data) return CT_INVALID_ARGUMENT;
    std::string body;
    Session s;
    if (!parse_common((const char *)req.data, req.len, s.ref, body))
        return CT_INVALID_ARGUMENT;
    std::string fuser, fpass;
    if (!str_field(body, "factory_user", 32, false, fuser) ||
        !str_field(body, "factory_pass", 64, false, fpass))
        return CT_INVALID_ARGUMENT;

    bool session_first = false;
    std::string nv;
    ReadRc rr = read_nvram(s, nv);
    if (rr == ReadRc::SessionRequired) {
        if (fuser.empty()) return CT_REJECTED;
        if (asus_login(s, fuser, fpass) != LoginRc::Ok) return CT_REJECTED;
        session_first = true;
        rr = read_nvram(s, nv);
    }
    if (rr == ReadRc::Rejected) return CT_REJECTED;
    if (rr != ReadRc::Ok) return CT_FAILED;

    std::string productid, x_setting;
    json_str(nv, "productid", productid);
    json_str(nv, "x_Setting", x_setting);
    std::vector<int> bands, secured;
    std::vector<std::string> ssids;
    band_lists(nv, bands, ssids, secured);
    long cap = max_admin_len(s);

    std::string receipt = "{\"productid\":\"";
    json_escape(productid, receipt);
    receipt += "\",\"x_setting\":\"";
    json_escape(x_setting, receipt);
    receipt += "\",\"session_first\":";
    receipt += session_first ? "true" : "false";
    receipt += ",\"max_admin_len\":" + std::to_string(cap);
    receipt += ",\"bands\":" + ints_json(bands);
    receipt += ",\"ssids\":" + strs_json(ssids);
    receipt += ",\"secured\":" + ints_json(secured) + "}";
    int32_t rc = CT_OK;
    put_receipt(out, out_len, receipt, rc);
    return rc;
}

int32_t ct_asus_rotate(ct_bytes req, ct_output out, int64_t *out_len) {
    if (!out_len || !req.data) return CT_INVALID_ARGUMENT;
    std::string body;
    Session s;
    if (!parse_common((const char *)req.data, req.len, s.ref, body))
        return CT_INVALID_ARGUMENT;
    std::string admin_user, admin_ref, fuser, fpass;
    bool session_first = false;
    if (!str_field(body, "admin_user", 32, true, admin_user) ||
        !str_field(body, "admin_ref", 128, true, admin_ref) ||
        !str_field(body, "factory_user", 32, false, fuser) ||
        !str_field(body, "factory_pass", 64, false, fpass) ||
        !json_bool(body, "session_first", session_first))
        return CT_INVALID_ARGUMENT;
    std::string admin_pw;
    if (!fetch_secret(admin_ref, admin_pw)) return CT_INVALID_ARGUMENT;

    auto chpass = [&](bool with_current) -> RoundRc {
        std::vector<std::pair<std::string, std::string>> f = {
            {"restart_httpd", "0"},
            {"new_username", b64(admin_user)},
            {"new_passwd", b64(admin_pw)},
            {"defpass_enable", "0"}};
        if (with_current) {
            f.push_back({"cur_username", md5_hex(fuser)});
            f.push_back({"cur_passwd", md5_hex(fpass)});
        }
        std::string form = form_join(f);
        std::string r =
            request_head(s, "POST", "/chpass.cgi", qis_referer(s.ref), &form);
        int status = 0;
        std::string b;
        RoundRc rc = http_round(s, r, status, b);
        if (rc == RoundRc::Ok && status != 200) return RoundRc::Failed;
        return rc;
    };
    // The proof of rotation is a fresh login; httpd may need a beat to
    // adopt the credential, so the proof retries on a bounded clock.
    auto prove_login = [&]() -> bool {
        for (int i = 0; i < 3; i++) {
            if (i) sleep(2);
            if (asus_login(s, admin_user, admin_pw) == LoginRc::Ok)
                return true;
        }
        return false;
    };

    std::string branch;
    if (!session_first) {
        long cap = max_admin_len(s);
        if (cap > 0 && (long)admin_pw.size() > cap)
            return CT_INVALID_ARGUMENT;
        if (chpass(false) == RoundRc::Ok) {
            if (!prove_login()) return CT_REJECTED;
            branch = "open";
        }
        // Cut/refused open move: fall through to the session branch,
        // exactly as the live transcript did.
    }
    if (branch.empty()) {
        if (fuser.empty()) return CT_REJECTED;
        if (asus_login(s, fuser, fpass) != LoginRc::Ok) return CT_REJECTED;
        long cap = max_admin_len(s);
        if (cap > 0 && (long)admin_pw.size() > cap)
            return CT_INVALID_ARGUMENT;
        (void)chpass(true);  // reply may cut on the httpd restart
        sleep(2);
        if (!prove_login()) return CT_REJECTED;
        branch = "session";
    }

    std::string receipt = "{\"rotated\":true,\"branch\":\"" + branch +
                          "\",\"login_verified\":true}";
    int32_t rc = CT_OK;
    put_receipt(out, out_len, receipt, rc);
    return rc;
}

int32_t ct_asus_apply(ct_bytes req, ct_output out, int64_t *out_len) {
    if (!out_len || !req.data) return CT_INVALID_ARGUMENT;
    std::string body;
    Session s;
    if (!parse_common((const char *)req.data, req.len, s.ref, body))
        return CT_INVALID_ARGUMENT;
    std::string admin_user, admin_ref, psk_ref, stem;
    if (!str_field(body, "admin_user", 32, true, admin_user) ||
        !str_field(body, "admin_ref", 128, true, admin_ref) ||
        !str_field(body, "psk_ref", 128, true, psk_ref) ||
        !str_field(body, "ssid_stem", 27, true, stem))
        return CT_INVALID_ARGUMENT;
    std::string admin_pw, psk;
    if (!fetch_secret(admin_ref, admin_pw) || !fetch_secret(psk_ref, psk))
        return CT_INVALID_ARGUMENT;
    if (psk.size() < 8 || psk.size() > 63) return CT_INVALID_ARGUMENT;

    if (asus_login(s, admin_user, admin_pw) != LoginRc::Ok)
        return CT_REJECTED;
    std::string nv;
    if (read_nvram(s, nv) != ReadRc::Ok) return CT_FAILED;
    std::vector<int> bands, secured;
    std::vector<std::string> ssids;
    band_lists(nv, bands, ssids, secured);
    if (bands.empty()) return CT_FAILED;

    auto echo = [&](const char *key) -> std::string {
        std::string v;
        json_str(nv, key, v);
        return v;
    };
    // The wizard's final form: setup flags, echo-current for everything
    // untouched, userObj riding along, per-band wireless block.
    std::vector<std::pair<std::string, std::string>> f = {
        {"action_mode", "apply"},
        {"x_Setting", "1"}, {"w_Setting", "1"}, {"qis_Setting", "1"},
        {"cfg_master", "1"},
        {"sw_mode", echo("sw_mode")}, {"wlc_psta", echo("wlc_psta")},
        {"wlc_dpsta", echo("wlc_dpsta")},
        {"smart_connect_x", echo("smart_connect_x")},
        {"wan_unit", echo("wan_unit")}, {"wan_proto", echo("wan_proto")},
        {"wan_dhcpenable_x", echo("wan_dhcpenable_x")},
        {"wan_dnsenable_x", echo("wan_dnsenable_x")},
        {"http_username", admin_user}, {"http_passwd", admin_pw}};
    std::vector<std::string> new_ssids;
    for (int i : bands) {
        std::string p = "wl" + std::to_string(i) + "_";
        std::string ssid = stem + kBandSuffix[i];
        new_ssids.push_back(ssid);
        f.push_back({p + "ssid", ssid});
        f.push_back({p + "wpa_psk", psk});
        f.push_back({p + "auth_mode_x", "psk2"});
        f.push_back({p + "crypto", "aes"});
        f.push_back({p + "mfp", echo((p + "mfp").c_str())});
        f.push_back({p + "11ax", echo((p + "11ax").c_str())});
    }
    f.push_back({"rc_service", "restart_wireless;restart_cfgsync"});

    std::string form = form_join(f);
    std::string r =
        request_head(s, "POST", "/applyapp.cgi", qis_referer(s.ref), &form);
    int status = 0;
    std::string resp;
    RoundRc rc = http_round(s, r, status, resp);
    bool reply_cut = false;
    if (rc == RoundRc::Cut) {
        reply_cut = true;  // radio restart took the reply with it
    } else if (rc != RoundRc::Ok) {
        return CT_FAILED;
    } else if (resp.find("Main_Login") != std::string::npos) {
        return CT_REJECTED;
    } else if (status != 200) {
        return CT_FAILED;
    }

    std::string receipt = "{\"submitted\":true,\"reply_cut\":";
    receipt += reply_cut ? "true" : "false";
    receipt += ",\"new_ssids\":" + strs_json(new_ssids) + "}";
    int32_t orc = CT_OK;
    put_receipt(out, out_len, receipt, orc);
    return orc;
}

int32_t ct_asus_verify(ct_bytes req, ct_output out, int64_t *out_len) {
    if (!out_len || !req.data) return CT_INVALID_ARGUMENT;
    std::string body;
    Session s;
    if (!parse_common((const char *)req.data, req.len, s.ref, body))
        return CT_INVALID_ARGUMENT;
    std::string admin_user, admin_ref;
    if (!str_field(body, "admin_user", 32, true, admin_user) ||
        !str_field(body, "admin_ref", 128, true, admin_ref))
        return CT_INVALID_ARGUMENT;
    std::string admin_pw;
    if (!fetch_secret(admin_ref, admin_pw)) return CT_INVALID_ARGUMENT;

    auto emit = [&](bool authed, const std::string &x_setting,
                    const std::string &wl0) -> int32_t {
        std::string receipt = "{\"authenticated\":";
        receipt += authed ? "true" : "false";
        receipt += ",\"x_setting\":\"";
        json_escape(x_setting, receipt);
        receipt += "\",\"wl0_ssid\":\"";
        json_escape(wl0, receipt);
        receipt += "\"}";
        int32_t rc = CT_OK;
        put_receipt(out, out_len, receipt, rc);
        return rc;
    };

    LoginRc lr = asus_login(s, admin_user, admin_pw);
    if (lr == LoginRc::Failed) return CT_FAILED;
    if (lr == LoginRc::Refused) return emit(false, "", "");
    std::string path =
        "/appGet.cgi?hook=nvram_get(x_Setting)%3Bnvram_get(wl0_ssid)"
        "%3Bget_clientlist()";
    std::string r = request_head(s, "GET", path, index_referer(s.ref), nullptr);
    int status = 0;
    std::string resp;
    if (http_round(s, r, status, resp) != RoundRc::Ok) return CT_FAILED;
    if (status != 200 || resp.find("AUTHFAIL") != std::string::npos ||
        resp.find("Main_Login") != std::string::npos)
        return emit(false, "", "");
    std::string x_setting, wl0;
    json_str(resp, "x_Setting", x_setting);
    json_str(resp, "wl0_ssid", wl0);
    return emit(true, x_setting, wl0);
}

}  // extern "C"
