#!/usr/bin/env python3
"""maple-shim: OpenAI-shaped audio API in front of the Maple enclave's JSON contract.

The enclave (via maple-proxy at 10.44.0.22:8080) speaks JSON-in/JSON-out for both
audio endpoints: TTS returns {content_base64, content_type} instead of raw bytes,
and STT wants the audio base64-encoded in a JSON field instead of multipart.
Anything built against OpenAI's audio API therefore breaks against it. This shim
translates in both directions and holds no credentials: the client's
Authorization header is relayed upstream untouched.

  POST /v1/audio/speech          OpenAI JSON in -> raw audio bytes out
  POST /v1/audio/transcriptions  multipart in (or native JSON passthrough) -> JSON out
  GET  /health
"""
import base64
import json
import os
import urllib.error
import urllib.request
from email import policy
from email.parser import BytesParser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("MAPLE_UPSTREAM", "http://10.44.0.22:8080/v1")
BIND = os.environ.get("BIND", "10.44.0.1")
PORT = int(os.environ.get("PORT", "8176"))
MAX_BODY = 30 * 1024 * 1024

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

    def _forward(self, path: str, payload: dict, auth: str):
        req = urllib.request.Request(
            UPSTREAM + path,
            data=json.dumps(payload).encode(),
            headers={
                "Content-Type": "application/json",
                "Authorization": auth,
                # Cloudflare fronts the enclave and 403s Python-urllib/* (error
                # 1010); the proxy relays our UA upstream, so send a real one.
                "User-Agent": "maple-shim/0.1",
            },
        )
        return urllib.request.urlopen(req, timeout=120)

    def _read_body(self) -> bytes | None:
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0:
            self._reply_json(400, {"error": "empty body"})
            return None
        if length > MAX_BODY:
            self._reply_json(413, {"error": "body too large"})
            return None
        return self.rfile.read(length)

    def do_GET(self):
        if self.path == "/health":
            self._reply_json(200, {"status": "ok", "upstream": UPSTREAM})
        else:
            self._reply_json(404, {"error": "not found"})

    def do_POST(self):
        auth = self.headers.get("Authorization")
        if not auth:
            self._reply_json(401, {"error": "missing Authorization header"})
            return
        try:
            if self.path == "/v1/audio/speech":
                self._speech(auth)
            elif self.path == "/v1/audio/transcriptions":
                self._transcriptions(auth)
            else:
                self._reply_json(404, {"error": "not found"})
        except urllib.error.HTTPError as exc:
            self._reply(
                exc.code,
                exc.read(),
                exc.headers.get("Content-Type", "application/json"),
            )
        except Exception as exc:  # noqa: BLE001
            self._reply_json(502, {"error": str(exc)})

    def _speech(self, auth: str) -> None:
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
        with self._forward("/audio/speech", payload, auth) as resp:
            data = json.load(resp)
        audio = base64.b64decode(data["content_base64"])
        self._reply(200, audio, data.get("content_type", "audio/mpeg"))

    def _transcriptions(self, auth: str) -> None:
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
            self._reply_json(415, {"error": "expected multipart/form-data or application/json"})
            return
        with self._forward("/audio/transcriptions", payload, auth) as resp:
            self._reply(
                200,
                resp.read(),
                resp.headers.get("Content-Type", "application/json"),
            )

    def log_message(self, fmt, *args):  # quiet
        pass


if __name__ == "__main__":
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()
