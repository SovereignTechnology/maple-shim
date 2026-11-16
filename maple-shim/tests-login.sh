#!/bin/bash
# Offline acceptance tests for maple-shim's transcription account-login mode.
#
# The enclave serves POST /v1/audio/transcriptions only to a logged-in account
# (403 transcription_app_only to an API key), so token clients' transcriptions
# go out with X-Maple-Login-* headers built from keys.env's MAPLE_LOGIN_<TIER>_*,
# and never with a key. Runs the real maple-shim.py against a stub enclave on
# loopback with fake keys and fake logins: no credentials, no network, nothing
# outside a temp dir.
#
# What it pins down:
#   - login headers go out, Authorization does not; the API-key path is untouched
#     for chat and for a shim with no logins configured;
#   - which refusals fail over to the other account (401 402 403 429 502 503),
#     which do not (400: the request is at fault; 504: the audio may already
#     have been processed, and replaying it would bill it twice);
#   - which refusals cool an account down (401 402 403 429, not 502/503), and
#     that a cooled account is tried last, not never;
#   - a login refusal never touches the CHAT latch/cooldown in state.json;
#   - the password never reaches the log, even when the upstream echoes it;
#   - a half-configured tier is skipped with a log line, never half-used.
#
# usage: ./tests-login.sh [path-to-maple-shim.py]

set -u
SHIM=${1:-"$(cd "$(dirname "$0")" && pwd)/maple-shim.py"}
[ -r "$SHIM" ] || { echo "!! cannot read $SHIM" >&2; exit 2; }

STUB_PORT=9098 SHIM_PORT=9177
t=$(mktemp -d); chmod 700 "$t"
trap 'kill ${STUB:-} ${SHIM_PID:-} 2>/dev/null; rm -rf "$t"' EXIT

# Fake credentials. Deliberately obvious placeholders -- never real ones.
PRO_ID=3f2a9c1e-1b4d-4e6f-8a7b-0c1d2e3f4a5b
KEYS='MAPLE_KEY_MAX=FAKEMAXKEY
MAPLE_KEY_PRO=FAKEPROKEY'
LOGINS="MAPLE_LOGIN_MAX_EMAIL=max@test.invalid
MAPLE_LOGIN_MAX_PASSWORD=FAKEMAXPASSWORD
MAPLE_LOGIN_PRO_ID=$PRO_ID
MAPLE_LOGIN_PRO_PASSWORD=FAKEPROPASSWORD"
printf 'testtoken123 test-client\n' > "$t/tokens"
printf 'RIFF....WAVEfmt fake audio' > "$t/a.wav"

cat > "$t/stub.py" <<'PYEOF'
"""Stub enclave. Per-account behaviour is read per request from a file; every
request is appended to requests.jsonl (who it authenticated as, nothing else)."""
import json, pathlib, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

BEHAVIOUR, LOG, PORT = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), int(sys.argv[3])
ACCOUNTS = {("email", "max@test.invalid", "FAKEMAXPASSWORD"): "max",
            ("id", sys.argv[4], "FAKEPROPASSWORD"): "pro"}

