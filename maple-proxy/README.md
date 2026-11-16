# maple-proxy: audio + transcription-session patches (upstream 0.5.0, monorepo)

> **Upstream status (checked 2026-11-03).** The standalone
> `OpenSecretCloud/maple-proxy` repo was **retired on 2026-09-08**; development
> moved to [`MaplePrivacyLabs/Maple`, `proxy/`](https://github.com/MaplePrivacyLabs/Maple/tree/master/proxy).
> Replacement images publish to `ghcr.io/mapleprivacylabs/maple-proxy`, one
> version tag per proxy release (0.4.0 to 0.4.5, then 0.5.0 on 2026-11-04);
> the legacy `ghcr.io/opensecretcloud/maple-proxy` publisher is disabled.
>
> **We are now on 0.5.0** (2026-11-06), monorepo commit
> `c760e5b833c7724717deb54478b847bfc7fd0172`: the revision the upstream image
> `ghcr.io/mapleprivacylabs/maple-proxy:0.5.0` names, which `build-image.sh`
> reads from its label and enforces. The audio routes are still absent upstream
> (the table is health, `/`, models, chat, embeddings and `/v1/systemone`), so
> `audio-endpoints.patch` is still required; it applies to 0.5.0 unchanged.
> The `0.4.5-audio` image stays imported as the rollback.
>
> **What 0.5.0 changes for us** (`proxy/` and `sdk/rust/`, `ea026815..c760e5b8`,
> 4 commits): the standalone binary tags its encrypted requests with client app
> `proxy` (upstream: no effect on authentication, model routing or pricing);
> SDK 4.2.0 adds optional catalog fields. No new environment knobs. Separately,
> and whatever proxy version runs, Maple's server refuses `/v1/chat/completions`
> to Free-plan callers since #1437 (2026-11-03), and GPT-OSS 120B and Llama 3.3
> are Pro-only.
>
> **Why 0.4.5 matters:** its SDK bundles the enclave PCR0s approved 2026-10-09
> and 2026-10-11. 0.4.1 bundled only approvals up to 2026-09-14 and verified the
> current enclave through the remote PCR history fetched from GitHub. 0.4.5 also
> carries the crypto-bigint advisory fix (RUSTSEC-2026-0387) and the 360 s stream
> idle default that lets the backend's 300 s provider-timeout error reach clients.

`maple-proxy` (10.44.0.22:8080) runs upstream Maple proxy plus
`audio-endpoints.patch` (2 router lines): the stock proxy 404s
`/v1/audio/speech` and `/v1/audio/transcriptions`, but the opensecret crate and
the enclave support both. Home Assistant's maple_tts/maple_stt components and
ourtranslate's voice path depend on these routes.

**The patch is not optional and it is not a nicety.** Stock upstream has never
routed audio at *any* version — 0.1.8, 0.1.11, 0.3.2 and the 0.4.x monorepo all
have no audio route and no fallback (0.4.5's own tests assert that
`/v1/audio/speech` is not forwarded; since 2026-11-16 the patch moves that test
to `/v1/audio/translations`, which stays unrouted, so the patched tree's
`cargo test --locked` passes: before that, one upstream test always failed). The handler is path-generic: it
takes `OriginalUri` and forwards it verbatim, and the SDK's
`is_allowed_inference_endpoint` already whitelists both audio paths. Routing
them is the whole fix.

## transcription-session.patch: account login for transcription (since 2026-11-10)

The enclave serves `POST /v1/audio/transcriptions` only to a **logged-in user
JWT on a paid plan**; an API key gets `403 transcription_app_only` (enclave
`web/openai.rs` `transcription_access`). Every other route here authenticates
with a per-request key. So with this patch the transcriptions route logs in as
the account the caller names in headers, using the SDK's own `login` /
`login_with_id`:

    X-Maple-Login-Email      a normal account, or
    X-Maple-Login-Id         a private account (a UUID, no e-mail)
    X-Maple-Login-Password   required with either

A request without them behaves exactly as before (key, then the enclave's 403).
maple-shim is the only caller that sends them (keys.env `MAPLE_LOGIN_*`, see its
README). What the patch guarantees, and its unit tests check:

- the three headers are on the unsafe-header list, so they are **never forwarded
  upstream**;
- the credentials type has no `Debug`, and a rejected login answers a bare
  `401 Maple account login rejected` without echoing the backend's message;
- one attested client and session per account, in memory only, so logins for one
  account are serialised; a `401` mid-request logs in again, once;
- since 2026-11-16: a **failed login leaves no entry behind**, so naming
  accounts cannot grow the map, and a **wrong password never evicts a working
  session**: the cached one is replaced only after the new password logs in.

**Exposure.** The proxy API is reachable on the tailnet (Caddy `:62053`) and
through the `maple-proxy api-multi` onion, not only from the shim. Anyone who
reaches it could already use a key of their own, and now an account of their
own. Each attempted login costs one attestation handshake plus one login call
to the enclave, so the patch amplifies traffic toward Maple; it has no rate limit.

It is applied after `audio-endpoints.patch` (it replaces that route's handler),
and `build-image.sh` refuses to continue if either did not apply.

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

## Upstream tracking (since 2026-11-04)

Every upstream input of this image is pinned in [`build-image.sh`](build-image.sh)
and watched by the fleet Renovate job (preset `sovtech/fleet-preset`, manager
M3a), which opens a GitLab MR here when one moves:

| pin | follows | an MR means |
|---|---|---|
| `UPSTREAM_TAG` / `UPSTREAM_DIGEST` | `ghcr.io/mapleprivacylabs/maple-proxy`, the image Maple publishes for each proxy release | a new proxy release: rebuild from its source, re-check the audio patch, deploy |
| `RUNTIME_TAG` / `RUNTIME_DIGEST` | `docker.io/library/debian:bookworm-slim` | a refreshed runtime base (weekly digest batch): rebuild, deploy |
| `BUILDER_TAG` | upstream's `proxy/Dockerfile` | not watched (`# renovate: ignore`): build-only, and the build refuses to run when upstream's Dockerfile names another rust tag, so it moves with a release |

The release pin is what ties the build to upstream: the build reads the
`org.opencontainers.image.revision` label of the pinned image (every blob
checked against its digest) and refuses a `SRC` whose copied paths
(`proxy/{Cargo.toml,Cargo.lock,src,Dockerfile}`, `sdk/rust/{Cargo.toml,src,assets}`)
differ from that commit, or whose `proxy/Cargo.toml` version is not
`UPSTREAM_TAG`. It also refuses when upstream's Dockerfile builds on another
rust tag or runs on another runtime tag than the script. The image it imports
carries `org.opencontainers.image.revision` and `.version` labels of its own.

The monorepo has no proxy tags and is busy (most commits are not the proxy),
so the published image, not the repo, is the release signal.

**0.4.5 predated the pin.** It was built on 2026-11-03 from `ea026815`, the
last commit touching `proxy/`; upstream's own 0.4.5 image was built from
`6f67e8fb`. Since 0.5.0 every build is from the revision the pinned image names.

## Build

[`build-image.sh`](build-image.sh) does a full no-docker rebuild on
ubuntu-server (dockerd is disabled by design; containerd is the runtime),
mirroring upstream's Dockerfile in two chroot stages:

1. builder `docker.io/library/rust:1.89.0-bookworm` — install `pkg-config
   libssl-dev`, apply `audio-endpoints.patch` then `transcription-session.patch`
   inside `proxy/`,
   `cargo build --locked --release --bin maple-proxy`;
2. runtime `docker.io/library/debian:bookworm-slim` — `apt-get upgrade` first
   (the base lags the security pocket: the 0.4.1 image carried old perl-base,
   libbrotli1 and openssl), then `ca-certificates libssl3 curl`, a `maple` user
   (uid 1001), the binary at `/usr/local/bin/maple-proxy`.

The source is staged the way upstream's `proxy/Dockerfile` COPYs it:
`proxy/{Cargo.toml,Cargo.lock,src}` and, **since 0.4.2, the in-tree SDK
`sdk/rust/{Cargo.toml,src,assets}`** (proxy's `Cargo.toml` patches `maple-sdk`
to `path = "../sdk/rust"`; the script checks for that line and stages the SDK
beside `proxy/`). **`rust-toolchain.toml` is deliberately not copied**, so the
builder image's rust is used exactly as upstream's Dockerfile does.
The version, and so the image name `maple-proxy-<ver>-audio`, is read from
`proxy/Cargo.toml` and must equal `UPSTREAM_TAG`. The runtime is pulled by
`RUNTIME_DIGEST`; the builder by `BUILDER_DIGEST` when it is set in the
environment, else by its tag.
The runtime base stays `debian:bookworm-slim` (glibc 2.36) — do not build the
binary on a newer-glibc host and copy it in.

    # on ubuntu-server, as root. SRC is a root-owned git checkout of the
    # monorepo at the revision the pinned image names (the build prints it
    # and says how to check it out when SRC is elsewhere)
    git -C /root/build/maple-src fetch origin <revision>
    git -C /root/build/maple-src checkout --detach <revision>
    SRC=/root/build/maple-src /path/to/build-image.sh   # imports docker.io/kata/maple-proxy-<ver>-audio:migrated

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
sovtech/platform (`maple-proxy-0.5.0-audio`); change it there, not by hand in
the unit. A version change is the "new alias" pattern. **First** re-point the
`maple-proxy` row of sovtech/fleet-scan `coverage.tsv` to the new
`kata/images.tsv` row (it is that row's exemption, so platform's L07 stays red
until it lands; 2026-11-03), then:

    sudo git -C /opt/sovtech-infra pull
    sudo /opt/sovtech-infra/kata/gen-kata-units.sh /tmp/u
    diff /tmp/u/kata-maple-proxy.service /etc/systemd/system/kata-maple-proxy.service
    sudo /opt/sovtech-infra/kata/gen-kata-units.sh --install
    sudo systemctl restart kata-maple-proxy

**Rollback.** The previous image stays imported as
`docker.io/kata/maple-proxy-0.4.5-audio:migrated` (`sha256:e93e5211…`, the image
the unit ran from 2026-11-03 to 2026-11-06). Quick rollback (keeps the unit on the
new alias): `ctr -n default image tag --force
docker.io/kata/maple-proxy-0.4.5-audio:migrated
docker.io/kata/maple-proxy-0.5.0-audio:migrated` and restart. Clean rollback:
revert the tsv row, pull, `gen-kata-units.sh --install`, restart. `ctr` renders
the hyphen in a ref as a space in its own output — never parse that output for
a ref.

## Deploys

- **2026-11-10 — 0.5.0-audio + transcription-session.patch** (recorded
  2026-11-16: the source stayed in ubuntu-server `/root/staging/maple-0.5.0-session/`
  until then). Same `c760e5b8` and pins as 11-06, plus the patch.
  `docker.io/kata/maple-proxy-0.5.0-audio:session-20261110` (`sha256:d803f535…`),
  retagged `:migrated` under the same alias, unit restarted 07:17Z. Rollback then:
  `:pre-session-20261110` (`673f9535`, the 11-06 build).
- **2026-11-06 — 0.5.0-audio.** Monorepo `c760e5b8` (the revision of upstream's
  0.5.0 image), patch unchanged, same builder and runtime pins as 0.4.5.
  `docker.io/kata/maple-proxy-0.5.0-audio:migrated` = `sha256:673f9535…`.
  `build-ca-layer.sh` found neither eMudhra root (bundle 148): no layer.
  Rollback: `maple-proxy-0.4.5-audio:migrated`.
- **2026-11-03 — 0.4.5-audio.** Monorepo `ea026815`, patch rebased after
  `/v1/systemone`, in-tree SDK staged, runtime upgraded. `build-ca-layer.sh`
  found neither eMudhra root, so no CA layer was added. Rollback:
  `maple-proxy-0.4.1-audio:migrated`.
- **2026-10-02 — 0.4.1-audio.** Built from monorepo `312d6c71` by
  `build-image.sh`, imported `docker.io/kata/maple-proxy-0.4.1-audio:migrated`
  (`sha256:b6831c73…`), containers.tsv row switched (sovtech/platform !33).
  Transport V2 returns raw audio (no base64 envelope), which required a
  maple-shim fix the same day. Rollback: `maple-proxy-0.3.2-audio:migrated`.
- **2026-09-02 — 0.3.2-audio.** Patched 0.3.2 (`sha256:b953e868…`).

## Contract

Transcription additionally needs the `X-Maple-Login-*` headers described
above; with only a key the enclave answers `403 transcription_app_only`.

Both endpoints are JSON-in/JSON-out with the audio base64 inside the JSON —
this is the *enclave's* contract, not OpenAI's. `maple-shim` translates it to
the OpenAI shape for normal clients, and passes it through untouched for
clients flagged `native-audio` (Home Assistant). Auth is a Bearer key, which
maple-shim injects; clients hold revocable tokens, not Maple keys.

- `POST /v1/audio/speech` `{model: voxtral-tts, input, voice, speed,
  response_format}` -> `{content_base64, content_type}`
- `POST /v1/audio/transcriptions` `{file: <b64>, filename, content_type,
  model: whisper-large-v3, language, response_format}` -> `{text, ...}`
