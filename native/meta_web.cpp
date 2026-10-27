// Continuum Meta HTTPS transport (item M01/C03).
//
// One bounded POST to the provider's /responses endpoint via the system
// curl binary: no new TLS dependency, no persistent connections, no
// threads. Goose owns request identity, budgets and response meaning;
// this file owns bytes on the wire.
//
// Credential handling: the API key is read from the environment variable
// NAMED in the config JSON ("api_key_env", e.g. MODEL_API_KEY) at submit
// time. The key is passed to curl via a protected temporary header file
// (0600, unlinked immediately after the child exits) so it never appears
// in a process command line. The key is never written to stdout, logs,
// receipts or error strings; failures name the failure class, not the
// credential. Response bodies larger than max_bytes are rejected unread:
// the child writes to a capped file and curl is told --max-filesize, so
// an oversize body fails closed instead of truncating into a half-parse.
//
// Status mapping: curl exit / HTTP status -> envelope {"status", "body",
// "error"}. Status 0 with a curl timeout exit is transport timeout;
// 4xx/5xx map through with no body; unreachable/garbage fails closed.
#include "continuum_native.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>

namespace {

const long kMaxBytes = 32768;
const int kShellTimeoutPadSec = 5;

bool json_str(const std::string &body, const char *key, std::string &out,
              size_t cap) {
    std::string q = std::string("\"") + key + "\":";
    size_t p = body.find(q);
    if (p == std::string::npos) return false;
    p += q.size();
    while (p < body.size() &&
           (body[p] == ' ' || body[p] == '\t' || body[p] == '\n' ||
            body[p] == '\r'))
        p++;
    if (p >= body.size() || body[p] != '"') return false;
    p++;
    std::string v;
    while (p < body.size() && body[p] != '"') {
        if (body[p] == '\\' && p + 1 < body.size()) {
            v += body[p + 1];
            p += 2;
        } else {
            v += body[p];
            p++;
        }
    }
    if (p >= body.size() || v.size() > cap) return false;
    out = v;
    return true;
}

bool json_long(const std::string &body, const char *key, long &out) {
    std::string q = std::string("\"") + key + "\":";
    size_t p = body.find(q);
    if (p == std::string::npos) return false;
    p += q.size();
    while (p < body.size() &&
           (body[p] == ' ' || body[p] == '\t' || body[p] == '\n' ||
            body[p] == '\r'))
        p++;
    if (p >= body.size() ||
        !(body[p] == '-' || (body[p] >= '0' && body[p] <= '9')))
        return false;
    size_t e = p + (body[p] == '-' ? 1 : 0);
    while (e < body.size() && body[e] >= '0' && body[e] <= '9') e++;
    if (e == p || e - p > 12) return false;
    out = std::stol(body.substr(p, e - p));
    return true;
}

// Escape a string for single-quoted shell embedding: close quote, add an
// escaped quote, reopen. The payload stays data, never shell syntax.
std::string sh_quote(const std::string &s) {
    std::string o = "'";
    for (char c : s) {
        if (c == '\'')
            o += "'\\''";
        else
            o += c;
    }
    return o + "'";
}

void put_envelope(ct_output out, int64_t *out_len, int32_t &rc,
                  const std::string &env) {
    if ((int64_t)env.size() > out.capacity) {
        rc = CT_BUFFER_TOO_SMALL;
        return;
    }
    std::memcpy(out.data, env.data(), env.size());
    *out_len = (int64_t)env.size();
    rc = CT_OK;
}

std::string read_file_capped(const char *path, long cap) {
    FILE *f = std::fopen(path, "rb");
    if (!f) return "";
    std::string o;
    char buf[4096];
    for (;;) {
        size_t n = std::fread(buf, 1, sizeof buf, f);
        if (n == 0) break;
        if ((long)(o.size() + n) > cap) {
            std::fclose(f);
            return "";
        }
        o.append(buf, n);
    }
    std::fclose(f);
    return o;
}

}  // namespace

