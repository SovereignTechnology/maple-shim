#!/bin/bash
# Build docker.io/kata/maple-proxy-0.4.1-audio:migrated -- upstream Maple proxy
# 0.4.1 plus audio-endpoints.patch, which routes /v1/audio/speech and
# /v1/audio/transcriptions (stock upstream 404s both at every version).
#
# Full rebuild from source, no dockerd (it is disabled on ubuntu-server by
# design; containerd is the runtime). Two chroot stages mirror the upstream
# Dockerfile: rust:1.89.0-bookworm builds the binary, debian:bookworm-slim is
# the runtime. Method mirrors sovtech-ubuntu-server/ci-runner/build-image.sh.
#
# Source is the Maple monorepo proxy/, pinned by SHA in the README. Only
# proxy/{Cargo.toml,Cargo.lock,src} are used (maple-sdk comes from crates.io),
# and rust-toolchain.toml is deliberately NOT copied, so the builder image's
# pinned 1.89.0 is used exactly as upstream's Dockerfile does.
#
# usage: build-image.sh [--no-import]      run as root on ubuntu-server
#   SRC=/path/to/monorepo    dir containing proxy/  (required)
#   BUILDER_DIGEST=sha256:...  pin rust:1.89.0-bookworm (default: resolve now)
#   RUNTIME_DIGEST=sha256:...  pin debian:bookworm-slim
#   OUT_TAG=migrated           tag to import
set -euo pipefail

BUILDER_NAME=docker.io/library/rust
BUILDER_TAG=1.89.0-bookworm
RUNTIME_NAME=docker.io/library/debian
RUNTIME_TAG=bookworm-slim
OUT_NAME=docker.io/kata/maple-proxy-0.4.1-audio
OUT_TAG=${OUT_TAG:-migrated}
W=${W:-/root/build/maple-proxy-0.4.1-audio/image}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC=${SRC:-}

[ "$(id -u)" = 0 ] || { echo "!! run as root" >&2; exit 1; }
for t in ctr jq tar gzip sha256sum python3 git; do
    command -v "$t" >/dev/null || { echo "!! need $t" >&2; exit 1; }
done
[ -n "$SRC" ] && [ -d "$SRC/proxy/src" ] || { echo "!! SRC must point at a monorepo checkout containing proxy/ (got '$SRC')" >&2; exit 1; }
[ -f "$HERE/audio-endpoints.patch" ] || { echo "!! missing $HERE/audio-endpoints.patch" >&2; exit 1; }

case "$W" in /root/build/?*) ;; *) echo "!! W must be under /root/build/ (got '$W')" >&2; exit 1 ;; esac
case "$W" in *..*) echo "!! W must not contain '..'" >&2; exit 1 ;; esac
umask 022
rm -rf "$W"; mkdir -p "$W/oci/blobs/sha256" "$W/build/proxy"

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

export_base() { # name tag outdir
    ctr -n default image pull --platform linux/amd64 "$1:$2" >/dev/null
    ctr -n default image export --platform linux/amd64 base.tar "$1:$2"
    rm -rf "$3"; mkdir -p "$3"
    tar -C "$3" -xf base.tar
}

# --------------------------------------------------------------------------- #
echo "== 0. builder base $BUILDER_NAME:$BUILDER_TAG"
cd "$W"
export_base "$BUILDER_NAME" "$BUILDER_TAG" "$W/base"
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
mkdir -p "$W/rootfs-builder/build"
cp -a "$W/build/proxy" "$W/rootfs-builder/build/proxy"

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
export_base "$RUNTIME_NAME" "$RUNTIME_TAG" "$W/base"
manifest=$(resolve "$(jq -r '.manifests[0].digest' base/index.json)")
mkdir -p "$W/rootfs"
for l in $(jq -r '.layers[].digest' "$manifest"); do
    tar -C "$W/rootfs" --numeric-owner -xpf "base/blobs/sha256/${l#sha256:}"
done
RUNTIME_DIGEST=${RUNTIME_DIGEST:-$(digest_of "$RUNTIME_NAME" "$RUNTIME_TAG")}
echo "   $RUNTIME_NAME@${RUNTIME_DIGEST:-<unresolved>}"

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
python3 - "$W" "$diff_id" "$layer_digest" "$layer_size" "$OUT_NAME" "$OUT_TAG" "$RUNTIME_DIGEST" <<'PY'
import json, hashlib, sys
W, diff_id, ldig, lsize, name, tag, base = sys.argv[1:]
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
       "MAPLE_STREAM_IDLE_TIMEOUT_SECS=300","RUST_LOG=info"]
config = {
  "architecture":"amd64","os":"linux","created":now,
  "config":{"Env":env,
            "Entrypoint":["/usr/local/bin/maple-proxy"],
            "WorkingDir":"/app","User":"maple",
            "ExposedPorts":{"8080/tcp":{}},
            "Labels":{"org.opencontainers.image.base.digest":base,
                      "org.opencontainers.image.description":"maple-proxy 0.4.1 + audio-endpoints.patch",
                      "org.opencontainers.image.source":"https://github.com/MaplePrivacyLabs/Maple"}},
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
