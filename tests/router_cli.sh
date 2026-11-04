#!/bin/sh
# Operator tuner against the C++ double. status must match an independent
# QoS read. apply must leave the setting. restore must make that revision
# gone. A rejected apply must not move the router.
set -eu
BIN=${1:?continuum binary}
DOUBLE=${2:?router_double}
PORT=${3:-18096}
PW=test-only-pw
UA="OpenAI File Downloader, XaiImageApiFetch/1.0"

pid=""
cleanup() {
    if [ -n "$pid" ]; then
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

ROUTER_PASSWORD=$PW "$DOUBLE" "$PORT" >/dev/null 2>&1 &
pid=$!
ready=0
i=1
while [ "$i" -le 10 ]; do
    if curl -s -A "$UA" -o /dev/null "http://127.0.0.1:$PORT/api/status"; then
        ready=1
        break
    fi
    sleep 1
    i=$((i + 1))
done
if [ "$ready" -ne 1 ]; then
    echo "ROUTER_CLI_RED double did not listen"
    exit 1
fi

qos_line() {
    PORT=$PORT ROUTER_PASSWORD=$PW python3 - <<'PY'
import json, os, urllib.request
port = os.environ["PORT"]
pw = os.environ["ROUTER_PASSWORD"]
ua = "OpenAI File Downloader, XaiImageApiFetch/1.0"
scheme = bytes([66, 101, 97, 114, 101, 114]).decode() + " "

def call(url, data=None, headers=None):
    h = {"User-Agent": ua}
    if headers:
        h.update(headers)
    req = urllib.request.Request(url, data=data, headers=h)
    with urllib.request.urlopen(req, timeout=5) as resp:
        return resp.read()

base = "http://127.0.0.1:" + port
login = call(base + "/api/login",
             data=json.dumps({"password": pw}).encode(),
             headers={"Content-Type": "application/json"})
token = json.loads(login)["session"]
body = json.loads(call(base + "/api/qos",
                       headers={"Authorization": scheme + token}))
on = "on" if body["qos"]["on"] else "off"
print("qos=%s rate_mbit=%s revision=%s" % (on, body["qos"]["rate_mbit"], body["revision"]))
PY
}

run_cli() {
    out=$1
    shift
    set +e
    ROUTER_HOST=127.0.0.1 ROUTER_PORT=$PORT ROUTER_PASSWORD=$PW \
        "$BIN" router "$@" >"$out" 2>"$out.err"
    rc=$?
    set -e
    echo "$rc"
}

fail() {
    echo "ROUTER_CLI_RED $1"
    exit 1
}

tmp=${TMPDIR:-/tmp}/router-cli-$$
mkdir -p "$tmp"

start=$(qos_line)
rc=$(run_cli "$tmp/status0" status)
[ "$rc" = 0 ] || fail "status exit $rc"
got=$(cat "$tmp/status0")
[ "$got" = "$start" ] || fail "status '$got' != router '$start'"

# The model entry must not run a scripted router proof while credentials
# are absent. No decision means no write, including a write later undone.
set +e
env -u MODEL_API_KEY ROUTER_HOST=127.0.0.1 ROUTER_PORT=$PORT ROUTER_PASSWORD=$PW \
    "$BIN" --loop >"$tmp/loop-nokey" 2>"$tmp/loop-nokey.err"
nokey=$?
set -e
[ "$nokey" != 0 ] || fail "model loop accepted a missing MODEL_API_KEY"
[ "$(qos_line)" = "$start" ] || fail "unconfigured model loop mutated the router"

rc=$(run_cli "$tmp/badrate" apply sqm-fair 80)
[ "$rc" != 0 ] || fail "wrong rate was accepted"
now=$(qos_line)
[ "$now" = "$start" ] || fail "wrong rate moved the router to '$now'"

rc=$(run_cli "$tmp/badprof" apply baseline-fifo 100)
[ "$rc" != 0 ] || fail "baseline profile was accepted as an apply"
now=$(qos_line)
[ "$now" = "$start" ] || fail "rejected profile moved the router to '$now'"

rc=$(run_cli "$tmp/apply" apply sqm-fair 90)
[ "$rc" = 0 ] || fail "apply exit $rc: $(cat "$tmp/apply" "$tmp/apply.err")"
applied=$(qos_line)
rev_before=${start##*revision=}
rev_after=${applied##*revision=}
[ "$applied" = "qos=on rate_mbit=90 revision=$((rev_before + 1))" ] || fail "apply left '$applied'"
[ "$rev_after" = "$((rev_before + 1))" ] || fail "apply revision"
apply_out=$(cat "$tmp/apply")
line1=$(printf '%s\n' "$apply_out" | sed -n '1p')
line2=$(printf '%s\n' "$apply_out" | sed -n '2p')
line3=$(printf '%s\n' "$apply_out" | sed -n '3p')
[ "$line1" = "applied profile=sqm-fair rate_mbit=90 revision_before=$rev_before revision_after=$rev_after" ] || fail "apply line '$line1'"
[ "$line2" = "$applied" ] || fail "apply readback '$line2' != '$applied'"
[ -z "$line3" ] || fail "apply printed extra '$line3'"

rc=$(run_cli "$tmp/status1" status)
[ "$rc" = 0 ] || fail "status after apply exit $rc"
[ "$(cat "$tmp/status1")" = "$applied" ] || fail "status forgot the apply"

rc=$(run_cli "$tmp/restore" restore)
[ "$rc" = 0 ] || fail "restore exit $rc: $(cat "$tmp/restore" "$tmp/restore.err")"
restored=$(qos_line)
[ "$restored" = "qos=off rate_mbit=100 revision=$((rev_after + 1))" ] || fail "restore left '$restored'"
case "$restored" in
    *"revision=$rev_after") fail "applied revision $rev_after still current" ;;
esac
r1=$(printf '%s\n' "$(cat "$tmp/restore")" | sed -n '1p')
r2=$(printf '%s\n' "$(cat "$tmp/restore")" | sed -n '2p')
[ "$r1" = "restored revision_before=$rev_after revision_after=$((rev_after + 1))" ] || fail "restore line '$r1'"
[ "$r2" = "$restored" ] || fail "restore readback '$r2' != '$restored'"

set +e
env -u ROUTER_PASSWORD ROUTER_HOST=127.0.0.1 ROUTER_PORT=$PORT \
    "$BIN" router status >"$tmp/nopw" 2>"$tmp/nopw.err"
nopw=$?
set -e
[ "$nopw" != 0 ] || fail "missing password was accepted"
[ "$(qos_line)" = "$restored" ] || fail "password refusal moved the router"

echo "ROUTER_CLI_ALL_GREEN"
