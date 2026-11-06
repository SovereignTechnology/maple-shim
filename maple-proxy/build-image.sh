#!/bin/bash
# Build docker.io/kata/maple-proxy-<ver>-audio:migrated -- upstream Maple proxy
# <ver> (read from the source's proxy/Cargo.toml) plus audio-endpoints.patch,
# which routes /v1/audio/speech and /v1/audio/transcriptions (stock upstream
# 404s both at every version).
#
# Full rebuild from source, no dockerd (it is disabled on ubuntu-server by
# design; containerd is the runtime). Two chroot stages mirror the upstream
# Dockerfile: rust:1.89.0-bookworm builds the binary, debian:bookworm-slim is
# the runtime. Method mirrors sovtech-ubuntu-server/ci-runner/build-image.sh.
#
# Source is the Maple monorepo. The release this build follows is pinned below
# as UPSTREAM_TAG/UPSTREAM_DIGEST: the image Maple publishes for each proxy
# release (ghcr.io/mapleprivacylabs/maple-proxy). Renovate (the fleet job, preset
# M3a) watches its tags and opens an MR that bumps both lines. The build reads
# the source commit from that image's org.opencontainers.image.revision label
# and refuses a SRC whose proxy/ or sdk/rust/ differs from that commit, so a
# bumped pin can only be built from the source upstream released.
#
# Staged exactly as upstream's proxy/Dockerfile COPYs it:
# proxy/{Cargo.toml,Cargo.lock,src} and, since 0.4.2, the in-tree SDK
# sdk/rust/{Cargo.toml,src,assets} (proxy's Cargo.toml patches maple-sdk to path
# ../sdk/rust). rust-toolchain.toml is deliberately NOT copied, so the builder
# image's rust is used exactly as upstream's Dockerfile does; the build checks
# that BUILDER_TAG and RUNTIME_TAG still name the tags of that Dockerfile.
#
# usage: build-image.sh [--no-import]      run as root on ubuntu-server
#   SRC=/path/to/monorepo    git checkout of the monorepo at the release revision (required)
#   BUILDER_DIGEST=sha256:...  pull rust:<BUILDER_TAG> by this digest (default: the tag, now)
#   OUT_TAG=migrated           tag to import
set -euo pipefail

BUILDER_NAME=docker.io/library/rust
# renovate: ignore build-only, and held equal to the rust tag of upstream's proxy/Dockerfile (checked below): it moves with an upstream release, never alone
BUILDER_TAG=1.89.0-bookworm
RUNTIME_NAME=docker.io/library/debian
# renovate: datasource=docker depName=docker.io/library/debian
RUNTIME_TAG=bookworm-slim
RUNTIME_DIGEST=sha256:99c0b25c46d0214d5a2091092e7908907dcaecd6a962cde0ac700acee222b6f3
UPSTREAM_NAME=ghcr.io/mapleprivacylabs/maple-proxy
# renovate: datasource=docker depName=ghcr.io/mapleprivacylabs/maple-proxy
UPSTREAM_TAG=0.5.0
UPSTREAM_DIGEST=sha256:d6165a34aa2ea50d206e57223a3016da4051ddf9f8bd87f8636c2d1b5ed9940a
# renovate: ignore the tag the build imports as, not an input
OUT_TAG=${OUT_TAG:-migrated}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${SRC:-}

[ "$(id -u)" = 0 ] || { echo "!! run as root" >&2; exit 1; }
for t in ctr jq tar gzip sha256sum python3 git curl; do
    command -v "$t" >/dev/null || { echo "!! need $t" >&2; exit 1; }
done
[ -n "$SRC" ] && [ -d "$SRC/proxy/src" ] || { echo "!! SRC must point at a monorepo checkout containing proxy/ (got '$SRC')" >&2; exit 1; }
[ -f "$HERE/audio-endpoints.patch" ] || { echo "!! missing $HERE/audio-endpoints.patch" >&2; exit 1; }
# The version names the image; read it from [package], never trust a stale constant.
VER=$(awk '/^\[/{p=($0=="[package]")} p && /^version *= *"/{gsub(/.*= *"|".*/,""); print; exit}' "$SRC/proxy/Cargo.toml")
case "$VER" in [0-9]*.[0-9]*.[0-9]*) ;; *) echo "!! no [package] version in $SRC/proxy/Cargo.toml (got '$VER')" >&2; exit 1 ;; esac
case "$VER" in *[!0-9.]*) echo "!! version '$VER' is not plain digits and dots" >&2; exit 1 ;; esac
[ "$VER" = "$UPSTREAM_TAG" ] || { echo "!! SRC is proxy $VER but the pinned upstream release is $UPSTREAM_TAG" >&2; exit 1; }
OUT_NAME=docker.io/kata/maple-proxy-$VER-audio
W=${W:-/root/build/maple-proxy-$VER-audio/image}
# 0.4.2+ build against the in-tree SDK; stage it when the manifest says so.
SDK=no
if grep -q '^maple-sdk *= *{ *path *= *"\.\./sdk/rust" *}' "$SRC/proxy/Cargo.toml"; then
    for f in Cargo.toml src assets; do
        [ -e "$SRC/sdk/rust/$f" ] || { echo "!! proxy patches maple-sdk to ../sdk/rust but $SRC/sdk/rust/$f is missing" >&2; exit 1; }
    done
    SDK=yes
