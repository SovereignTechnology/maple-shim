#!/usr/bin/env python3
"""maple-shim: the one holder of the Maple API keys, in front of maple-proxy.

Three jobs in a single process, because they all need the same credential:

  1. Key broker. Clients authenticate with a per-client token listed in
     /etc/maple-shim/tokens; the shim swaps that token for a real Maple key
     before talking upstream. A compromised laptop then leaks a revocable
     token instead of the account key, and the keys live in one place rather
     than the six they were scattered across. The keys arrive through systemd
     LoadCredential, so only this service can read them -- there is no
     group-readable copy sitting on disk.

  2. Quota failover. Max is used until the enclave says it is spent, then Pro.
     Exhaustion is HTTP 403 with "Usage limit reached" in the body. It is NOT
     429, and it is NOT every 403 -- a rejected key is a 403 too -- so both the
     status and the body are checked before failing over; treating a bad key as
     exhaustion would spend the other plan's quota on a doomed request.
     /v1/models keeps answering happily on an exhausted key, so this is only
     ever visible on a real inference call. A health probe cannot see it coming.

     Max resets on the 1st and Pro on the 15th, so a latch is not a duration:
     it expires at the next occurrence of its own reset day. Clearing a latch
     early is safe -- their reset timezone need not be ours, and the next call
     simply 403s and re-latches, costing one wasted round trip a month.

  3. Audio translation, the shim's original job: the enclave's audio endpoints
     are JSON-in/JSON-out with base64 audio, which stock OpenAI clients cannot
     speak.

Chat completions are SSE, so responses are relayed chunk by chunk under chunked
transfer encoding. The previous buffered resp.read() was correct for a one-shot
audio blob, but would have destroyed token streaming for every chat client and
capped generations at the read timeout.

  GET  /health                   active tier + latch state, no secrets
  GET  /v1/models
  POST /v1/chat/completions      streaming and non-streaming
  POST /v1/embeddings
  POST /v1/audio/speech          OpenAI JSON in -> raw audio bytes out
  POST /v1/audio/transcriptions  multipart in (or native JSON passthrough)
"""
import base64
import hmac
import json
import os
import sys
import threading
import urllib.error
import urllib.request
from datetime import datetime
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("MAPLE_UPSTREAM", "http://10.44.0.22:8080/v1")
BIND = os.environ.get("BIND", "10.44.0.1")
PORT = int(os.environ.get("PORT", "8176"))
MAX_BODY = 30 * 1024 * 1024

# maple-proxy 0.3.x runs with a 300s request and stream-idle timeout; sit just
# above it so the proxy is what gives up first and we relay its error.
UPSTREAM_TIMEOUT = int(os.environ.get("MAPLE_TIMEOUT", "330"))

# Until every client is migrated off raw Maple keys, an unrecognised bearer is
# relayed upstream untouched -- which is exactly what this shim did before, so
# it is no worse than the status quo. Set MAPLE_SHIM_STRICT=1 once the last
# client is moved, to reject unknown tokens instead.
STRICT = os.environ.get("MAPLE_SHIM_STRICT", "") not in ("", "0", "false")

TOKENS_FILE = os.environ.get("MAPLE_TOKENS", "/etc/maple-shim/tokens")
STATE_DIR = os.environ.get("STATE_DIRECTORY", "/var/lib/maple-shim")
STATE_FILE = os.path.join(STATE_DIR, "state.json")

# Day of the month on which each plan's quota resets.
RESET_DAY = {"max": 1, "pro": 15}
TIER_ORDER = ("max", "pro")

# OpenAI voice names -> nearest Maple voice; native Maple names pass through.
VOICE_MAP = {
    "alloy": "neutral_female",
    "ash": "neutral_male",
    "ballad": "casual_male",
    "coral": "cheerful_female",
    "echo": "neutral_male",
    "fable": "cheerful_female",
    "onyx": "casual_male",
    "nova": "casual_female",
    "sage": "neutral_female",
    "shimmer": "cheerful_female",
    "verse": "casual_male",
}

