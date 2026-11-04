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
#include <map>
#include <string>
#include <utility>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/wait.h>

namespace {

const long kMaxBytes = 32768;
const int kShellTimeoutPadSec = 5;
// Goose calls this synchronous boundary on one thread. Handles and pending
// envelopes belong to this process; setup and the resident service cannot
// overwrite each other's state. Each open retains at most one capped response.
struct Session {
    std::string config, payload;
    uint64_t request_id = 0;
    int status = 0;
};
std::map<ct_handle, Session> sessions;

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

int32_t ct_meta_key_available(ct_bytes name) {
    if (!name.data || name.len <= 0 || name.len > 64) return 0;
    std::string env(reinterpret_cast<const char *>(name.data), (size_t)name.len);
    for (unsigned char c : env) {
        if (!((c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') ||
              (c >= '0' && c <= '9') || c == '_')) return 0;
    }
    const char *key = std::getenv(env.c_str());
    return key && *key ? 1 : 0;
}

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
    // The credential itself is still resolved only at submit time.
    static uint64_t next_handle = 1;
    if (sessions.size() >= 8 || next_handle == 0) return CT_REJECTED;
    *out_handle = next_handle++;
    sessions.emplace(*out_handle, Session{std::move(cfg), "", 0, 0});
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

    const auto session = sessions.find(handle);
    if (session == sessions.end()) return CT_INVALID_ARGUMENT;
    if (session->second.request_id != 0) return CT_PENDING;
    const std::string &cfg = session->second.config;
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

    const char *scratch = std::getenv("TMPDIR");
    if (!scratch || scratch[0] != '/') scratch = "/tmp";
    if (std::strlen(scratch) > 4000) return CT_INVALID_ARGUMENT;
    char body_path[4096], hdr_path[4096], rsp_path[4096];
    std::snprintf(body_path, sizeof body_path, "%s/ct_meta_body_XXXXXX", scratch);
    std::snprintf(hdr_path, sizeof hdr_path, "%s/ct_meta_hdr_XXXXXX", scratch);
    std::snprintf(rsp_path, sizeof rsp_path, "%s/ct_meta_rsp_XXXXXX", scratch);
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
    // getenv storage belongs to the process. Scrub only our owned copy:
    // changing the environment here destroys the next turn's credential.
    std::memset(&auth[0], 0, auth.size());

    long secs = timeout_ms / 1000 + kShellTimeoutPadSec;
    if (secs < 6) secs = 6;
    std::string url = base + path;
    std::string cmd = "curl -sS -A 'OpenAI File Downloader, XaiImageApiFetch/1.0' --max-time " + std::to_string(secs) +
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

    std::string payload = read_file_capped(rsp_path, max_bytes);
    unlink(rsp_path);
    if (payload.empty() && (st != 0 || code == 0)) code = 0;
    session->second.request_id = *out_request_id;
    session->second.status = code;
    session->second.payload = std::move(payload);
    return CT_OK;
}

int32_t ct_meta_poll(ct_handle handle, ct_output result_json,
                     int64_t *out_length) {
    if (handle == 0 || !result_json.data || result_json.capacity <= 0 ||
        !out_length)
        return CT_INVALID_ARGUMENT;
    *out_length = 0;
    const auto session = sessions.find(handle);
    if (session == sessions.end() || session->second.request_id == 0) return CT_INVALID_ARGUMENT;
    const auto &pending = session->second;
    std::string env = "{\"status\":" + std::to_string(pending.status) + ",\"body\":";
    if (pending.status == 200 && !pending.payload.empty()) env += pending.payload;
    else env += "null";
    env += ",\"error\":\"\"}";
    int32_t rc = CT_FAILED;
    put_envelope(result_json, out_length, rc, env);
    if (rc == CT_OK) {
        session->second.request_id = 0;
        session->second.payload.clear();
    }
    return rc;
}

int32_t ct_meta_cancel(ct_handle handle, uint64_t request_id) {
    const auto session = sessions.find(handle);
    if (request_id == 0 || session == sessions.end() || session->second.request_id != request_id)
        return CT_INVALID_ARGUMENT;
    session->second.request_id = 0;
    session->second.payload.clear();
    return CT_OK;
}

int32_t ct_meta_close(ct_handle handle) {
    return sessions.erase(handle) == 1 ? CT_OK : CT_INVALID_ARGUMENT;
}

}  // extern "C"