fi
echo "== maple-proxy $VER (in-tree sdk: $SDK) -> $OUT_NAME:$OUT_TAG"

case "$W" in /root/build/?*) ;; *) echo "!! W must be under /root/build/ (got '$W')" >&2; exit 1 ;; esac
case "$W" in *..*) echo "!! W must not contain '..'" >&2; exit 1 ;; esac
umask 022
# A run that died between a /dev bind below and its umount (SIGKILL skips the EXIT trap) leaves the
# host /dev mounted under $W, and rm -rf would then unlink host device nodes (/dev/kvm, /dev/null...).
# So the whole build runs in a private mount namespace -- its mounts die with it and no other run sees
# them -- and refuses to start while anything older is still mounted under $W.
[ -n "${BUILD_IMAGE_NS:-}" ] || exec unshare -m --propagation private env BUILD_IMAGE_NS=1 "$0" "$@"
if awk -v w="$W/" 'index($5, w) == 1 {f = 1} END {exit !f}' /proc/self/mountinfo; then
    echo "!! something is still mounted under $W -- unmount it first" >&2; exit 1
fi
rm -rf --one-file-system "$W"; mkdir -p "$W/oci/blobs/sha256" "$W/build/proxy" "$W/build/sdk/rust"

resolve() { # index -> (nested index) -> amd64 manifest blob path
    local d=$1 mt
    while :; do
        mt=$(jq -r '.mediaType // ""' "base/blobs/sha256/${d#sha256:}")
        case "$mt" in
            *manifest*) echo "base/blobs/sha256/${d#sha256:}"; return ;;
            *index*|*list*) d=$(jq -r '[.manifests[] | select(.platform.architecture=="amd64" and .platform.os=="linux")][0].digest' "base/blobs/sha256/${d#sha256:}") ;;
            *) echo "!! unknown mediaType '$mt' for $d" >&2; return 1 ;;
        esac
    done
}

digest_of() { # name:tag -> digest as ctr reports it (multi-arch index digest)
    ctr -n default image ls | awk -v n="$1:$2" '$1==n {print $3}'
}

export_base() { # name tag outdir [digest] -- by digest when one is given, else by tag
    local ref="$1:$2"
    if [ -n "${4:-}" ]; then
        case "$4" in sha256:[0-9a-f]*) ;; *) echo "!! digest '$4' is not sha256:<hex>" >&2; return 1 ;; esac
        [ "${#4}" = 71 ] || { echo "!! digest '$4' is not 64 hex characters" >&2; return 1; }
        ref="$1@$4"
    fi
    ctr -n default image pull --platform linux/amd64 "$ref" >/dev/null
    ctr -n default image export --platform linux/amd64 base.tar "$ref"
    rm -rf "$3"; mkdir -p "$3"
    tar -C "$3" -xf base.tar
}

