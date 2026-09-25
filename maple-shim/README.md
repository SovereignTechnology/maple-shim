# maple-shim (deployed 2026-08-23, became the key broker 2026-09-01)

The single holder of the Maple API keys, in front of maple-proxy. Originally
just an audio adapter; it now also brokers credentials and fails over between
the Max and Pro plans.

- Runs as the Kata VM `maple-shim` on **10.44.0.64:8176** (2026-08-30 cutover;
  `kata/host-workloads.tsv` in sovtech/platform). The script lives in the
  image built from this directory's `Dockerfile` — editing
  `/usr/local/bin/maple-shim.py` on the host now changes nothing. Rebuild,
  `ctr images import`, retag `docker.io/kata/host-maple-shim:migrated`, then
  `systemctl restart kata-maple-shim`. `keys.env` and `tokens` are bind-mounted
  from the host, so the image still holds no secret.
- Published on the tailnet by Caddy as `https://100.64.0.11:62054`
  (`caddy/services.tsv` in sovtech/platform, row `maple-shim`; auburn-cowboys Local Root CA).

## Why it holds the keys

The Maple key used to live in six places across four hosts — opencode on two
laptops, openclaw on booty, ourtranslate, plus a ccr config and a
maple-fusion `.env`. Clients now present a **per-client token** from
`/etc/maple-shim/tokens` and the shim swaps it for the real key, so revoking
one machine does not mean re-keying the rest, and a leaked client config leaks
a token rather than the account.

Keys are delivered by systemd `LoadCredential=` from `/etc/maple-shim/keys.env`
(0600 root). www-data never gets a readable copy on disk.

    /etc/maple-shim/keys.env    MAPLE_KEY_MAX=... / MAPLE_KEY_PRO=...   0600 root
    /etc/maple-shim/tokens      "<token> <label> [flag...]" per line, on mtime
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

Max is used until it stops serving, then Pro.

**Failing over and latching are separate decisions, and that separation is the
whole design.** *Any* refusal moves to the next tier. Only a refusal we can
attribute to quota writes an exhaustion latch.

- **Failover** on any upstream error — any HTTP status, and transport failures
  too. Cost of being wrong: one extra round trip on a request that had already
  failed.
- **Latch** only on `402`, `429`, or a `403` carrying one of `QUOTA_MARKERS`
  (`usage limit`, `token limit`, `quota`, `insufficient credit`). `403` alone is
  not enough, because a rejected key is also a `403`. Cost of being wrong: a
  credential failure reported as a billing one, in `/health` and over Signal,
  until the tier's reset day.

`401` is deliberately **not** a latching signal even though a spent plan is the
likeliest cause of one here — see below.

### What exhaustion actually looks like (measured 2026-09-20)

A spent Max plan refuses `/v1/chat/completions` with a bare
`401 {"status":401,"message":"Unauthorized"}`, streaming or not, **while
`/v1/models` and `/v1/embeddings` keep answering 200 on the same key.** There is
no `403`, no marker string, and nothing to distinguish it from a revoked key
except that the key demonstrably still works elsewhere.

This is why the endpoint went down rather than failing over. The original rule —
fail over only on `403` + `usage limit`, re-raise everything else — could not
match it, so every request hard-failed on Max, Pro was never tried, no latch was
written, and **nothing was logged at all**. `active_tier` therefore never changed,
so booty's Signal watcher stayed silent too. The enclave's *other* exhaustion
error, `Free tier token limit exceeded` (fired above 20k input tokens once an
account drops to free-tier behaviour), was missed by the same rule.

A tier that refuses for an unattributable reason gets a **cooldown**
(`MAPLE_COOLDOWN_SECONDS`, default 900) instead of a latch: demoted, retried
soon, and never described as "exhausted".

### Ordering and self-healing

`_tier_order()` ranks tiers healthy → cooling down → latched, and the sort is
stable, so equal-health tiers keep `TIER_ORDER` and Max stays preferred over Pro.
Every configured tier is still *attempted*, so a stale latch or cooldown heals
itself rather than locking you out.

Max resets on the **1st**, Pro on the **15th**, so a latch is not a timer: it
expires at the next occurrence of its own reset day. A latch cleared too early
(their reset timezone need not match ours) costs one wasted round trip.

