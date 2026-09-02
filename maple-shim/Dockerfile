# Image for the maple-shim Kata VM.
#
# Pure stdlib -- the only imports are http.server, urllib, email, hmac, base64, json,
# threading and datetime -- so there is nothing to pip install and no build stage.
#
# Runs as root in the guest, deliberately. On the host this ran as www-data with
# systemd LoadCredential handing it the keys, because a uid was the only boundary
# available. In a VM the boundary is the VM, and root inside it is the fleet's norm
# (see the user column in incus/containers.tsv). It also lets the process read
# /etc/maple-shim/keys.env, which is 0600 root on the host and keeps that ownership
# through the bind mount.
#
# The keys are NOT baked in and are NOT passed as environment variables: keys.env and
# tokens are bind-mounted from the host at run time, so this image holds no secret and
# maple-shim keeps its "one file, one holder" property.
FROM python:3.14-slim

COPY maple-shim.py /usr/local/bin/maple-shim.py
RUN chmod 0755 /usr/local/bin/maple-shim.py

# Paths the shim resolves from the environment; the unit sets BIND/PORT/STRICT.
ENV MAPLE_TOKENS=/etc/maple-shim/tokens \
    STATE_DIRECTORY=/var/lib/maple-shim

CMD ["/usr/local/bin/python3", "/usr/local/bin/maple-shim.py"]