ghcr_get() { # manifests|blobs digest outfile accept -- anonymous read of $UPSTREAM_NAME, checked against the digest asked for
    [[ $2 =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "!! '$2' is not sha256:<64 hex>" >&2; return 1; }
    curl -fsSL --proto =https --proto-redir =https --max-time 120 \
        -H "Authorization: Bearer $GHCR_TOKEN" -H "Accept: $4" \
        -o "$3" "https://ghcr.io/v2/${UPSTREAM_NAME#ghcr.io/}/$1/$2"
    [ "sha256:$(sha256sum < "$3" | cut -d' ' -f1)" = "$2" ] || { echo "!! $2: the body does not match its digest" >&2; return 1; }
}

up_from() { # stage -> the image of upstream's 'FROM <image> AS <stage>', registry and namespace dropped
    awk -v s="$1" 'toupper($1)=="FROM" && toupper($(NF-1))=="AS" && tolower($NF)==s {print $2; exit}' "$SRC/proxy/Dockerfile" | sed 's#.*/##'
}

# --------------------------------------------------------------------------- #
# The source must be exactly what upstream released as $UPSTREAM_TAG: the commit
# the pinned image's revision label names, for every path this build copies.
echo "== 0a. upstream release $UPSTREAM_NAME:$UPSTREAM_TAG"
case "$UPSTREAM_NAME" in ghcr.io/?*) ;; *) echo "!! UPSTREAM_NAME must be on ghcr.io (got '$UPSTREAM_NAME')" >&2; exit 1 ;; esac
mkdir -p "$W/upstream"
GHCR_TOKEN=$(curl -fsS --proto =https --max-time 30 "https://ghcr.io/token?scope=repository:${UPSTREAM_NAME#ghcr.io/}:pull" | jq -r '.token // empty')
[[ $GHCR_TOKEN =~ ^[A-Za-z0-9._~+/=-]+$ ]] || { echo "!! no usable anonymous pull token from ghcr.io" >&2; exit 1; }
MAN='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'
ghcr_get manifests "$UPSTREAM_DIGEST" "$W/upstream/top" "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, $MAN"
if jq -e '.manifests | type == "array"' "$W/upstream/top" >/dev/null; then
    ghcr_get manifests "$(jq -r '[.manifests[] | select(.platform.architecture=="amd64" and .platform.os=="linux")][0].digest // ""' "$W/upstream/top")" \
        "$W/upstream/manifest" "$MAN"
else
    cp "$W/upstream/top" "$W/upstream/manifest"
fi
ghcr_get blobs "$(jq -r '.config.digest // ""' "$W/upstream/manifest")" "$W/upstream/config" 'application/vnd.oci.image.config.v1+json, application/octet-stream'
REV=$(jq -r '.config.Labels["org.opencontainers.image.revision"] // ""' "$W/upstream/config")
up_ver=$(jq -r '.config.Labels["org.opencontainers.image.version"] // ""' "$W/upstream/config")
[[ $REV =~ ^[0-9a-f]{40}$ ]] || { echo "!! the pinned image names no source revision (got '$REV')" >&2; exit 1; }
[ "$up_ver" = "$UPSTREAM_TAG" ] || { echo "!! the pinned image is version '$up_ver', not $UPSTREAM_TAG" >&2; exit 1; }
echo "   source revision $REV"
# Git refuses a SRC that root does not own (safe.directory): never override that here, a foreign
# repo config (core.fsmonitor) would run as root.
COPIED=(proxy/Cargo.toml proxy/Cargo.lock proxy/src proxy/Dockerfile sdk/rust/Cargo.toml sdk/rust/src sdk/rust/assets)
git -C "$SRC" rev-parse -q --verify "$REV^{commit}" >/dev/null \
    || { echo "!! SRC has no commit $REV: git -C $SRC fetch origin $REV && git -C $SRC checkout --detach $REV" >&2; exit 1; }
git -C "$SRC" diff --quiet "$REV" -- "${COPIED[@]}" \
    || { echo "!! SRC differs from $REV under proxy/ or sdk/rust/: git -C $SRC checkout --detach $REV" >&2; exit 1; }
[ -z "$(git -C "$SRC" status --porcelain --untracked-files=all --ignored -- "${COPIED[@]}")" ] \
    || { echo "!! SRC has untracked or ignored files under the paths this build copies" >&2; exit 1; }
[ "$(up_from builder)" = "${BUILDER_NAME##*/}:$BUILDER_TAG" ] \
    || { echo "!! upstream builds with '$(up_from builder)', this script with ${BUILDER_NAME##*/}:$BUILDER_TAG: update BUILDER_TAG" >&2; exit 1; }
[ "$(up_from runtime)" = "${RUNTIME_NAME##*/}:$RUNTIME_TAG" ] \
    || { echo "!! upstream runs on '$(up_from runtime)', this script on ${RUNTIME_NAME##*/}:$RUNTIME_TAG: update the RUNTIME pin" >&2; exit 1; }

# --------------------------------------------------------------------------- #
echo "== 0b. builder base $BUILDER_NAME:$BUILDER_TAG"
cd "$W"
export_base "$BUILDER_NAME" "$BUILDER_TAG" "$W/base" "${BUILDER_DIGEST:-}"
manifest=$(resolve "$(jq -r '.manifests[0].digest' base/index.json)")
mkdir -p "$W/rootfs-builder"
for l in $(jq -r '.layers[].digest' "$manifest"); do
    tar -C "$W/rootfs-builder" --numeric-owner -xpf "base/blobs/sha256/${l#sha256:}"