**`/v1/models` answers on a spent key, so a 200 from it is not evidence of
health** and must never clear a latch — `_call(..., consumes_quota=False)`.
opencode's `maple-sync.ts` polls it on every startup, so without that guard one
catalogue refresh silently un-latches a spent tier.
**`/v1/embeddings` is the same** (it answers on a spent key too): only
`/v1/chat/completions` counts as evidence. It shares the chat route, so the guard
is `consumes_quota = (path == "/v1/chat/completions")`. Found in review 2026-09-25;
it only bites with **both** tiers latched (month's end), when Max is tried first
and an embeddings 200 would clear its latch. Tests 4c/4d cover it and fail on the
code without the guard.

Failover only happens before the response starts: urllib raises on a non-2xx
before any byte reaches the client. Once an SSE stream has begun, that request
is committed to its tier.

### Tests

`./tests-failover.sh` runs the real script against a stub enclave on loopback
with fake keys — no credentials, no network, no fleet access. It covers all of
the above, including the 401 case verbatim. Against the pre-2026-09-20 code it
fails 12 of 14.

## Notification

booty polls `/health` every 2 minutes (`maple-tier-watch.timer`) and sends a
Signal message via `/etc/nut/ups-alert.sh` when `active_tier` changes. Pull,
not push: signal-cli's JSON-RPC is loopback-only on booty and owned by
openclaw-gateway, so this needs no inbound listener there and no credential on
ubuntu-server.

## Endpoints

- `GET  /health` — active tier, and per-tier `configured`, `exhausted`,
  `exhausted_at`, `resets`, `cooling_down`, `cooldown_until` and `last_error`
  (the upstream status and first 200 bytes of its message). No secrets.
  `resets` is reported whenever `exhausted_at` is set, not only while latched.
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

**Audio requires the patched maple-proxy image** (`ubuntu-server/maple-proxy/`):
stock upstream 404s both audio paths at every version, so an unpatched proxy
makes every audio call here fail with a relayed 404, while chat keeps working.

## Token flags

A third-and-later field on a `tokens` line is a flag for that client.

- `native-audio` — return the enclave's audio JSON (`{content_base64,
  content_type}`) verbatim instead of decoding it to raw bytes. Home
  Assistant's `maple_tts` does its own base64 decode and cannot parse raw
  audio, so this is what let it move off a raw Maple key onto a token without
  touching the component. `X-Maple-Native-Audio: 1` does the same per request.
  Key injection, quota failover and the latch all still apply.

## Clients

| client | endpoint | notes |
|---|---|---|
| opencode (latitude, laptop2) | Caddy `:62054` | token in `auth.json` |
| openclaw (booty) | `127.0.0.1:18080` → socat → `:62054` | `maple-shim-tunnel.service` |
| ourtranslate | `10.44.0.64:8176` | chat + `TTS_BACKEND`/`STT_BACKEND=maple` |
| home-assistant | `10.44.0.64:8176/v1` | `native-audio`; `maple_tts` + `maple_stt` + `llama_conversation` |

Home Assistant was found on 2026-09-02 holding a **raw Pro key** and pointing
straight at maple-proxy — outside the shim, so it had no failover and simply
broke when Pro hit its usage limit. Its config lives in a container volume
(`home-assistant/data/config/{configuration,secrets}.yaml`), which is why it was
missed in the first inventory: grepping the laptops and booty cannot see it.

HA holds Maple credentials in **two** places, and both had the raw Pro key:

- `secrets.yaml` → `maple_api_key`, used by `maple_tts` + `maple_stt`.
- `.storage/core.config_entries` → the `llama_conversation` entry (a HACS
  component, "Generic OpenAI"), which is the LLM behind the **Maple** assist
  pipeline (`stt=maple_stt`, `tts=maple_tts`, conversation = **`glm-5-3`**,
  was `deepseek-v4-flash` until 2026-09-13). Restoring the audio routes alone
  would have left the pipeline mute anyway, because its brain was 403ing.

That entry is edited by stopping HA, rewriting the JSON, then starting it —
HA rewrites `.storage` on shutdown, so editing it live loses the change. Note
`port` is stored as a **string**: writing an int makes the component fail setup
in `format_url` with no useful message.

### Changing the conversation model

The field is `subentries[].data.huggingface_model` (`const.py:90` defines
`CONF_CHAT_MODEL = "huggingface_model"`). It reaches the wire as the request
`model` via `entity.py:695` → `generic_openai.py:108` → `:121`. Set the
subentry `title` to the same value: it drives the device and entity friendly
names (`entity.py:655-660`). Nothing else needs touching.

**Do not rename the entity_id, and do not expect it to follow.** It is
`conversation.deepseek_v4_flash_deepseek_v4_flash` and it will keep that name
forever, because `_attr_unique_id = subentry.subentry_id` is a ULID — the
registry is keyed on that, not on the model string. It looks wrong and it is
deliberate: the **`Maple` assist pipeline binds that entity_id**
(`.storage/assist_pipeline.pipelines`) and the recorder history in
`home-assistant_v2.db` is keyed on it, so renaming would mute the voice
pipeline and orphan the history for a cosmetic gain. `original_name` and the
device name in `core.{entity,device}_registry` also stay at the old value after
a restart; they are display-only.

### GLM landmine: never send `enable_thinking: false` from HA

Measured against the shim on 2026-09-13, with an HA-shaped assist request:

| request | reasoning lands in | spoken text |
|---|---|---|
| default (what HA sends) | nowhere — 0 chars | clean answer |
| `chat_template_kwargs: {enable_thinking: false}` | **`content`** | *"The user wants to know if the nursery air conditioner is on… Let me use the HassGetState tool"* |

`enable_thinking:false` does not stop GLM reasoning, it **relocates the chain
into `content`** — and `content` is exactly what `maple_tts` speaks aloud. It
arrives without `<think>` tags, so the component's `thinking_prefix` /
`thinking_suffix` stripping does not catch it. `llama_conversation` sends no
`chat_template_kwargs` at all, so the default path is safe; the hazard is only
if someone adds one. The same applies to `reasoning_effort` on GLM — see the
measurements in `~/.config/opencode/opencode.jsonc:307-313`.

Second-turn latency (the reply that gets spoken, median of 3):
`glm-5-3` 4.0s [4.0–4.4] · `glm-5-3-flash` 4.5s [3.3–8.3] ·
`deepseek-v4-flash` 5.2s [4.1–8.1]. Both GLM variants tool-called correctly and
neither leaked reasoning at default settings. `glm-5-3` was chosen for the
tightest spread. Note `glm-5-3-flash` exists on the enclave but postdates the
2026-09-02 catalogue refresh in `opencode.jsonc`.
