#!/bin/bash
# Offline acceptance tests for maple-shim's tier failover.
#
# Runs the real maple-shim.py against a stub enclave on loopback with fake keys.
# No Maple credentials, no network, no state outside a temp dir -- so this is
# safe to run anywhere, including on a laptop with no access to the fleet.
#
# The scenarios are the ones that actually bit us:
#
#   1. A spent Max plan refusing /v1/chat/completions with a bare 401 while
#      /v1/models and /v1/embeddings keep answering on the same key. Measured on
#      the live endpoint 2026-09-20. The shim used to relay that 401 straight to
#      the client and never try Pro, which is what took the endpoint down.
#   2. The enclave's OTHER exhaustion error, "Free tier token limit exceeded",
#      which does not contain the substring the old detector looked for.
#   4. /v1/models or /v1/embeddings answering on a spent key must not clear an exhaustion latch --
#      opencode's maple-sync plugin polls it on every startup.
#
# usage: ./tests-failover.sh [path-to-maple-shim.py]

set -u
SHIM=${1:-"$(cd "$(dirname "$0")" && pwd)/maple-shim.py"}
[ -r "$SHIM" ] || { echo "!! cannot read $SHIM" >&2; exit 2; }

t=$(mktemp -d); chmod 700 "$t"
trap 'kill ${STUB:-} ${SHIM_PID:-} 2>/dev/null; rm -rf "$t"' EXIT

# Fake credentials. Deliberately obvious placeholders -- never real keys.
printf 'MAPLE_KEY_MAX=FAKEMAXKEY\nMAPLE_KEY_PRO=FAKEPROKEY\n' > "$t/maple-keys"
printf 'testtoken123 test-client\n' > "$t/tokens"
printf 'max_status=401\npro_status=200\n' > "$t/behaviour"

cat > "$t/stub.py" <<'PYEOF'
"""Stub enclave. Behaviour is read per request from a file, so a scenario can be
flipped without restarting anything."""
import json, pathlib, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BEHAVIOUR = pathlib.Path(sys.argv[1])
BODIES = {
    401: b'{"status":401,"message":"Unauthorized"}',
    403: b'{"status":403,"message":"Free tier token limit exceeded"}',
    429: b'{"status":429,"message":"Too many requests"}',
}

def cfg():
    out = {}
    for line in BEHAVIOUR.read_text().splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    return out

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def _send(self, code, body):
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def _key(self):
        h = self.headers.get("Authorization", "")
        return h[7:].strip() if h[:7].lower() == "bearer " else h.strip()
    def _handle(self, path):
        tier = {"FAKEMAXKEY": "max", "FAKEPROKEY": "pro"}.get(self._key(), "unknown")
        if path == "/models":
            # Answers regardless of plan state, exactly like the real enclave.
            return self._send(200, json.dumps({"data": [{"id": "glm-5-3"}]}).encode())
        if path == "/embeddings":
            # So does /v1/embeddings (measured 2026-09-20 on a spent Max key).
            return self._send(200, json.dumps({"data": [{"embedding": [0.0]}], "served_by": tier}).encode())
        status = int(cfg().get(f"{tier}_status", "200"))
        if status == 200:
            return self._send(200, json.dumps(
                {"served_by": tier, "choices": [{"message": {"content": "ok"}}]}).encode())
        self._send(status, BODIES.get(status, b'{"status":%d}' % status))
    def do_GET(self): self._handle(self.path.replace("/v1", "", 1))
    def do_POST(self):
        ln = int(self.headers.get("Content-Length") or 0)
        if ln: self.rfile.read(ln)
        self._handle(self.path.replace("/v1", "", 1))
    def log_message(self, *a): pass

ThreadingHTTPServer(("127.0.0.1", 9099), H).serve_forever()
PYEOF