EXT_CONTENT_TYPES = {
    "wav": "audio/wav",
    "mp3": "audio/mpeg",
    "mpga": "audio/mpeg",
    "ogg": "audio/ogg",
    "oga": "audio/ogg",
    "opus": "audio/ogg",
    "m4a": "audio/mp4",
    "mp4": "audio/mp4",
    "flac": "audio/flac",
    "webm": "audio/webm",
}


def _log(msg: str) -> None:
    print(f"maple-shim: {msg}", file=sys.stderr, flush=True)


def _load_keys() -> dict:
    """Maple keys from the systemd credential, or a root-owned file when run
    by hand. Failing to find one is fatal: a shim with no key is a shim that
    would silently relay whatever a client sent, which is the thing this
    service exists to stop."""
    creds = os.environ.get("CREDENTIALS_DIRECTORY")
    path = os.path.join(creds, "maple-keys") if creds else "/etc/maple-shim/keys.env"
    wanted = {"MAPLE_KEY_MAX": "max", "MAPLE_KEY_PRO": "pro"}
    keys: dict = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                name, _, value = line.partition("=")
                tier = wanted.get(name.strip())
                if tier:
                    keys[tier] = value.strip().strip('"').strip("'")
    except OSError as exc:
        _log(f"FATAL: cannot read keys from {path}: {exc}")
        raise SystemExit(1)
    if not keys:
        _log(f"FATAL: no MAPLE_KEY_MAX or MAPLE_KEY_PRO in {path}")
        raise SystemExit(1)
    _log(f"loaded keys for tiers: {','.join(sorted(keys))}")
    return keys


KEYS = _load_keys()

_tokens: dict = {}
_tokens_mtime = -1.0
_tokens_lock = threading.Lock()


def _tokens_now() -> dict:
    """token -> label, reloaded whenever the file changes, so adding a client
    does not need a restart (and revoking one takes effect immediately)."""
    global _tokens, _tokens_mtime
    try:
        mtime = os.stat(TOKENS_FILE).st_mtime
    except OSError:
        return {}
    with _tokens_lock:
        if mtime != _tokens_mtime:
            table = {}
            try:
                with open(TOKENS_FILE, "r", encoding="utf-8") as fh:
                    for line in fh:
                        line = line.strip()
                        if not line or line.startswith("#"):
                            continue
                        parts = line.split()
                        if len(parts) >= 2:
                            table[parts[0]] = parts[1]
            except OSError as exc:
                _log(f"cannot read {TOKENS_FILE}: {exc}")
                return _tokens
            _tokens = table
            _tokens_mtime = mtime
            _log(f"loaded {len(table)} client token(s)")
        return _tokens


def _label_for(token: str):
    """Compare against every known token in constant time, so a timing signal
    cannot be used to recover one byte at a time."""
    match = None
    for known, label in _tokens_now().items():
        if hmac.compare_digest(known, token):
            match = label
    return match


_state_lock = threading.Lock()


def _read_state() -> dict:
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return {}


def _write_state(state: dict) -> None:
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(state, fh)
    os.replace(tmp, STATE_FILE)


def _next_reset(when: datetime, day: int) -> datetime:
    """The first instant strictly after `when` at which `day` of a month begins.
    day is only ever 1 or 15, so it is always a real date in every month."""
    candidate = when.replace(day=day, hour=0, minute=0, second=0, microsecond=0)
    if candidate <= when:
        year, month = when.year, when.month + 1
        if month > 12:
            year, month = year + 1, 1
        candidate = candidate.replace(year=year, month=month)
    return candidate


def _latched(tier: str, state: dict, now: datetime) -> bool:
    """True while this tier is known-exhausted and its reset day has not come."""
    stamp = (state.get(tier) or {}).get("exhausted_at")
    if not stamp:
        return False
    try:
        when = datetime.fromisoformat(stamp)
    except ValueError:
        return False
    return now < _next_reset(when, RESET_DAY[tier])


