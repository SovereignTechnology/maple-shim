# maple-proxy: audio endpoint patch (patched binary 2026-08-22, baked into an image 2026-09-02)

> **Upstream status (checked 2026-10-02).** The standalone
> `OpenSecretCloud/maple-proxy` repo was **retired on 2026-09-08**; development
> moved to [`MaplePrivacyLabs/Maple`, `proxy/`](https://github.com/MaplePrivacyLabs/Maple/tree/master/proxy),
> now at **0.4.1**. Replacement images publish to
> `ghcr.io/mapleprivacylabs/maple-proxy` (tags `0.4.0`/`latest`); the legacy
> `ghcr.io/opensecretcloud/maple-proxy` publisher is disabled, so its `latest`
> no longer tracks new releases.
>
> **Our deployment is the last standalone release, v0.3.2 + `audio-endpoints.patch`,
> and that is still correct.** The audio routes are absent from the monorepo
> proxy too — its route table is unchanged (`/v1/models`, `/v1/chat/completions`,
> `/v1/embeddings` only) — so the patch is still required, and it **applies clean
> to `proxy/` at 0.4.1** (verified 2026-10-02). Re-basing onto 0.4.x is a
> deliberate follow-up, not done yet; upstream's own guidance is to keep a
> deployment on its working image until a replacement is published *and* verified.

`maple-proxy` (10.44.0.22:8080) runs upstream v0.3.2 plus
`audio-endpoints.patch` (2 router lines): the stock proxy 404s
`/v1/audio/speech` and `/v1/audio/transcriptions`, but the opensecret crate and
the enclave support both. Home Assistant's maple_tts/maple_stt components and
ourtranslate's voice path depend on these routes.

**The patch is not optional and it is not a nicety.** Stock upstream has never
routed audio at *any* version — 0.1.8, 0.1.11, 0.3.2 and master all have the
same five-route table with no fallback, and 0.3.2 added a test
(`routes_outside_the_explicit_proxy_surface_are_not_forwarded`) that asserts
`/v1/audio/speech` returns 404. The handler is path-generic: it takes
`OriginalUri` and forwards it verbatim, and the SDK's
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

Upstream's own Dockerfile, so the runtime base stays `debian:bookworm-slim`
(glibc 2.36) — do not build the binary on a newer-glibc host and copy it in.

    git clone --depth 1 --branch v0.3.2 https://github.com/OpenSecretCloud/maple-proxy
    cd maple-proxy && git apply /path/to/audio-endpoints.patch
    docker build -t maple-proxy:0.3.2-audio .
    docker save maple-proxy:0.3.2-audio -o mp-audio.tar   # -> ubuntu-server

The retired-repo clone above still works for v0.3.2. For a 0.4.x re-base, clone
the monorepo instead (`git clone --depth 1 https://github.com/MaplePrivacyLabs/Maple`),
apply the patch under `proxy/`, and build with the monorepo proxy's own
Dockerfile.

On ubuntu-server (dockerd is stopped by design; containerd is the runtime):

    ctr -n default images import /tmp/mp-audio.tar
    ctr -n default images tag docker.io/library/maple-proxy:0.3.2-audio \
                              docker.io/kata/maple-proxy-0.3.2-audio:migrated
    systemctl restart kata-maple-proxy

The image ref is generated from `incus/containers.tsv` column 2 in
sovtech/platform (`maple-proxy-0.3.2-audio`); change it there, not by hand
in the unit. Rollback: set the column back to `maple-proxy-0.3.2` (stock, still
imported, audio 404s) and restart. `ctr` renders the hyphen in a ref as a space
in its own output — never parse that output for a ref.

Note the patch makes upstream's `routes_outside_...` test fail by design;
`cargo build` (what the Dockerfile runs) is unaffected.

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