done
BUILDER_DIGEST=${BUILDER_DIGEST:-$(digest_of "$BUILDER_NAME" "$BUILDER_TAG")}
echo "   $BUILDER_NAME@${BUILDER_DIGEST:-<unresolved>}"

echo "== 1. patch proxy source and stage it"
cp "$SRC/proxy/Cargo.toml" "$SRC/proxy/Cargo.lock" "$W/build/proxy/"
cp -a "$SRC/proxy/src" "$W/build/proxy/src"
( cd "$W/build/proxy" && git apply "$HERE/audio-endpoints.patch" )
grep -q '/v1/audio/speech' "$W/build/proxy/src/lib.rs" || { echo "!! patch did not apply (no audio route in lib.rs)" >&2; exit 1; }
if [ "$SDK" = yes ]; then
    cp "$SRC/sdk/rust/Cargo.toml" "$W/build/sdk/rust/"
    cp -a "$SRC/sdk/rust/src" "$SRC/sdk/rust/assets" "$W/build/sdk/rust/"
fi
mkdir -p "$W/rootfs-builder/build"
cp -a "$W/build/proxy" "$W/rootfs-builder/build/proxy"
[ "$SDK" = no ] || { mkdir -p "$W/rootfs-builder/build/sdk"; cp -a "$W/build/sdk/rust" "$W/rootfs-builder/build/sdk/rust"; }

echo "== 2. chroot build (rust $BUILDER_TAG)"
cp /etc/resolv.conf "$W/rootfs-builder/etc/resolv.conf"
mkdir -p "$W/rootfs-builder/proc" "$W/rootfs-builder/dev" "$W/rootfs-builder/sys"
mount -t proc proc "$W/rootfs-builder/proc"
mount --bind /dev "$W/rootfs-builder/dev"
trap 'umount -l "$W/rootfs-builder/dev" "$W/rootfs-builder/proc" 2>/dev/null || true' EXIT
chroot "$W/rootfs-builder" /usr/bin/env -i \
    PATH=/usr/local/cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    CARGO_HOME=/usr/local/cargo RUSTUP_HOME=/usr/local/rustup HOME=/root \
    /bin/sh -e <<'EOF'
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
apt-get -q update
apt-get -q -y --no-install-recommends install pkg-config libssl-dev
rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin
cd /build/proxy
cargo build --locked --release --bin maple-proxy
EOF
umount "$W/rootfs-builder/dev" "$W/rootfs-builder/proc"; trap - EXIT
BIN="$W/rootfs-builder/build/proxy/target/release/maple-proxy"
[ -x "$BIN" ] || { echo "!! no binary at $BIN" >&2; exit 1; }
echo "   built $(du -h "$BIN" | cut -f1) binary"

# --------------------------------------------------------------------------- #
echo "== 3. runtime base $RUNTIME_NAME:$RUNTIME_TAG"
export_base "$RUNTIME_NAME" "$RUNTIME_TAG" "$W/base" "$RUNTIME_DIGEST"
manifest=$(resolve "$(jq -r '.manifests[0].digest' base/index.json)")
mkdir -p "$W/rootfs"
for l in $(jq -r '.layers[].digest' "$manifest"); do
    tar -C "$W/rootfs" --numeric-owner -xpf "base/blobs/sha256/${l#sha256:}"
done
echo "   $RUNTIME_NAME@$RUNTIME_DIGEST"

cp /etc/resolv.conf "$W/rootfs/etc/resolv.conf"
mkdir -p "$W/rootfs/proc" "$W/rootfs/dev" "$W/rootfs/sys"
mount -t proc proc "$W/rootfs/proc"
mount --bind /dev "$W/rootfs/dev"
trap 'umount -l "$W/rootfs/dev" "$W/rootfs/proc" 2>/dev/null || true' EXIT
printf '#!/bin/sh\nexit 101\n' > "$W/rootfs/usr/sbin/policy-rc.d"; chmod 755 "$W/rootfs/usr/sbin/policy-rc.d"
chroot "$W/rootfs" /usr/bin/env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root \
    /bin/sh -e <<'EOF'