def _tier_order(state: dict) -> list:
    """Unlatched tiers first, latched ones after -- but latched tiers are still
    attempted rather than refused outright. If a latch is stale the request
    succeeds and clears it; if it is not, the 403 comes straight back."""
    now = datetime.now()
    configured = [t for t in TIER_ORDER if KEYS.get(t)]
    return [t for t in configured if not _latched(t, state, now)] + [
        t for t in configured if _latched(t, state, now)
    ]


def _set_latch(tier: str, exhausted: bool):
    """Record or clear a tier's exhaustion. Returns the previous stamp so the
    caller can log only genuine transitions rather than every repeat 403."""
    with _state_lock:
        state = _read_state()
        entry = state.setdefault(tier, {})
        previous = entry.get("exhausted_at")
        entry["exhausted_at"] = (
            datetime.now().isoformat(timespec="seconds") if exhausted else None
        )
        _write_state(state)
        return previous


def _is_quota(body: bytes) -> bool:
    return b"usage limit" in (body or b"").lower()


class _UpstreamError(Exception):
    def __init__(self, code: int, body: bytes, content_type):
        super().__init__(f"upstream {code}")
        self.code = code
        self.body = body or b""
        self.content_type = content_type or "application/json"


def _open(path: str, data, content_type, key: str):
    headers = {
        # A client relaying its own raw key hands us the whole header value.
        "Authorization": key if key.lower().startswith("bearer ") else f"Bearer {key}",
        # Cloudflare fronts the enclave and 403s Python-urllib/* (error 1010);
        # the proxy relays our UA upstream, so send a real one.
        "User-Agent": "maple-shim/0.2",
    }
    if content_type:
        headers["Content-Type"] = content_type
    req = urllib.request.Request(UPSTREAM + path, data=data, headers=headers)
    return urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT)


def _call(path: str, data, content_type, relay_key=None):
    """Send a request upstream on the best available tier, failing over on a
    quota 403. Returns (tier, response).

    Failing over is only safe here because urllib raises on a non-2xx before
    any byte has been handed to the client: once a stream has started, the
    tier is committed for that request.
    """
    if relay_key is not None:
        return "relay", _open(path, data, content_type, relay_key)

    state = _read_state()
    last = None
    for tier in _tier_order(state):
        try:
            resp = _open(path, data, content_type, KEYS[tier])
        except urllib.error.HTTPError as exc:
            body = exc.read()
            if exc.code == 403 and _is_quota(body):
                if not _set_latch(tier, True):
                    _log(f"tier {tier} exhausted (403 usage limit) - failing over")
                last = _UpstreamError(exc.code, body, exc.headers.get("Content-Type"))
                continue
            raise _UpstreamError(exc.code, body, exc.headers.get("Content-Type"))
        # A tier that answers is not exhausted, whatever the state file claimed.
        if (state.get(tier) or {}).get("exhausted_at"):
            _set_latch(tier, False)
            _log(f"tier {tier} answering again - latch cleared")
        return tier, resp

    if last is not None:
        _log("every tier is exhausted")
        raise last
    raise _UpstreamError(503, b'{"error":"no maple key configured"}', "application/json")


def _guess_content_type(filename: str, declared: str | None) -> str:
    if declared and declared not in ("application/octet-stream", "text/plain"):
        return declared
    ext = filename.rsplit(".", 1)[-1].lower() if "." in filename else ""
    return EXT_CONTENT_TYPES.get(ext, "audio/mpeg")


