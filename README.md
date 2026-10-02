# maple-shim

The Maple access layer for the SovTech fleet: a single key broker that fails
over between the two Maple plans (Max → Pro) and the patched proxy it fronts.

Source of truth: `nostr://npub1s0vtechh66tx7vrwdud8zfyheu9zca7swwfrzd4qu2a4f93mxs6qvn9adx/git.sovit.xyz/maple-shim`.
A public read-only mirror lives at `https://github.com/SovereignTechnology/maple-shim`.

Split out of `sovtech/ubuntu-server` on 2026-10-02; history for both directories
is preserved.

## Components

| directory | what it is |
|---|---|
| [`maple-shim/`](maple-shim/README.md) | The single holder of the Maple API keys, in front of maple-proxy. Per-client tokens, Max→Pro quota failover, an exhaustion latch, and the OpenAI-compatible audio endpoints. Deployed as the Kata VM `maple-shim` on `10.44.0.64:8176`, published by Caddy as `https://100.64.0.11:62054`. |
| [`maple-proxy/`](maple-proxy/README.md) | The patched `maple-proxy` (upstream Maple 0.4.1 from the `MaplePrivacyLabs/Maple` monorepo, pinned commit `312d6c71`, + `audio-endpoints.patch`) that adds the enclave's audio endpoints. The shim's audio calls fail with a relayed 404 against the stock proxy. Built with `maple-proxy/build-image.sh` (no docker). |

## Deploy

Each directory's README carries its own build and deploy procedure. The shim is
built into an image from `maple-shim/Dockerfile` and run as the Kata VM
`kata-maple-shim`; `maple-proxy/build-image.sh` builds the patched proxy image
(upstream Maple 0.4.1 + audio patch) for the Kata VM `kata-maple-proxy`.

## Secrets

No credential is ever committed here. The runtime keys live only in
`/etc/maple-shim/keys.env` (0600 root) on the host, delivered to the process by
systemd `LoadCredential=`. The durable record is in Bitwarden
(`maple-api-key-max` / `maple-api-key-pro`).