export DEBIAN_FRONTEND=noninteractive LC_ALL=C
apt-get -q update
# The base image lags the security pocket (perl-base, libbrotli1 and openssl
# were all stale in the 0.4.1 build): upgrade it before adding anything.
apt-get -q -y -o Dpkg::Options::=--force-confold upgrade
apt-get -q -y --no-install-recommends install ca-certificates libssl3 curl
rm -rf /var/lib/apt/lists/* /var/cache/apt/*.bin /var/log/apt /var/log/dpkg.log
useradd -m -u 1001 -s /bin/bash maple
mkdir -p /app && chown -R maple:maple /app
EOF
umount "$W/rootfs/dev" "$W/rootfs/proc"; trap - EXIT
rm -f "$W/rootfs/usr/sbin/policy-rc.d" "$W/rootfs/etc/resolv.conf"
: > "$W/rootfs/etc/resolv.conf"   # ctr bind-mounts the real one over this path
install -m 0755 "$BIN" "$W/rootfs/usr/local/bin/maple-proxy"

echo "== 4. squash into one layer"
tar -C "$W/rootfs" --numeric-owner --xattrs --sort=name -cf "$W/layer.tar" .
diff_id=$(sha256sum "$W/layer.tar" | cut -d' ' -f1)
gzip -n -6 "$W/layer.tar"
layer_digest=$(sha256sum "$W/layer.tar.gz" | cut -d' ' -f1)
layer_size=$(stat -c %s "$W/layer.tar.gz")
mv "$W/layer.tar.gz" "$W/oci/blobs/sha256/$layer_digest"

echo "== 5. OCI layout"
python3 - "$W" "$diff_id" "$layer_digest" "$layer_size" "$OUT_NAME" "$OUT_TAG" "$RUNTIME_DIGEST" "$VER" "$REV" <<'PY'
import json, hashlib, sys
W, diff_id, ldig, lsize, name, tag, base, ver, rev = sys.argv[1:]
import datetime
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z")
def blob(obj):
    b = json.dumps(obj, separators=(",",":"), sort_keys=True).encode()
    d = hashlib.sha256(b).hexdigest()
    open(f"{W}/oci/blobs/sha256/{d}","wb").write(b)
    return d, len(b)
env = ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
       "MAPLE_HOST=0.0.0.0","MAPLE_PORT=8080",
       "MAPLE_BACKEND_URL=https://enclave.trymaple.ai",
       "MAPLE_PCR0_ENVIRONMENT=production","MAPLE_DEBUG=false",
       "MAPLE_ENABLE_CORS=true","MAPLE_REQUEST_TIMEOUT_SECS=300",
       "MAPLE_STREAM_IDLE_TIMEOUT_SECS=360","RUST_LOG=info"]
config = {
  "architecture":"amd64","os":"linux","created":now,
  "config":{"Env":env,
            "Entrypoint":["/usr/local/bin/maple-proxy"],
            "WorkingDir":"/app","User":"maple",
            "ExposedPorts":{"8080/tcp":{}},
            "Labels":{"org.opencontainers.image.base.digest":base,
                      "org.opencontainers.image.description":f"maple-proxy {ver} + audio-endpoints.patch",
                      "org.opencontainers.image.source":"https://github.com/MaplePrivacyLabs/Maple",
                      "org.opencontainers.image.revision":rev,
                      "org.opencontainers.image.version":ver}},
  "rootfs":{"type":"layers","diff_ids":[f"sha256:{diff_id}"]},
  "history":[{"created":now,"created_by":"maple-shim/maple-proxy/build-image.sh"}]}
cd_, cs = blob(config)
manifest = {"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json",
  "config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":f"sha256:{cd_}","size":cs},
  "layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","digest":f"sha256:{ldig}","size":int(lsize)}]}
md, ms = blob(manifest)
index = {"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json",
  "manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":f"sha256:{md}","size":ms,
                "platform":{"architecture":"amd64","os":"linux"},
                "annotations":{"org.opencontainers.image.ref.name":f"{name}:{tag}"}}]}
json.dump(index, open(f"{W}/oci/index.json","w"), separators=(",",":"))
json.dump({"imageLayoutVersion":"1.0.0"}, open(f"{W}/oci/oci-layout","w"))
open(f"{W}/MANIFEST_DIGEST","w").write(f"sha256:{md}\n")
print(f"   manifest sha256:{md}  layer {int(lsize)//1048576} MiB")
PY
tar -C "$W/oci" -cf "$W/oci.tar" .

if [ "${1:-}" = "--no-import" ]; then echo "== built $W/oci.tar (not imported)"; exit 0; fi

echo "== 6. import"
ctr -n default images import --platform linux/amd64 --base-name "$OUT_NAME" "$W/oci.tar" >/dev/null
ctr -n default images ls | awk -v n="$OUT_NAME:$OUT_TAG" '$1==n {print "   "$1, $3}'
echo "== $OUT_NAME:$OUT_TAG = $(cat "$W/MANIFEST_DIGEST")  (runtime $RUNTIME_DIGEST)"