def cfg():
    out = {}
    for line in BEHAVIOUR.read_text().splitlines():
        if "=" in line:
            k, _, v = line.partition("=")
            out[k.strip()] = v.strip()
    return out

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def _send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_POST(self):
        ln = int(self.headers.get("Content-Length") or 0)
        if ln: self.rfile.read(ln)
        h = self.headers
        auth = h.get("Authorization", "")
        key = {"Bearer FAKEMAXKEY": "max", "Bearer FAKEPROKEY": "pro"}.get(auth)
        email, ident, pw = h.get("X-Maple-Login-Email"), h.get("X-Maple-Login-Id"), h.get("X-Maple-Login-Password")
        acct = ACCOUNTS.get(("email", email, pw) if email else ("id", ident, pw))
        with LOG.open("a") as fh:
            fh.write(json.dumps({"path": self.path, "key": key, "account": acct,
                                 "authorization": bool(auth), "login": bool(email or ident)}) + "\n")
        if self.path == "/v1/chat/completions":
            if cfg().get("chat_status", "200") != "200":
                # Echo the key back, to prove the shim never relays it to the client.
                return self._send(int(cfg()["chat_status"]), {"error": f"bad key {auth}"})
            return self._send(200, {"served_by": key})
        if self.path != "/v1/audio/transcriptions":
            return self._send(404, {"error": "not found"})
        if acct is None:
            # The real enclave's answer to an API key (or to a bad login).
            return self._send(403, {"error": "transcription_app_only"})
        status = int(cfg().get(f"{acct}_status", "200"))
        if status == 200:
            return self._send(200, {"text": "hello", "served_by": acct})
        # Echo the password back, to prove the shim redacts it from its log.
        self._send(status, {"error": f"refused for {pw}"})
    def log_message(self, *a): pass

ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
PYEOF

pass=0; fail=0
ok() { pass=$((pass+1)); printf '%-64s %s\n' "$1" "PASS"; }
no() { fail=$((fail+1)); printf '%-64s %s\n' "$1" "FAIL  <- $2"; }
check() { if eval "$2"; then ok "$1"; else no "$1" "${3:-check failed}"; fi; }
setb() { printf '%s\n' "$@" > "$t/behaviour"; }
transcribe() { curl -sS -m 10 -o "$t/out.json" -w '%{http_code}' \
  -H 'Authorization: Bearer testtoken123' -F "file=@$t/a.wav;type=audio/wav" -F model=whisper-1 \
  "http://127.0.0.1:$SHIM_PORT/v1/audio/transcriptions"; }
chat() { curl -sS -m 10 -o "$t/out.json" -w '%{http_code}' \
  -H 'Authorization: Bearer testtoken123' -H 'Content-Type: application/json' \
  "http://127.0.0.1:$SHIM_PORT/v1/chat/completions" -d '{"model":"m","messages":[]}'; }
# nth request's field, 1-based, from the stub's log
req() { python3 -c 'import json,sys;r=[json.loads(l) for l in open(sys.argv[1])];i=int(sys.argv[2])-1;print(r[i].get(sys.argv[3]) if i<len(r) else "none")' "$t/requests.jsonl" "$1" "$2" 2>/dev/null || echo none; }
nreq() { [ -f "$t/requests.jsonl" ] && wc -l < "$t/requests.jsonl" | tr -d ' ' || echo 0; }
health() { curl -sS -m 5 "http://127.0.0.1:$SHIM_PORT/health" | python3 -c 'import json,sys;d=json.load(sys.stdin);t=d.get("transcription") or {};print(" ".join(f"{k}:{int(bool(v.get(sys.argv[1])))}" for k,v in sorted(t.items())))' "$1"; }
chat_state_clean() { python3 -c 'import json,os,sys;p=sys.argv[1];s=json.load(open(p)) if os.path.exists(p) else {};sys.exit(0 if not any((v or {}).get(f) for v in s.values() for f in ("last_error","cooldown_until","exhausted_at")) else 1)' "$t/state.json"; }

# Each scenario starts a fresh shim (the login cooldown is in memory) and a
# fresh request log. $1 = the keys.env body.
start_shim() {
  printf '%s\n' "$1" > "$t/maple-keys"; rm -f "$t/requests.jsonl" "$t/state.json"
  MAPLE_UPSTREAM="http://127.0.0.1:$STUB_PORT/v1" BIND=127.0.0.1 PORT=$SHIM_PORT \
  MAPLE_SHIM_STRICT=1 MAPLE_TOKENS="$t/tokens" STATE_DIRECTORY="$t" \
  CREDENTIALS_DIRECTORY="$t" MAPLE_COOLDOWN_SECONDS=900 \
  MAPLE_RESET_DAY_MAX=1 MAPLE_RESET_DAY_PRO=15 \
  python3 "$SHIM" >>"$t/shim.log" 2>&1 & SHIM_PID=$!
  for _ in $(seq 50); do curl -s -m 1 -o /dev/null "http://127.0.0.1:$SHIM_PORT/health" && return; sleep 0.1; done
}
stop_shim() { kill $SHIM_PID 2>/dev/null; wait $SHIM_PID 2>/dev/null; SHIM_PID=; }

