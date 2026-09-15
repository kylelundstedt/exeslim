#!/bin/bash
# Join the IV tailnet, IF AND ONLY IF this VM was granted permission to.
#
# The consent signal is the `api-tailscale` exe.dev integration. exe.dev injects
# the Tailscale OAuth credential at the network edge, so the proxy answers only
# from a VM the control plane deliberately attached it to. Unattached, the token
# exchange returns no access_token and this exits 0 having done nothing.
#
# THIS IS NOT THE v2.0.0 AUTO-JOIN. That was removed because it put every VM on
# the tailnet whether or not it belonged there. The difference is the gate: the
# decision lives off-VM, in an integration attachment, exactly as it does for dev
# VMs in provision-iv.sh. A prod VM with no attachment stays off the tailnet.
#
# It exists as a UNIT rather than a provisioning step because the prod lane has
# no provisioner: no git, no python, no agent. Anything not in the image is
# something a human has to remember, and the whole reason this lane went dark for
# 26 days is that nobody remembered.
#
# tag:prod, never tag:dev. Prod VMs are internet-facing; the tailnet policy
# grants dev -> prod on :22 for verification and deliberately grants nothing in
# the reverse direction.
set -uo pipefail

PROXY=${IV_TAILSCALE_API_URL:-https://api-tailscale.int.exe.xyz}
TS_API=https://api.tailscale.com
TAG=${IV_TAILSCALE_TAG:-tag:prod}

# Already a member? Nothing to do. Re-running must never re-register a node.
if tailscale status >/dev/null 2>&1; then
  echo "already on the tailnet; nothing to do"
  exit 0
fi

# The exchange doubles as the reachability probe: an unattached proxy answers
# with a non-JSON error page, so jq needs its own redirect (in a pipeline the
# 2>/dev/null binds to curl alone).
#
# RETRY, because this runs at boot and the two failure modes are
# indistinguishable from one attempt:
#   - genuinely unattached      -> correct to give up, VM stays off the tailnet
#   - attached but not ready yet -> exe.dev's integration plumbing is eventually
#                                   consistent on first use (the same reason
#                                   new-dev-vm retries repo clones), and giving
#                                   up here strands the VM until someone reboots
#                                   it by hand
# Six tries over ~2.5 min costs nothing on an unattached VM and rescues the
# common case where the edge is still wiring up on first boot.
token=""
for attempt in 1 2 3 4 5 6; do
  token=$(curl -sL --connect-timeout 5 --max-time 20 -X POST \
    -d "grant_type=client_credentials" "$PROXY/api/v2/oauth/token" 2>/dev/null \
    | jq -r '.access_token // empty' 2>/dev/null)
  [[ -n $token ]] && break
  [[ $attempt -lt 6 ]] && sleep 30
done

if [[ -z $token ]]; then
  echo "api-tailscale not attached; staying off the tailnet"
  exit 0
fi

# NON-EPHEMERAL, on purpose (2026-09-15). A deployment target is a long-lived
# appliance: an ephemeral node is reaped after a long enough outage, and then
# the only way back is this unit -- which needs api-tailscale attached again.
# That dependency is what kept the integration as a STANDING grant on
# internet-facing VMs (the 2026-07-28 remediation had removed exactly that).
# A persistent node survives reboots and outages with no API access at all, so
# the grant can be time-boxed to the first boot (`integrations attach
# api-tailscale vm:<vm> --for 30m`) and lapse. The cost moves to retirement:
# delete the node explicitly (iv-provision retiring.md section 5), or the next
# VM of the same name joins as <name>-1. The key itself is one-use and expires
# in 10 minutes if unused, so a failed boot leaves nothing behind.
#
# Keep the bearer token out of the process table and off any shell history:
# curl --config reads it from a 0600 file instead of argv.
trap 'rm -f "${auth_config:-}"; unset token key' EXIT
auth_config=$(mktemp)
chmod 600 "$auth_config"
printf 'header = "Authorization: Bearer %s"\n' "$token" > "$auth_config"

mint=$(curl --config "$auth_config" -sL --max-time 30 -X POST \
  "$TS_API/api/v2/tailnet/-/keys" -H "Content-Type: application/json" \
  -d "{\"capabilities\":{\"devices\":{\"create\":{\"reusable\":false,\"ephemeral\":false,\"preauthorized\":true,\"tags\":[\"$TAG\"]}}},\"expirySeconds\":600}" \
  2>/dev/null)
rm -f "$auth_config"
key=$(jq -r '.key // empty' <<<"$mint" 2>/dev/null)

if [[ -z $key ]]; then
  # PRINT WHAT THE API SAID, never a guess about why.
  #
  # This line used to read "check the OAuth client's auth_keys scope". The scope
  # was correct and the real message was
  #
  #   requested tags [tag:dev] are invalid or not permitted
  #
  # which is about tag OWNERSHIP, not scope: an OAuth client is its own identity
  # in Tailscale, so holding a tag is not enough -- tagOwners must list the tag
  # as an owner of ITSELF before a client may apply it. The hardcoded guess sent
  # two people to re-verify a setting that was already right, twice, and cost
  # most of a debugging cycle (2026-08-23). The API had the answer the whole
  # time; the script was throwing it away.
  echo "could not mint a $TAG auth key. Tailscale said:" >&2
  jq -r '.message // "(no message; raw response below)"' <<<"$mint" 2>/dev/null >&2 \
    || printf '%s\n' "$mint" >&2
  echo "hint: if this mentions tags, check tagOwners lists \"$TAG\" as an owner of itself" >&2
  exit 1
fi

# --ssh so the fleet can verify this box; --accept-dns for MagicDNS short names.
tailscale up --ssh --accept-dns --hostname="$(hostname)" --authkey="$key"
tailscale status