extern "C" {

int32_t ct_meta_open(ct_bytes config_json, ct_handle *out_handle) {
    if (!out_handle || !config_json.data || config_json.len <= 0 ||
        config_json.len > 4096)
        return CT_INVALID_ARGUMENT;
    std::string cfg((const char *)config_json.data,
                    (size_t)config_json.len);
    std::string env_name, base;
    long timeout_ms = 0, max_bytes = 0;
    if (!json_str(cfg, "api_key_env", env_name, 64)) return CT_INVALID_ARGUMENT;
    if (!json_str(cfg, "base_url", base, 256)) return CT_INVALID_ARGUMENT;
    if (base.compare(0, 8, "https://") != 0) return CT_INVALID_ARGUMENT;
    if (!json_long(cfg, "timeout_ms", timeout_ms) || timeout_ms < 1000 ||
        timeout_ms > 120000)
        return CT_INVALID_ARGUMENT;
    if (!json_long(cfg, "max_bytes", max_bytes) || max_bytes <= 0 ||
        max_bytes > kMaxBytes)
        return CT_INVALID_ARGUMENT;
    // No secret is read here: submit reads the live environment so a
    // rotated key takes effect on the next request, not the next open.
    // The open config (credential source NAME, base URL, budgets - never
    // a secret) is staged for submit under this handle.
    static uint64_t next_handle = 1;
    char cfg_path[64];
    std::snprintf(cfg_path, sizeof cfg_path, "/tmp/ct_meta_cfg_%llu",
                  (unsigned long long)(next_handle));
    FILE *cf = std::fopen(cfg_path, "wb");
    if (!cf) return CT_FAILED;
    fchmod(fileno(cf), 0600);
    std::fwrite(cfg.data(), 1, cfg.size(), cf);
    std::fclose(cf);
    *out_handle = next_handle++;
    if (*out_handle == 0) *out_handle = next_handle++;
    return CT_OK;
}

int32_t ct_meta_submit(ct_handle handle, ct_bytes request_json,
                       uint64_t *out_request_id) {
    if (handle == 0 || !out_request_id || !request_json.data ||
        request_json.len <= 0 || request_json.len > kMaxBytes)
        return CT_INVALID_ARGUMENT;
    std::string req((const char *)request_json.data, (size_t)request_json.len);
    std::string path, body;
    if (!json_str(req, "path", path, 64)) return CT_INVALID_ARGUMENT;
    if (path != "/responses") return CT_INVALID_ARGUMENT;
    // The body is the provider JSON; locate its raw span by brace balance
    // from the first '{' after "body": so no re-serialization can smuggle
    // in a second member.
    size_t bk = req.find("\"body\":");
    if (bk == std::string::npos) return CT_INVALID_ARGUMENT;
    size_t bs = req.find('{', bk + 7);
    if (bs == std::string::npos) return CT_INVALID_ARGUMENT;
    int nest = 0;
    bool in_s = false, esc = false;
    size_t be = std::string::npos;
    for (size_t p = bs; p < req.size(); p++) {
        char c = req[p];
        if (in_s) {
            if (esc)
                esc = false;
            else if (c == '\\')
                esc = true;
            else if (c == '"')
                in_s = false;
        } else if (c == '"') {
            in_s = true;
        } else if (c == '{') {
            nest++;
        } else if (c == '}') {
            if (--nest == 0) {
                be = p;
                break;
            }
        }
    }
    if (be == std::string::npos) return CT_INVALID_ARGUMENT;
    std::string body_json = req.substr(bs, be - bs + 1);
    if ((long)body_json.size() > kMaxBytes) return CT_INVALID_ARGUMENT;

    // Open validated these shapes and staged the non-secret config under
    // this handle; submit re-reads it (a stale handle fails closed here).
    char cfg_path[64];
    std::snprintf(cfg_path, sizeof cfg_path, "/tmp/ct_meta_cfg_%llu",
                  (unsigned long long)handle);
    std::string cfg = read_file_capped(cfg_path, 4096);
    std::string key_env, base;
    long timeout_ms = 0, max_bytes = kMaxBytes;
    if (cfg.empty() || !json_str(cfg, "api_key_env", key_env, 64) ||
        !json_str(cfg, "base_url", base, 256) ||
        !json_long(cfg, "timeout_ms", timeout_ms) ||
        !json_long(cfg, "max_bytes", max_bytes)) {
        return CT_INVALID_ARGUMENT;
    }
    const char *key = std::getenv(key_env.c_str());
    if (!key || !*key) return CT_INVALID_ARGUMENT;

    char body_path[] = "/tmp/ct_meta_body_XXXXXX";
    char hdr_path[] = "/tmp/ct_meta_hdr_XXXXXX";
    char rsp_path[] = "/tmp/ct_meta_rsp_XXXXXX";
    int bfd = mkstemp(body_path);
    int hfd = mkstemp(hdr_path);
    int rfd = mkstemp(rsp_path);
    if (bfd < 0 || hfd < 0 || rfd < 0) {
        if (bfd >= 0) {
            close(bfd);
            unlink(body_path);
        }
        if (hfd >= 0) {
            close(hfd);
            unlink(hdr_path);
        }
        if (rfd >= 0) {
            close(rfd);
            unlink(rsp_path);
        }
        return CT_FAILED;
    }
    close(rfd);  // curl opens the response file by path, 0600 from mkstemp.
    FILE *bf = fdopen(bfd, "wb");
    FILE *hf = fdopen(hfd, "wb");
    if (!bf || !hf) {
        if (bf) std::fclose(bf);
        if (hf) std::fclose(hf);
        unlink(body_path);
        unlink(hdr_path);
        unlink(rsp_path);
        return CT_FAILED;
    }
    std::fwrite(body_json.data(), 1, body_json.size(), bf);
    std::fclose(bf);
    std::string auth = std::string("Authorization: Bearer ") + key + "\n";
    std::fwrite(auth.data(), 1, auth.size(), hf);
    std::fclose(hf);
    // Scrub the key from memory as soon as the header file holds it.
    volatile char *kscrub = (volatile char *)key;
    for (size_t i = 0; i < std::strlen(key); i++) kscrub[i] = 0;
    std::memset(&auth[0], 0, auth.size());

    long secs = timeout_ms / 1000 + kShellTimeoutPadSec;
    if (secs < 6) secs = 6;
    std::string url = base + path;
    std::string cmd = "curl -sS --max-time " + std::to_string(secs) +
                      " --max-filesize " + std::to_string(max_bytes) +
                      " -o " + sh_quote(rsp_path) + " -X POST " +
                      sh_quote(url) + " -H 'Content-Type: application/json'" +
                      " -H @" + sh_quote(hdr_path) +
                      " --data @" + sh_quote(body_path) +
                      " -w '%{http_code}'";
    FILE *pp = popen(cmd.c_str(), "r");
    if (!pp) {
        unlink(body_path);
        unlink(hdr_path);
        unlink(rsp_path);
        return CT_FAILED;
    }
    int st = 1;
    int code = 0;
    {
        char code_buf[16] = {0};
        size_t cn = std::fread(code_buf, 1, sizeof(code_buf) - 1, pp);
        (void)cn;
        st = pclose(pp);
        // curl prints 000 when no HTTP exchange happened (DNS, timeout,
        // TLS failure): that is status 0, transport failure, never data.
        code = std::atoi(code_buf);
    }
    unlink(body_path);
    unlink(hdr_path);
    static uint64_t next_req = 1;
    *out_request_id = next_req++;
    if (*out_request_id == 0) *out_request_id = next_req++;

    // Stage the response body keyed by request id for poll, plus the
    // handle->request map poll uses to find it. A curl failure with no
    // body stages status 0: transport failure, never data.
    char stage[64];
    std::snprintf(stage, sizeof stage, "/tmp/ct_meta_resp_%llu",
                  (unsigned long long)*out_request_id);
    {
        std::string payload = read_file_capped(rsp_path, max_bytes);
        unlink(rsp_path);
        if (payload.empty() && (st != 0 || code == 0)) {
            code = 0;
        }
        FILE *sf = std::fopen(stage, "wb");
        if (!sf) return CT_FAILED;
        fchmod(fileno(sf), 0600);
        std::fwrite(payload.data(), 1, payload.size(), sf);
        std::fclose(sf);
        char stg2[96];
        std::snprintf(stg2, sizeof stg2, "%s.status", stage);
        FILE *cf = std::fopen(stg2, "wb");
        if (cf) {
            fchmod(fileno(cf), 0600);
            std::fprintf(cf, "%d", code);
            std::fclose(cf);
        }
        char map_path[64];
        std::snprintf(map_path, sizeof map_path, "/tmp/ct_meta_last_%llu",
                      (unsigned long long)handle);
        FILE *mf = std::fopen(map_path, "wb");
        if (mf) {
            fchmod(fileno(mf), 0600);
            std::fprintf(mf, "%llu", (unsigned long long)*out_request_id);
            std::fclose(mf);
        }
    }
    return CT_OK;
}

int32_t ct_meta_poll(ct_handle handle, ct_output result_json,
                     int64_t *out_length) {
    if (handle == 0 || !result_json.data || result_json.capacity <= 0 ||
        !out_length)
        return CT_INVALID_ARGUMENT;
    // Poll drains the staged response for this handle's latest request.
    // The Goose side submits exactly one request per handle, so the map
    // file stamped by submit is the matching one; anything else is a bug,
    // not data.
    int32_t rc = CT_FAILED;
    char map_path[64];
    std::snprintf(map_path, sizeof map_path, "/tmp/ct_meta_last_%llu",
                  (unsigned long long)handle);
    std::string last = read_file_capped(map_path, 32);
    if (last.empty()) return CT_INVALID_ARGUMENT;
    unsigned long long req = std::strtoull(last.c_str(), nullptr, 10);
    if (req == 0) return CT_INVALID_ARGUMENT;
    char stage[64], stg2[96];
    std::snprintf(stage, sizeof stage, "/tmp/ct_meta_resp_%llu", req);
    std::snprintf(stg2, sizeof stg2, "%s.status", stage);
    std::string status_s = read_file_capped(stg2, 16);
    std::string payload = read_file_capped(stage, kMaxBytes + 1);
    unlink(stage);
    unlink(stg2);
    unlink(map_path);
    if (!status_s.empty() && payload.size() > (size_t)kMaxBytes) {
        // Paranoia: cap check already enforced at download.
        return CT_BUFFER_TOO_SMALL;
    }
    long code = status_s.empty() ? 0 : std::atol(status_s.c_str());
    std::string env = "{\"status\":" + std::to_string(code) + ",\"body\":";
    if (code == 200 && !payload.empty()) {
        env += payload;
    } else {
        env += "null";
    }
    env += ",\"error\":\"\"}";
    put_envelope(result_json, out_length, rc, env);
    return rc;
}

int32_t ct_meta_cancel(ct_handle handle, uint64_t request_id) {
    if (handle == 0 || request_id == 0) return CT_INVALID_ARGUMENT;
    char stage[64], stg2[96], map_path[64];
    std::snprintf(stage, sizeof stage, "/tmp/ct_meta_resp_%llu",
                  (unsigned long long)request_id);
    std::snprintf(stg2, sizeof stg2, "%s.status", stage);
    std::snprintf(map_path, sizeof map_path, "/tmp/ct_meta_last_%llu",
                  (unsigned long long)handle);
    unlink(stage);
    unlink(stg2);
    unlink(map_path);
    return CT_OK;
}

int32_t ct_meta_close(ct_handle handle) {
    if (handle == 0) return CT_INVALID_ARGUMENT;
    char cfg_path[64], map_path[64];
    std::snprintf(cfg_path, sizeof cfg_path, "/tmp/ct_meta_cfg_%llu",
                  (unsigned long long)handle);
    std::snprintf(map_path, sizeof map_path, "/tmp/ct_meta_last_%llu",
                  (unsigned long long)handle);
    unlink(cfg_path);
    unlink(map_path);
    return CT_OK;
}

}  // extern "C"
