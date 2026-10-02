# maple-proxy: audio endpoint patch (upstream 0.4.1, monorepo)

> **Upstream status (checked 2026-10-02).** The standalone
> `OpenSecretCloud/maple-proxy` repo was **retired on 2026-09-08**; development
> moved to [`MaplePrivacyLabs/Maple`, `proxy/`](https://github.com/MaplePrivacyLabs/Maple/tree/master/proxy).
> Replacement images publish to `ghcr.io/mapleprivacylabs/maple-proxy`
> (tags `0.4.0`/`latest`); the legacy `ghcr.io/opensecretcloud/maple-proxy`
> publisher is disabled.
>
> **We are now on 0.4.1**, pinned to monorepo commit
> `312d6c718e088a3af120677e553df1b69b141b31` (the latest commit touching
> `proxy/`, 2026-09-22). The audio routes are still absent there, so
> `audio-endpoints.patch` is still required and still applies clean to
> `proxy/src/lib.rs` (verified 2026-10-02). The old `0.3.2-audio` image stays
> imported as the rollback.

`maple-proxy` (10.44.0.22:8080) runs upstream Maple proxy plus
`audio-endpoints.patch` (2 router lines): the stock proxy 404s
`/v1/audio/speech` and `/v1/audio/transcriptions`, but the opensecret crate and
the enclave support both. Home Assistant's maple_tts/maple_stt components and
ourtranslate's voice path depend on these routes.

**The patch is not optional and it is not a nicety.** Stock upstream has never
routed audio at *any* version — 0.1.8, 0.1.11, 0.3.2 and the 0.4.1 monorepo all
have the same route table with no fallback. The handler is path-generic: it
takes `OriginalUri` and forwards it verbatim, and the SDK's
`is_allowed_inference_endpoint` already whitelists both audio paths. Routing
them is the whole fix.

## Why it is an image now (incident, 2026-08-30)

The original deployment pushed a patched *binary* into the running Incus
container (`incus file push`), so the patch lived only in that container's
writable layer. The Kata cutover on 2026-08-30 built its image from the
2026-08-28 Incus **image** export, which never contained that binary — so the
patch vanished and audio has 404'd since, silently: `/v1/models` and chat kept
working, and the only symptom was `404 Not Found` in ourtranslate's log
and a dead HA voice pipeline.

Baking it into the image means restarts, reboots, VM migrations and rebuilds
all keep it. Do not go back to pushing a binary into a running container.

## Build

[`build-image.sh`](build-image.sh) does a full no-docker rebuild on
ubuntu-server (dockerd is disabled by design; containerd is the runtime),
mirroring upstream's Dockerfile in two chroot stages:

1. builder `docker.io/library/rust:1.89.0-bookworm` — install `pkg-config
   libssl-dev`, apply `audio-endpoints.patch` inside `proxy/`,
   `cargo build --locked --release --bin maple-proxy`;
2. runtime `docker.io/library/debian:bookworm-slim` — `ca-certificates libssl3
   curl`, a `maple` user (uid 1001), the binary at `/usr/local/bin/maple-proxy`.

Only `proxy/{Cargo.toml,Cargo.lock,src}` are used (`maple-sdk` comes from
crates.io); **`rust-toolchain.toml` is deliberately not copied**, so the
builder image's pinned 1.89.0 is used exactly as upstream's Dockerfile does.
The runtime base stays `debian:bookworm-slim` (glibc 2.36) — do not build the
binary on a newer-glibc host and copy it in.

    # on ubuntu-server, as root; SRC is a monorepo checkout at the pinned SHA
    SRC=/root/build/maple-proxy-0.4.1-audio/src \
      /path/to/build-image.sh          # imports docker.io/kata/maple-proxy-0.4.1-audio:migrated

### 0.4.x notes

- **`MAPLE_CACHE_NAMESPACE_ROOT` is deliberately NOT set.** It is a
  client-side *secret* that stabilises Tinfoil provider-cache entries across
  restarts. Omitting it is safe — the proxy generates a per-process root and
  requests still work; only cross-restart cache hits are lost. It must not go
  in `/etc/kata/env/maple-proxy.env`: the Kata runtime-rs shim writes the full
  env to journald at every container start. If persistence is ever wanted, it
  needs a secret-delivery path other than `--env-file`.
- **Transport V2.** 0.4.x drops the V1 fallback, so it requires a V2-capable
  enclave. The chat/embeddings smoke test after the switch is mandatory; if the
  production enclave does not accept it, roll back immediately.
- `MAPLE_ENABLE_CORS` defaults to false in 0.4.x; our env file sets it to `true`
  explicitly, so the default change is inert.

## Deploy

The image ref is generated from `incus/containers.tsv` column 2 in
sovtech/platform (`maple-proxy-0.4.1-audio`); change it there, not by hand in
the unit. A version change is the "new alias" pattern:

    sudo git -C /opt/sovtech-infra pull
    sudo /opt/sovtech-infra/kata/gen-kata-units.sh /tmp/u
    diff /tmp/u/kata-maple-proxy.service /etc/systemd/system/kata-maple-proxy.service
    sudo /opt/sovtech-infra/kata/gen-kata-units.sh --install
    sudo systemctl restart kata-maple-proxy

**Rollback.** The previous image stays imported as
`docker.io/kata/maple-proxy-0.3.2-audio:migrated`. Quick rollback (keeps the
unit on the new alias): `ctr -n default image tag --force
docker.io/kata/maple-proxy-0.3.2-audio:migrated
docker.io/kata/maple-proxy-0.4.1-audio:migrated` and restart. Clean rollback:
revert the tsv row, pull, `gen-kata-units.sh --install`, restart. `ctr` renders
the hyphen in a ref as a space in its own output — never parse that output for
a ref.

## Deploys

- **2026-10-02 — 0.4.1-audio.** Built from monorepo `312d6c71` by
  `build-image.sh`, imported `docker.io/kata/maple-proxy-0.4.1-audio:migrated`
  (`sha256:b6831c73…`), containers.tsv row switched (sovtech/platform !33).
  Transport V2 returns raw audio (no base64 envelope), which required a
  maple-shim fix the same day. Rollback: `maple-proxy-0.3.2-audio:migrated`.
- **2026-09-02 — 0.3.2-audio.** Patched 0.3.2 (`sha256:b953e868…`).

## Contract

Both endpoints are JSON-in/JSON-out with the audio base64 inside the JSON —
this is the *enclave's* contract, not OpenAI's. `maple-shim` translates it to
the OpenAI shape for normal clients, and passes it through untouched for
clients flagged `native-audio` (Home Assistant). Auth is a Bearer key, which
maple-shim injects; clients hold revocable tokens, not Maple keys.

- `POST /v1/audio/speech` `{model: voxtral-tts, input, voice, speed,
  response_format}` -> `{content_base64, content_type}`
- `POST /v1/audio/transcriptions` `{file: <b64>, filename, content_type,
  model: whisper-large-v3, language, response_format}` -> `{text, ...}`