def _parse_multipart(content_type: str, body: bytes) -> dict:
    """Return {field: str} plus 'file', 'filename', 'file_content_type'."""
    msg = BytesParser(policy=policy.default).parsebytes(
        b"Content-Type: " + content_type.encode() + b"\r\n\r\n" + body
    )
    out: dict = {}
    for part in msg.iter_parts():
        name = part.get_param("name", header="content-disposition")
        if not name:
            continue
        if name == "file":
            filename = part.get_filename() or "audio.mp3"
            out["file"] = part.get_payload(decode=True) or b""
            out["filename"] = filename
            out["file_content_type"] = _guess_content_type(
                filename, part.get_content_type()
            )
        else:
            payload = part.get_payload(decode=True) or b""
            out[name] = payload.decode("utf-8", "replace").strip()
    return out


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def _reply(self, code: int, body: bytes, content_type: str) -> None:
        self.send_response(code)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _reply_json(self, code: int, obj: dict) -> None:
        self._reply(code, json.dumps(obj).encode(), "application/json")

    def _stream(self, resp, content_type: str) -> None:
        """Relay an SSE body chunk by chunk. read1() is essential: read() would
        block until the buffer filled, which for a token stream means holding
        output back until the generation was nearly done."""
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Accel-Buffering", "no")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        reader = getattr(resp, "read1", resp.read)
        try:
            while True:
                chunk = reader(65536)
                if not chunk:
                    break
                self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.flush()
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            # Client hung up mid-generation; drop the connection and let the
            # upstream response be closed by the caller's `with`.
            self.close_connection = True

    def _relay(self, resp) -> None:
        content_type = resp.headers.get("Content-Type", "application/json")
        if content_type.startswith("text/event-stream"):
            self._stream(resp, content_type)
        else:
            self._reply(resp.status, resp.read(), content_type)

    def _auth(self):
        """Resolve the caller. Returns (relay_key_or_None, label), or None when
        a reply has already been sent."""
        header = self.headers.get("Authorization")
        if not header:
            self._reply_json(401, {"error": "missing Authorization header"})
            return None
        token = header[7:].strip() if header[:7].lower() == "bearer " else header.strip()
        label = _label_for(token)
        if label:
            return None, label
        # Name the caller either way. Without this an unmigrated client is
        # invisible: it either keeps working silently (non-strict) or starts
        # failing somewhere else entirely (strict), with nothing here saying
        # which machine it was.
        if STRICT:
            _log(f"rejected unknown token from {self.client_address[0]} on {self.path}")
            self._reply_json(401, {"error": "unknown client token"})
            return None
        _log(f"relaying a raw key for an unmigrated client at {self.client_address[0]} on {self.path}")
        return header, "unmigrated"

    def _proxy(self, path: str, data, content_type) -> None:
        auth = self._auth()
        if auth is None:
            return
        relay_key, _label = auth
        tier, resp = _call(path, data, content_type, relay_key)
        with resp:
            self._relay(resp)
        del tier

    def _read_body(self) -> bytes | None:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            self._reply_json(400, {"error": "empty body"})
            return None
        if length > MAX_BODY:
            self._reply_json(413, {"error": "body too large"})
            return None
        return self.rfile.read(length)

    def _health(self) -> None:
        state = _read_state()
        now = datetime.now()
        tiers = {}
        for tier in TIER_ORDER:
            stamp = (state.get(tier) or {}).get("exhausted_at")
            latched = _latched(tier, state, now)
            tiers[tier] = {
                "configured": bool(KEYS.get(tier)),
                "exhausted": latched,
                "exhausted_at": stamp,
                "resets": (
                    _next_reset(
                        datetime.fromisoformat(stamp), RESET_DAY[tier]
                    ).isoformat()
                    if latched
                    else None
                ),
            }
        order = _tier_order(state)
        self._reply_json(
            200,
            {
                "status": "ok",
                "upstream": UPSTREAM,
                "active_tier": order[0] if order else None,
                "strict": STRICT,
                "tiers": tiers,
            },
        )

    def _dispatch(self, fn, *args):
        try:
            fn(*args)
        except _UpstreamError as exc:
            self._reply(exc.code, exc.body, exc.content_type)
        except urllib.error.HTTPError as exc:
            self._reply(
                exc.code, exc.read(), exc.headers.get("Content-Type", "application/json")
            )
        except Exception as exc:  # noqa: BLE001
            _log(f"error on {self.path}: {exc}")
            self._reply_json(502, {"error": str(exc)})

    def do_GET(self):
        if self.path == "/health":
            self._dispatch(self._health)
        elif self.path in ("/v1/models", "/models"):
            self._dispatch(self._proxy, "/models", None, None)
        else:
            self._reply_json(404, {"error": "not found"})

    def do_POST(self):
        if self.path in ("/v1/chat/completions", "/v1/embeddings"):
            body = self._read_body()
            if body is None:
                return
            # Forward the raw bytes: maple-proxy passes provider-specific JSON
            # fields through untouched, and re-serialising here would quietly
            # drop the ones this shim does not know about.
            self._dispatch(
                self._proxy,
                self.path[3:],
                body,
                self.headers.get("Content-Type", "application/json"),
            )
        elif self.path == "/v1/audio/speech":
            self._dispatch(self._speech)
        elif self.path == "/v1/audio/transcriptions":
            self._dispatch(self._transcriptions)
        else:
            self._reply_json(404, {"error": "not found"})

    def _speech(self) -> None:
        auth = self._auth()
        if auth is None:
            return
        relay_key, _label = auth
        body = self._read_body()
        if body is None:
            return
        try:
            req = json.loads(body)
        except ValueError:
            self._reply_json(400, {"error": "invalid JSON"})
            return
        text = req.get("input")
        if not text:
            self._reply_json(400, {"error": "missing 'input'"})
            return
        voice = req.get("voice") or "casual_female"
        payload = {
            "model": "voxtral-tts",
            "input": text,
            "voice": VOICE_MAP.get(voice, voice),
            "response_format": req.get("response_format") or "mp3",
        }
        if "speed" in req:
            payload["speed"] = float(req["speed"])
        _tier, resp = _call(
            "/audio/speech", json.dumps(payload).encode(), "application/json", relay_key
        )
        with resp:
            data = json.load(resp)
        audio = base64.b64decode(data["content_base64"])
        self._reply(200, audio, data.get("content_type", "audio/mpeg"))

    def _transcriptions(self) -> None:
        auth = self._auth()
        if auth is None:
            return
        relay_key, _label = auth
        body = self._read_body()
        if body is None:
            return
        content_type = self.headers.get("Content-Type", "")
        if content_type.startswith("application/json"):
            # native Maple contract passthrough for clients that already speak it
            payload = json.loads(body)
            payload.setdefault("model", "whisper-large-v3")
        elif content_type.startswith("multipart/form-data"):
            fields = _parse_multipart(content_type, body)
            if not fields.get("file"):
                self._reply_json(400, {"error": "missing 'file' part"})
                return
            payload = {
                "file": base64.b64encode(fields["file"]).decode(),
                "filename": fields["filename"],
                "content_type": fields["file_content_type"],
                "model": "whisper-large-v3",
                "response_format": fields.get("response_format") or "json",
            }
            if fields.get("language"):
                payload["language"] = fields["language"]
            if fields.get("prompt"):
                payload["prompt"] = fields["prompt"]
            if fields.get("temperature"):
                payload["temperature"] = float(fields["temperature"])
        else:
            self._reply_json(
                415, {"error": "expected multipart/form-data or application/json"}
            )
            return
        _tier, resp = _call(
            "/audio/transcriptions",
            json.dumps(payload).encode(),
            "application/json",
            relay_key,
        )
        with resp:
            self._reply(
                200,
                resp.read(),
                resp.headers.get("Content-Type", "application/json"),
            )

    def log_message(self, fmt, *args):  # quiet
        pass


if __name__ == "__main__":
    os.makedirs(STATE_DIR, exist_ok=True)
    _log(f"listening on {BIND}:{PORT} -> {UPSTREAM} (strict={STRICT})")
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
