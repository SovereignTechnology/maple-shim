# maple-shim (deployed 2026-08-23)

OpenAI-shaped audio API adapter in front of maple-proxy. The Maple enclave's
audio endpoints are JSON-in/JSON-out (base64 audio inside JSON), so stock
OpenAI clients break against them; this shim translates both directions and
holds no credentials — the client's Bearer key is relayed upstream.

- Runs on the ubuntu-server host: `/usr/local/bin/maple-shim.py` +
  `maple-shim.service`, bound to `10.44.0.1:8176` (incus bridge only, same
  posture as camrecorder on 8175).
- Published on the tailnet by Caddy as `https://100.64.0.11:62054`
  (`caddy/services.tsv` in cam/homelab-platform, row `maple-shim`; auburn-cowboys Local Root CA).
- Endpoints:
  - `POST /v1/audio/speech` — OpenAI TTS request in, raw audio bytes out.
    Forces model `voxtral-tts`; maps OpenAI voice names (alloy, nova, ...) to
    Maple voices; native Maple voice names pass through.
  - `POST /v1/audio/transcriptions` — OpenAI multipart in, OpenAI JSON out.
    Forces model `whisper-large-v3`. A JSON body is passed through as the
    native Maple contract instead.
  - `GET /health`
- Point any OpenAI-compatible client at `https://100.64.0.11:62054/v1` with
  the Maple API key. Audio endpoints need the paid Maple tier.
