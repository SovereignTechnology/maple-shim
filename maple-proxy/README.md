# maple-proxy: audio endpoint patch (deployed 2026-08-22)

The incus container `maple-proxy` (10.44.0.22:8080) runs maple-proxy v0.3.2
plus `audio-endpoints.patch` (2 router lines): the stock proxy deliberately
404s `/v1/audio/speech` and `/v1/audio/transcriptions`, but the opensecret
crate and the enclave support both. Home Assistant's maple_tts/maple_stt
custom components depend on these routes.

- Binary: `/usr/local/bin/maple-proxy` in the container; stock backup kept as
  `maple-proxy.0.3.1-stock` alongside it.
- Build: `docker run --rm -v <src>:/src -w /src rust:1-bookworm cargo build
  --release` (container is Debian 12 / glibc 2.36 — do not build on newer
  glibc hosts directly).
- Deploy: `incus file push` to `maple-proxy.new`, `incus exec ... mv` over the
  live binary (it is PID 1; in-place push fails with "text file busy"), then
  `incus restart maple-proxy --force` (no TERM handler as PID 1 — a graceful
  stop hangs forever).
- Contract (both endpoints JSON-in/JSON-out, audio base64 in JSON; auth is the
  client's Bearer key relayed upstream):
  - POST /v1/audio/speech {model: voxtral-tts, input, voice, speed,
    response_format} -> {content_base64, content_type}
  - POST /v1/audio/transcriptions {file: <b64>, filename, content_type,
    model: whisper-large-v3, language, response_format} -> {text, ...}
