#!/bin/bash
# Build docker.io/kata/host-maple-shim:migrated from a python:3.14-slim base plus
# maple-shim.py. Full base rebuild, no dockerd: export the base rootfs from
# containerd, add the script, squash to ONE OCI layer, write the OCI layout by
# hand, `ctr images import`. Method mirrors sovtech-ubuntu-server/ci-runner.
#
# The shim is stdlib-only, so there is no chroot install step and no build stage
# (see the Dockerfile). keys.env and tokens are NOT in the image: they are
# bind-mounted at run time, so the image holds no secret.
#
# usage: build-image.sh [--no-import]        run as root on ubuntu-server
#   BASE_DIGEST=sha256:...   pin the base (default: resolve python:3.14-slim now)
#   OUT_TAG=migrated         tag to import (default migrated)
#   W=/root/build/maple-shim-image   build dir (must be under /root/build/)
set -euo pipefail

BASE_NAME=docker.io/library/python
BASE_TAG=3.14-slim
BASE_DIGEST=${BASE_DIGEST:-}
OUT_NAME=docker.io/kata/host-maple-shim
OUT_TAG=${OUT_TAG:-migrated}
W=${W:-/root/build/maple-shim-image}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

[ "$(id -u)" = 0 ] || { echo "!! run as root" >&2; exit 1; }
for t in ctr jq tar gzip sha256sum python3; do
    command -v "$t" >/dev/null || { echo "!! need $t" >&2; exit 1; }
done
[ -f "$HERE/maple-shim.py" ] || { echo "!! missing $HERE/maple-shim.py" >&2; exit 1; }

case "$W" in /root/build/?*) ;; *) echo "!! W must be under /root/build/ (got '$W')" >&2; exit 1 ;; esac
case "$W" in *..*) echo "!! W must not contain '..'" >&2; exit 1 ;; esac
umask 022
rm -rf "$W"; mkdir -p "$W/rootfs" "$W/oci/blobs/sha256" "$W/base"
cd "$W"

echo "== 0. base image $BASE_NAME:$BASE_TAG"
if [ -z "$BASE_DIGEST" ]; then
    ctr -n default image pull --platform linux/amd64 "$BASE_NAME:$BASE_TAG" >/dev/null
    BASE_DIGEST=$(ctr -n default image ls | awk -v n="$BASE_NAME:$BASE_TAG" '$1==n {print $3; exit}')
fi
[ -n "$BASE_DIGEST" ] || { echo "!! could not resolve $BASE_NAME:$BASE_TAG digest" >&2; exit 1; }
echo "   $BASE_NAME@$BASE_DIGEST"

echo "== 1. export base rootfs"
ctr -n default image export --platform linux/amd64 base.tar "$BASE_NAME@$BASE_DIGEST"
tar -C base -xf base.tar
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
manifest=$(resolve "$(jq -r '.manifests[0].digest' base/index.json)")
for l in $(jq -r '.layers[].digest' "$manifest"); do
    tar -C rootfs --numeric-owner -xpf "base/blobs/sha256/${l#sha256:}"
done
base_config="base/blobs/sha256/$(jq -r '.config.digest' "$manifest" | sed 's/^sha256://')"

echo "== 2. maple-shim.py into the rootfs"
install -m 0755 "$HERE/maple-shim.py" rootfs/usr/local/bin/maple-shim.py

echo "== 3. squash into one layer"
tar -C rootfs --numeric-owner --xattrs --sort=name -cf layer.tar .
diff_id=$(sha256sum layer.tar | cut -d' ' -f1)
gzip -n -6 layer.tar
layer_digest=$(sha256sum layer.tar.gz | cut -d' ' -f1)
layer_size=$(stat -c %s layer.tar.gz)
mv layer.tar.gz "oci/blobs/sha256/$layer_digest"

echo "== 4. OCI layout (config inherits the base's Env, then sets the shim's)"
python3 - "$diff_id" "$layer_digest" "$layer_size" "$OUT_NAME" "$OUT_TAG" "$BASE_DIGEST" "$base_config" <<'PY'
import json, hashlib, sys, datetime
diff_id, ldig, lsize, name, tag, base, base_config_path = sys.argv[1:]
now = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00","Z")
base_cfg = json.load(open(base_config_path))
env = list(base_cfg.get("config", {}).get("Env", []))
for pair in ("MAPLE_TOKENS=/etc/maple-shim/tokens", "STATE_DIRECTORY=/var/lib/maple-shim"):
    key = pair.split("=", 1)[0] + "="
    env = [e for e in env if not e.startswith(key)]
    env.append(pair)
def blob(obj):
    b = json.dumps(obj, separators=(",",":"), sort_keys=True).encode()
    d = hashlib.sha256(b).hexdigest()
    open(f"oci/blobs/sha256/{d}","wb").write(b)
    return d, len(b)
desc = "maple-shim (stdlib) on python:3.14-slim; keys bind-mounted, not in image"
config = {
  "architecture":"amd64","os":"linux","created":now,
  "config":{"Env":env,
            "Cmd":["/usr/local/bin/python3","/usr/local/bin/maple-shim.py"],
            "WorkingDir":"/","User":"0:0",
            "Labels":{"org.opencontainers.image.base.digest":base,
                      "org.opencontainers.image.description":desc}},
  "rootfs":{"type":"layers","diff_ids":[f"sha256:{diff_id}"]},
  "history":[{"created":now,"created_by":"maple-shim/build-image.sh"}]}
cd_, cs = blob(config)
manifest = {"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json",
  "config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":f"sha256:{cd_}","size":cs},
  "layers":[{"mediaType":"application/vnd.oci.image.layer.v1.tar+gzip","digest":f"sha256:{ldig}","size":int(lsize)}]}
md, ms = blob(manifest)
index = {"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json",
  "manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":f"sha256:{md}","size":ms,
                "platform":{"architecture":"amd64","os":"linux"},
                "annotations":{"org.opencontainers.image.ref.name":f"{name}:{tag}"}}]}
json.dump(index, open("oci/index.json","w"), separators=(",",":"))
json.dump({"imageLayoutVersion":"1.0.0"}, open("oci/oci-layout","w"))
open("MANIFEST_DIGEST","w").write(f"sha256:{md}\n")
print(f"   manifest sha256:{md}  layer {int(lsize)//1048576} MiB")
PY
tar -C oci -cf oci.tar .

if [ "${1:-}" = "--no-import" ]; then echo "== built $W/oci.tar (not imported)"; exit 0; fi

echo "== 5. import"
ctr -n default images import --platform linux/amd64 --base-name "$OUT_NAME" oci.tar >/dev/null
ctr -n default images ls | awk -v n="$OUT_NAME:$OUT_TAG" '$1==n {print "   "$1, $3}'
echo "== $OUT_NAME:$OUT_TAG = $(cat MANIFEST_DIGEST)  (base $BASE_DIGEST)"