python3 "$t/stub.py" "$t/behaviour" "$t/requests.jsonl" $STUB_PORT $PRO_ID & STUB=$!
for _ in $(seq 50); do curl -s -m 1 -o /dev/null "http://127.0.0.1:$STUB_PORT/" && break; sleep 0.1; done

# L1 -- the happy path: Max's login, no key on the wire.
setb 'max_status=200' 'pro_status=200'; start_shim "$KEYS
$LOGINS"
c=$(transcribe)
check "L1a transcription with logins -> 200" '[ "$c" = 200 ]' "got $c"
check "L1b served by the Max account" 'grep -q "\"served_by\": *\"max\"" "$t/out.json"' "$(cat "$t/out.json")"
check "L1c login headers sent, Authorization not" '[ "$(req 1 login)" = True ] && [ "$(req 1 authorization)" = False ]' "login=$(req 1 login) auth=$(req 1 authorization)"
check "L1d /health: both logins configured, none cooling" '[ "$(health login_configured)" = "max:1 pro:1" ] && [ "$(health cooling_down)" = "max:0 pro:0" ]' "$(health login_configured) / $(health cooling_down)"
grep -q "loaded logins for tiers: max,pro" "$t/shim.log" && ok "L1e startup logs the configured tiers" || no "L1e startup logs the configured tiers" "missing"
c=$(chat)
check "L1f chat still uses an API key, not a login" '[ "$c" = 200 ] && [ "$(req 2 key)" != None ] && [ "$(req 2 login)" = False ]' "http $c key=$(req 2 key) login=$(req 2 login)"
stop_shim

# L2 -- an account refusal fails over, cools that account, and leaves chat state alone.
setb 'max_status=403' 'pro_status=200'; start_shim "$KEYS
$LOGINS"
c=$(transcribe)
check "L2a Max login 403 -> 200 via the Pro account" '[ "$c" = 200 ] && grep -q "\"served_by\": *\"pro\"" "$t/out.json"' "got $c"
check "L2b Pro went out as X-Maple-Login-Id" '[ "$(req 2 account)" = pro ]' "account=$(req 2 account)"
check "L2c Max is cooling down" '[ "$(health cooling_down)" = "max:1 pro:0" ]' "$(health cooling_down)"
check "L2d chat latch/cooldown untouched" 'chat_state_clean' "state.json has chat state"
c=$(transcribe)
check "L2e cooled Max is tried last: Pro first" '[ "$c" = 200 ] && [ "$(req 3 account)" = pro ] && [ "$(nreq)" = 3 ]' "http $c third=$(req 3 account) n=$(nreq)"
stop_shim

# L3 -- the request is at fault: the other account would refuse it too.
setb 'max_status=400' 'pro_status=200'; start_shim "$KEYS
$LOGINS"
c=$(transcribe)
check "L3  400 is relayed, Pro never tried, Max not cooled" '[ "$c" = 400 ] && [ "$(nreq)" = 1 ] && [ "$(health cooling_down)" = "max:0 pro:0" ]' "http $c n=$(nreq) $(health cooling_down)"
stop_shim

# L4 -- a timeout may mean the audio WAS processed: never replay it on the other account.
setb 'max_status=504' 'pro_status=200'; start_shim "$KEYS
$LOGINS"
c=$(transcribe)
check "L4  504 is relayed, never replayed on Pro" '[ "$c" = 504 ] && [ "$(nreq)" = 1 ]' "http $c n=$(nreq)"
stop_shim

