# maple-shim (deployed 2026-08-23, became the key broker 2026-09-01)

The single holder of the Maple API keys, in front of maple-proxy. Originally
just an audio adapter; it now also brokers credentials and fails over between
the Max and Pro plans.

- Runs on the ubuntu-server host: `/usr/local/bin/maple-shim.py` +
  `maple-shim.service`, bound to `10.44.0.1:8176` (incus bridge only, same
  posture as camrecorder on 8175).
- Published on the tailnet by Caddy as `https://100.64.0.11:62054`
  (`caddy/services.tsv` in cam/homelab-platform, row `maple-shim`; auburn-cowboys Local Root CA).

## Why it holds the keys

The Maple key used to live in six places across four hosts — opencode on two
laptops, openclaw on booty, the translate gateway, plus a ccr config and a
maple-fusion `.env`. Clients now present a **per-client token** from
`/etc/maple-shim/tokens` and the shim swaps it for the real key, so revoking
one machine does not mean re-keying the rest, and a leaked client config leaks
a token rather than the account.

Keys are delivered by systemd `LoadCredential=` from `/etc/maple-shim/keys.env`
(0600 root). www-data never gets a readable copy on disk.

    /etc/maple-shim/keys.env    MAPLE_KEY_MAX=... / MAPLE_KEY_PRO=...   0600 root
    /etc/maple-shim/tokens      "<token> <label>" per line, reloaded on mtime
    /var/lib/maple-shim/state.json   quota latch (StateDirectory=)

`MAPLE_SHIM_STRICT=1` rejects unknown tokens and logs the caller's IP. It is
**on** (2026-09-01), so every client must hold a token from the table above.

### Why keys.env and not the bw-agent broker

`keys.env` is the runtime source of truth and stays that way. The bw-agent
broker (`secret-run`/`secret-store`, Bitwarden `shared` collection) exists only
on **latitude** — ubuntu-server has no broker, no `/etc/bw-agent`, and no unit.
Standing one up here would give the host that runs all 24 Kata VMs unattended
boot-time access to the *entire* `shared` collection, purely to fetch two keys.
That is a strictly worse blast radius than one 0600 root file holding exactly
those two keys, so it was rejected deliberately — do not "finish the migration".

Both keys ARE in the vault as `maple-api-key-max` / `maple-api-key-pro`
(stored 2026-09-01), but as the durable record for recovery and rotation, not
as a runtime dependency. Rotating a plan key means: update the vault item,
update `keys.env`, `systemctl restart maple-shim`. Clients are untouched —
that is the whole point of the token indirection.

## Quota failover

Max is used until the enclave says it is spent, then Pro.

Exhaustion is **HTTP 403 with `Usage limit reached` in the body** — not 429,
and not every 403, since a rejected key is also 403. Both the status and the
body are checked; treating a bad key as exhaustion would burn the other plan's
quota on a request that was going to fail anyway. Note `/v1/models` keeps
answering normally on an exhausted key, so exhaustion is only ever detectable
on a real inference call.

Max resets on the **1st**, Pro on the **15th**, so a latch is not a timer: it
expires at the next occurrence of its own reset day. A latch cleared too early
(their reset timezone need not match ours) costs one wasted round trip — the
call 403s and re-latches. A latched tier is still tried as a last resort, so a
stale latch heals itself instead of locking you out.

Failover only happens before the response starts: urllib raises on a non-2xx
before any byte reaches the client. Once an SSE stream has begun, that request
is committed to its tier.

## Notification

booty polls `/health` every 2 minutes (`maple-tier-watch.timer`) and sends a
Signal message via `/etc/nut/ups-alert.sh` when `active_tier` changes. Pull,
not push: signal-cli's JSON-RPC is loopback-only on booty and owned by
openclaw-gateway, so this needs no inbound listener there and no credential on
ubuntu-server.

## Endpoints

- `GET  /health` — active tier, per-tier latch and reset date. No secrets.
- `GET  /v1/models`
- `POST /v1/chat/completions` — streaming and non-streaming. SSE is relayed
  chunk by chunk under chunked transfer encoding; the body is forwarded as raw
  bytes so provider-specific JSON fields survive.
- `POST /v1/embeddings`
- `POST /v1/audio/speech` — OpenAI TTS request in, raw audio bytes out. Forces
  model `voxtral-tts`; maps OpenAI voice names (alloy, nova, ...) to Maple
  voices; native Maple voice names pass through.
- `POST /v1/audio/transcriptions` — OpenAI multipart in, OpenAI JSON out.
  Forces `whisper-large-v3`. A JSON body is passed through as the native Maple
  contract instead.

Point any OpenAI-compatible client at `https://100.64.0.11:62054/v1` with its
per-client token. Audio endpoints need the paid Maple tier.