pass=0; fail=0
ok() { pass=$((pass+1)); printf '%-62s %s\n' "$1" "PASS"; }
no() { fail=$((fail+1)); printf '%-62s %s\n' "$1" "FAIL  <- $2"; }
setb() { printf '%s\n' "$@" > "$t/behaviour"; }
chat() { curl -sS -m 10 -o "$t/out.json" -w '%{http_code}' \
  -H 'Authorization: Bearer testtoken123' -H 'Content-Type: application/json' \
  http://127.0.0.1:9176/v1/chat/completions -d '{"model":"glm-5-3","messages":[]}'; }
models() { curl -sS -m 5 -o /dev/null -w '%{http_code}' \
  -H 'Authorization: Bearer testtoken123' http://127.0.0.1:9176/v1/models; }
embed() { curl -sS -m 5 -o /dev/null -w '%{http_code}' \
  -H 'Authorization: Bearer testtoken123' -H 'Content-Type: application/json' \
  http://127.0.0.1:9176/v1/embeddings -d '{"model":"nomic-embed-text","input":"x"}'; }
latched() { python3 -c 'import json,sys;print("yes" if (json.load(open(sys.argv[1])).get(sys.argv[2]) or {}).get("exhausted_at") else "no")' "$t/state.json" "$1" 2>/dev/null || echo missing; }

start_shim() {
  MAPLE_UPSTREAM=http://127.0.0.1:9099/v1 BIND=127.0.0.1 PORT=9176 \
  MAPLE_SHIM_STRICT=1 MAPLE_TOKENS="$t/tokens" STATE_DIRECTORY="$t" \
  CREDENTIALS_DIRECTORY="$t" MAPLE_COOLDOWN_SECONDS=900 \
  python3 "$SHIM" >"$t/shim.log" 2>&1 & SHIM_PID=$!; sleep 1
}
stop_shim() { kill $SHIM_PID 2>/dev/null; wait $SHIM_PID 2>/dev/null; SHIM_PID=; }

python3 "$t/stub.py" "$t/behaviour" & STUB=$!
sleep 1

# 1 -- the live failure of 2026-09-20: a spent plan answering 401.
rm -f "$t/state.json"; setb 'max_status=401' 'pro_status=200'; start_shim
c=$(chat)
[ "$c" = 200 ] && ok "1a 401 on Max -> request still succeeds" || no "1a 401 on Max -> request still succeeds" "got $c"
grep -q '"served_by": *"pro"' "$t/out.json" && ok "1b served by Pro" || no "1b served by Pro" "not Pro"
[ "$(latched max)" = no ] && ok "1c Max NOT latched on a 401" || no "1c Max NOT latched on a 401" "latch written"
python3 -c 'import json,sys;m=json.load(open(sys.argv[1])).get("max") or {};sys.exit(0 if m.get("cooldown_until") and (m.get("last_error") or {}).get("code")==401 else 1)' "$t/state.json" \
  && ok "1d Max cooldown + last_error recorded" || no "1d Max cooldown + last_error recorded" "missing"
grep -q "refused with 401" "$t/shim.log" && ok "1e refusal is logged" || no "1e refusal is logged" "silent"
stop_shim

# 2 -- the enclave's other exhaustion error, which carries no "usage limit".
rm -f "$t/state.json"; setb 'max_status=403' 'pro_status=200'; start_shim
c=$(chat)
[ "$c" = 200 ] && ok "2a 403 free-tier-token-limit -> 200 via Pro" || no "2a 403 -> 200 via Pro" "got $c"
[ "$(latched max)" = yes ] && ok "2b Max IS latched on a quota 403" || no "2b Max IS latched on a quota 403" "no latch"
grep -q "exhausted (403)" "$t/shim.log" && ok "2c exhaustion logged" || no "2c exhaustion logged" "silent"
stop_shim

# 3 -- status-only quota signal.
rm -f "$t/state.json"; setb 'max_status=429' 'pro_status=200'; start_shim
chat >/dev/null
[ "$(latched max)" = yes ] && ok "3  429 latches Max" || no "3  429 latches Max" "no latch"
stop_shim

# 4/5 -- /v1/models must not be treated as evidence of health.
rm -f "$t/state.json"; setb 'max_status=403' 'pro_status=200'; start_shim
chat >/dev/null
setb 'max_status=200' 'pro_status=403'
m=$(models)
[ "$m" = 200 ] && ok "4a /v1/models answers" || no "4a /v1/models answers" "got $m"
[ "$(latched max)" = yes ] && ok "4b /v1/models did NOT clear the Max latch" || no "4b /v1/models did NOT clear the Max latch" "cleared"
c=$(chat)
[ "$c" = 200 ] && [ "$(latched max)" = no ] && ok "5  real inference clears a stale latch" || no "5  real inference clears a stale latch" "http $c, latched $(latched max)"
stop_shim

# 4c/4d -- /v1/embeddings also answers on a spent plan. With BOTH tiers latched (month's end)
# the shim tries Max first (stable order), and a 200 there must not clear its latch.
rm -f "$t/state.json"; setb 'max_status=403' 'pro_status=403'; start_shim
chat >/dev/null
e=$(embed)
[ "$e" = 200 ] && ok "4c /v1/embeddings answers on spent plans" || no "4c /v1/embeddings answers on spent plans" "got $e"
[ "$(latched max)" = yes ] && ok "4d /v1/embeddings did NOT clear the Max latch" || no "4d /v1/embeddings did NOT clear the Max latch" "cleared"
stop_shim

# 6 -- nothing left to try.
rm -f "$t/state.json"; setb 'max_status=401' 'pro_status=401'; start_shim
c=$(chat)
[ "$c" = 401 ] && ok "6a both refuse -> upstream status relayed" || no "6a both refuse -> upstream status relayed" "got $c"
grep -q "every tier refused" "$t/shim.log" && ok "6b 'every tier refused' logged" || no "6b 'every tier refused' logged" "silent"
stop_shim

echo; echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