# L5 -- 503 (that account already has a transcription running) fails over without a cooldown.
setb 'max_status=503' 'pro_status=200'; start_shim "$KEYS
$LOGINS"
c=$(transcribe)
check "L5  503 fails over to Pro, Max not cooled" '[ "$c" = 200 ] && [ "$(health cooling_down)" = "max:0 pro:0" ]' "http $c $(health cooling_down)"
stop_shim

# L6 -- both refuse: the last refusal is relayed and logged.
setb 'max_status=401' 'pro_status=401'; start_shim "$KEYS
$LOGINS"
c=$(transcribe)
check "L6a both accounts refuse -> 401 relayed" '[ "$c" = 401 ]' "got $c"
grep -q "every transcription login refused" "$t/shim.log" && ok "L6b 'every transcription login refused' logged" || no "L6b 'every transcription login refused' logged" "silent"
check "L6c both cooling down" '[ "$(health cooling_down)" = "max:1 pro:1" ]' "$(health cooling_down)"
check "L6d the relayed refusal carries no password" '! grep -q -E "FAKEMAXPASSWORD|FAKEPROPASSWORD" "$t/out.json" && grep -q "<redacted>" "$t/out.json"' "$(cat "$t/out.json")"
stop_shim

# L7 -- no logins: transcription keeps the old API-key behaviour (and the enclave's 403).
setb 'max_status=200' 'pro_status=200'; start_shim "$KEYS"
c=$(transcribe)
check "L7a no logins -> a key goes out, no login headers" '[ "$(req 1 key)" != None ] && [ "$(req 1 login)" = False ]' "key=$(req 1 key) login=$(req 1 login)"
check "L7b /health: no logins configured" '[ "$(health login_configured)" = "max:0 pro:0" ]' "$(health login_configured)"
grep -q "loaded logins for tiers: none" "$t/shim.log" && ok "L7c startup logs 'none'" || no "L7c startup logs 'none'" "missing"
stop_shim

# L8 -- a half-set tier is skipped with a log line; the complete one still works.
setb 'max_status=200' 'pro_status=200'; start_shim "$KEYS
MAPLE_LOGIN_MAX_EMAIL=max@test.invalid
MAPLE_LOGIN_PRO_ID=$PRO_ID
MAPLE_LOGIN_PRO_PASSWORD=FAKEPROPASSWORD"
c=$(transcribe)
check "L8a Max without a password is ignored; Pro serves" '[ "$c" = 200 ] && [ "$(req 1 account)" = pro ] && [ "$(nreq)" = 1 ]' "http $c first=$(req 1 account) n=$(nreq)"
grep -q "login for tier max ignored" "$t/shim.log" && ok "L8b the ignored tier is logged" || no "L8b the ignored tier is logged" "silent"
stop_shim

# L10 -- the key path: a refusal that echoes the key is relayed without it.
setb 'chat_status=401'; start_shim "$KEYS"
c=$(chat)
check "L10 chat refusal relayed (401) without the key" '[ "$c" = 401 ] && ! grep -q -E "FAKEMAXKEY|FAKEPROKEY" "$t/out.json" && grep -q "<redacted>" "$t/out.json"' "http $c $(cat "$t/out.json")"
stop_shim

# L9 -- across every scenario above the upstream echoed passwords back; none may reach the log.
n=$(grep -c -E 'FAKEMAXPASSWORD|FAKEPROPASSWORD' "$t/shim.log")
check "L9a no password in the shim log" '[ "$n" = 0 ]' "$n line(s)"
check "L9b the echoed passwords were logged as <redacted>" 'grep -q "<redacted>" "$t/shim.log"' "no <redacted> marker"

echo; echo "PASS=$pass FAIL=$fail"
[ "$fail" -eq 0 ]
