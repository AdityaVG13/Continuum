// Authored Meta transport, linked only into the setup acceptance executable.
// Exercise the real request/parse/dispatch/continuation path without HTTPS.
#include "../native/continuum_native.h"
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

namespace {
int turn = 0;
std::string pending;
std::string quote(const std::string &s) {
    std::string out = "\"";
    for (char c : s) { if (c == '"' || c == '\\') out += '\\'; out += c; }
    return out + '"';
}
int fail(const char *why) { std::fprintf(stderr, "FIXTURE_CONTRACT_FAILED %s\n", why); return CT_REJECTED; }
std::string call(const char *name, const char *arguments) {
    return std::string("{\"type\":\"function_call\",\"name\":") + quote(name) +
        ",\"call_id\":\"fixture-call-" + std::to_string(turn) + "\",\"arguments\":" + quote(arguments) + '}';
}
}
extern "C" {
int32_t ct_meta_key_available(ct_bytes) { return std::getenv("MODEL_API_KEY") ? 1 : 0; }
int32_t ct_meta_open(ct_bytes, ct_handle *out) { *out = 1; return CT_OK; }
int32_t ct_meta_submit(ct_handle, ct_bytes request, uint64_t *out) {
    std::string body(reinterpret_cast<const char *>(request.data), static_cast<size_t>(request.len));
    if (body.find("synthetic-private") != std::string::npos) return fail("key leaked into provider request");
    const char *expected = std::getenv("CONTINUUM_FIXTURE_MODEL");
    if (expected && body.find("\"model\":" + quote(expected)) == std::string::npos)
        return fail("worker model differs from the TUI settings");
    std::string output;
    if (body.find("device_agent") != std::string::npos) {
        const char *scenario = std::getenv("CONTINUUM_AGENT_FIXTURE");
        if (!scenario) return fail("unexpected device-agent request");
        if (std::string(scenario) == "ui") {
            if (body.find("Investigate without reboots") == std::string::npos)
                return fail("TUI did not deliver the actual owner message");
            output = "{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Owner dialogue connected; no authority added.\"}]}";
        } else if (std::string(scenario) == "chat") {
            if (body.find("Keep FTP") == std::string::npos || body.find("Owner uses FTP") == std::string::npos ||
                body.find("Samba disabled") == std::string::npos)
                return fail("dialogue omitted owner instructions or durable device context");
            output = "{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"FTP retained; no router reboot.\"}]}";
        } else if (std::string(scenario) == "program") {
            const char *operation = std::getenv("CONTINUUM_PROGRAM_OPERATION");
            const char *payload = std::getenv("CONTINUUM_PROGRAM_PAYLOAD");
            if (!operation || !payload) return fail("authored program arguments missing");
            if (turn == 0) {
                const char *target = std::getenv("CONTINUUM_PROGRAM_TARGET");
                const auto arguments = "{\"candidate_id\":" + quote(target ? target : "lo0:127.0.0.1") + ",\"operation\":" + quote(operation) +
                    ",\"payload\":" + quote(payload) + "}";
                output = call("manage_device", arguments.c_str());
            } else if (turn == 1) {
                const char *receipt = std::getenv("CONTINUUM_PROGRAM_EXPECT");
                if (!receipt || body.find(receipt) == std::string::npos)
                    return fail("program tool did not return the expected real receipt");
                output = "{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Program operation acknowledged.\"}]}";
            } else return fail("unexpected program continuation");
        } else {
            const auto manage = [&](const char *operation, const std::string &payload) {
                const auto arguments = "{\"candidate_id\":\"lo0:127.0.0.1\",\"operation\":" + quote(operation) +
                    ",\"payload\":" + quote(payload) + "}";
                return call("manage_device", arguments.c_str());
            };
            if (turn == 0) output = manage("read_skill", "commissioning");
            else if (turn == 1) output = manage("apply", "{\"enable_samba\":true,\"enable_ftp\":false,\"dms_enable\":false,\"daapd_enable\":false,\"enable_webdav\":false}");
            else if (turn == 2) {
                if (body.find("baseline_applied") == std::string::npos)
                    return fail("model did not receive the actual apply receipt");
                output = manage("remember", "Owner uses FTP; keep it enabled.");
            } else if (turn == 3) output = manage("reboot", "");
            else if (turn == 4) {
                if (body.find("owner_reboot_approval_required") == std::string::npos)
                    return fail("model reboot was not refused at the permission boundary");
                output = "{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Samba disabled; FTP retained; router reboot awaits your approval.\"}]}";
            } else return fail("unexpected device-agent continuation");
        }
        ++turn;
        pending = "{\"status\":200,\"body\":{\"id\":\"fixture-device\",\"model\":\"fixture-meta\",\"output\":[" + output + "]}}";
        *out = static_cast<uint64_t>(turn);
        return CT_OK;
    }
    if (body.find("service_incident") != std::string::npos) {
        if (std::getenv("CONTINUUM_DEVICE_FIXTURE")) {
            if (body.find("lo0:127.0.0.1") == std::string::npos || body.find("RT-TEST") == std::string::npos ||
                body.find("authored_host_fixture") == std::string::npos)
                return fail("resident incident omitted the selected protected device");
            if (turn == 0) {
                if (body.find("inspect_system") == std::string::npos || body.find("apply_profile") != std::string::npos)
                    return fail("resident advertised physical actuation before qualification");
                output = call("inspect_system", "{\"candidate_id\":\"lo0:127.0.0.1\"}");
            } else if (turn == 1) {
                if (body.find("function_call_output") == std::string::npos || body.find("inventory") == std::string::npos)
                    return fail("resident did not continue with protected tool evidence");
                output = call("apply_profile", "{}");
            } else if (turn == 2) {
                if (body.find("physical_actuation_unqualified") == std::string::npos)
                    return fail("unqualified model action was not explicitly rejected");
                output = "{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Selected device inspected; unsafe actuation refused.\"}]}";
            } else return fail("unexpected resident continuation");
            ++turn;
        } else {
            if (body.find("\\\"authority\\\":\\\"read_only\\\"") == std::string::npos ||
                body.find("authored_host_fixture") == std::string::npos || body.find("\"tools\":[]") == std::string::npos ||
                body.find("apply_profile") != std::string::npos) return fail("service incident escaped its read-only evidence scope");
            output = "{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Observed route transition; no mutation authorized.\"}]}";
        }
        pending = "{\"status\":200,\"body\":{\"id\":\"fixture-service\",\"model\":\"fixture-meta\",\"output\":[" + output + "]}}";
        *out = 1;
        return CT_OK;
    }
    const char *session = std::getenv("CONTINUUM_FIXTURE_SESSION");
    if (session) {
        // A transport double, not model-quality or provider-access evidence.
        const std::string marker = "\\\"run_id\\\":\\\"";
        const auto start = body.find(marker);
        if (start == std::string::npos) return fail("session run identity missing");
        const auto end = body.find("\\\"", start + marker.size());
        if (end == std::string::npos) return fail("session run identity unterminated");
        const auto run = body.substr(start + marker.size(), end - start - marker.size());
        const bool task = body.find("\"tools\":[]") != std::string::npos;
        if (task) {
            if (std::string(session) == "outage") return CT_FAILED;
            std::string result = "{\"schema_version\":\"1.0\",\"run_id\":" + quote(run) +
                ",\"task_id\":\"release-audit\",\"task_revision\":1,\"decision\":\"hold\","
                "\"findings\":[{\"finding_id\":\"REL-17\",\"severity\":\"blocker\",\"summary\":\"Rollback rehearsal incomplete.\","
                "\"evidence_ids\":[\"ci-summary:v1\",\"rollout-policy:v1\"]},"
                "{\"finding_id\":\"SEC-42\",\"severity\":\"blocker\",\"summary\":\"Authorization defect unresolved.\","
                "\"evidence_ids\":[\"security-review:v1\",\"rollout-policy:v1\"]}],"
                "\"missing_evidence_ids\":[],\"summary\":\"Hold for the two unresolved blockers.\"}";
            if (std::string(session) == "invalid") result = "not a task result";
            if (std::string(session) == "changed-input") {
                FILE *f = std::fopen("fixtures/corpus/security-review.md", "a");
                if (!f) return fail("cannot change sandbox evidence");
                std::fputs("\nEvidence changed during the model request.\n", f);
                std::fclose(f);
            }
            output = "{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":" + quote(result) + "}]}";
        } else if (turn == 0) {
            output = call("apply_profile", "{\"request_id\":\"fixture-apply\",\"scope_id\":\"lab-sim\","
                "\"path_id\":\"sim0\",\"profile_id\":\"sqm-fair\",\"observation_id\":\"sim-obs\","
                "\"task_revision\":1,\"route_epoch\":3,\"config_revision\":7,\"lease_ms\":60000,"
                "\"rationale\":\"Authored integration decision\"}");
        } else {
            if (body.find("function_call_output") == std::string::npos || body.find("applied") == std::string::npos)
                return fail("controller did not receive the actual apply receipt");
            output = "{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Continue the protected workload.\"}]}";
        }
    } else if (turn == 0) {
        if (body.find("live_host") == std::string::npos || body.find("discover_topology") == std::string::npos ||
            body.find("apply_profile") != std::string::npos) return fail("first context/tools are not live/read-only");
        output = call("discover_topology", "{\"host\":\"unobserved\"}");
    } else if (turn == 1) {
        if (body.find("function_call_output") == std::string::npos || body.find("rejected") == std::string::npos)
            return fail("unknown discovery arguments must return a rejection receipt");
        output = call("discover_topology", "{}");
    } else if (turn == 2) {
        if (body.find("interfaces") == std::string::npos || body.find("live_host") == std::string::npos)
            return fail("real discovery receipt is missing from continuation");
        output = call("apply_profile", "{}");
    } else if (turn == 3) {
        if (body.find("outside read-only discovery scope") == std::string::npos)
            return fail("mutation tool must return a scope rejection receipt");
        output = "{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Observed host paths; management identity remains unverified. No changes made.\"}]}";
    } else return fail("unexpected extra provider request");
    ++turn;
    pending = "{\"status\":200,\"body\":{\"id\":\"fixture-response-" + std::to_string(turn) +
        "\",\"model\":\"fixture-meta\",\"output\":[" + output + "]}}";
    *out = static_cast<uint64_t>(turn);
    return CT_OK;
}
int32_t ct_meta_poll(ct_handle, ct_output out, int64_t *n) {
    if (out.capacity < static_cast<int64_t>(pending.size())) return CT_BUFFER_TOO_SMALL;
    std::memcpy(out.data, pending.data(), pending.size());
    *n = static_cast<int64_t>(pending.size()); return CT_OK;
}
int32_t ct_meta_cancel(ct_handle, uint64_t) { return CT_OK; }
int32_t ct_meta_close(ct_handle) { return CT_OK; }
}
