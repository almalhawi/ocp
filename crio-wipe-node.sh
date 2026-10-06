#!/usr/bin/env bash
# Wipe CRI-O ephemeral storage on one node (OCP docs 7.3.4 "Cleaning CRI-O storage").
#
# Author: Nasser Almalhawi <almalhawi.nasser@gmail.com>
#
# Run with --help for usage.
#
# Default transport is `oc debug`, which cannot survive the procedure itself (the
# debug pod is removed by `crictl rmp -fa`), so the on-node steps are handed to the
# host's systemd as a transient unit and run detached from the debug pod.
# kubelet is usually down for less than the ~40s it takes the node to show NotReady,
# so completion is judged by the unit's result, not by a NotReady->Ready transition.
#
# WARNING: this deletes every cached image on the node. If the internal registry
# has lost images, the node cache may be the only remaining copy.
set -euo pipefail

THRESHOLD=65

usage() {
  cat <<EOF
Usage: ${0##*/} [-y] [--ssh] [node_name]

Wipe CRI-O storage on a node: cordon, drain (--force), stop kubelet, remove pods,
stop crio, crio wipe -f, start crio and kubelet, wait for Ready, uncordon.

  node_name   node to clean; omit to list nodes whose /var is over ${THRESHOLD}% full
              and pick one
  -y          skip the confirmation prompt
  --ssh       run the on-node steps over SSH (core@<node>) instead of oc debug;
              use when crio is too broken for 'oc debug node/' to work
  -h, --help  show this help

WARNING: deletes every cached image on the node, and the --force drain deletes
pods that have no controller. If the wipe fails, the node is left cordoned.
EOF
}

# Print "<pct>%  (<used>G / <capacity>G)" for /var on node $1. node.fs in the kubelet
# stats summary is the filesystem holding /var/lib/kubelet, i.e. /var. Percentage is
# computed the way df does (used / (used + avail), rounded up).
var_usage() {
  oc get --raw "/api/v1/nodes/$1/proxy/stats/summary" 2>/dev/null | jq -er '.node.fs
    | (.usedBytes + .availableBytes) as $tot
    | "\((.usedBytes * 100 + $tot - 1) / $tot | floor)%  (\(.usedBytes / 1e9 | floor)G / \(.capacityBytes / 1e9 | floor)G)"'
}

YES=0; USE_SSH=0; NODE=""
for arg in "$@"; do
  case "$arg" in
    -y) YES=1 ;;
    --ssh) USE_SSH=1 ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $arg" >&2; usage >&2; exit 2 ;;
    *) NODE="$arg" ;;
  esac
done
if [[ -z "$NODE" ]]; then
  echo "==> Nodes with /var over ${THRESHOLD}%"
  CANDIDATES=()
  for n in $(oc get nodes -o name | cut -d/ -f2); do
    if ! usage=$(var_usage "$n"); then
      echo "    warning: no stats from $n (NotReady?)" >&2
      continue
    fi
    if (( ${usage%%%*} > THRESHOLD )); then CANDIDATES+=("$n  $usage"); fi
  done
  (( ${#CANDIDATES[@]} )) || { echo "    none"; exit 0; }
  PS3="Select node to clean (Ctrl-D to abort): "
  select choice in "${CANDIDATES[@]}"; do
    [[ -n "$choice" ]] && break
  done
  [[ -n "${choice:-}" ]] || exit 1
  NODE="${choice%% *}"
fi
oc get node "$NODE" >/dev/null

UNIT="crio-wipe-$(date +%s)"
REMOTE='set -x
systemctl stop kubelet
for pod in $(crictl pods -q); do
  if [[ "$(crictl inspectp $pod | jq -r .status.linux.namespaces.options.network)" != "NODE" ]]; then
    crictl rmp -f $pod
  fi
done
crictl rmp -fa
systemctl stop crio
crio wipe -f
systemctl start crio
systemctl start kubelet'

if (( ! YES )); then
  read -rp "Cordon, drain and WIPE ALL CRI-O STORAGE on $NODE? [y/N] " ans
  [[ "$ans" == [yY] ]] || exit 1
fi

BEFORE=$(var_usage "$NODE") || BEFORE="unavailable"

echo "==> Cordon and drain $NODE"
oc adm cordon "$NODE"
oc adm drain "$NODE" --ignore-daemonsets --delete-emptydir-data --force

echo "==> Stopping kubelet/crio, removing pods, wiping storage on $NODE"
if (( USE_SSH )); then
  ssh "core@$NODE" sudo bash -s <<<"$REMOTE"
else
  # If the debug pod still exists when kubelet restarts, kubelet finds no container for
  # it (crio was wiped) and runs this command again -- so only start the unit if it
  # doesn't exist yet, otherwise the wipe would run twice.
  oc debug "node/$NODE" -q -- chroot /host bash -c \
    '[[ $(systemctl show -p LoadState --value "$1") == not-found ]] || exit 0
     exec systemd-run --unit="$1" -p RemainAfterExit=yes bash -c "$2"' _ "$UNIT" "$REMOTE" \
    || echo "    oc debug exited non-zero; checking the unit anyway"
  echo "    running as systemd unit $UNIT on the node (journalctl -u $UNIT)"
  # oc debug fails while crio is down, so keep retrying until the unit has exited.
  echo "==> Waiting for $UNIT to finish"
  state=""
  for (( i = 0; i < 90; i++ )); do
    state=$(oc debug "node/$NODE" -q -- chroot /host \
      systemctl show "$UNIT" -p LoadState -p SubState -p Result 2>/dev/null | sort | paste -sd' ') || state=""
    [[ "$state" == *LoadState=not-found* || "$state" == *SubState=exited* || "$state" == *SubState=failed* ]] && break
    sleep 10
  done
  if [[ "$state" != "LoadState=loaded Result=success SubState=exited" ]]; then
    echo "!! $UNIT did not succeed (${state:-no response from node}) -- leaving $NODE cordoned." >&2
    echo "   oc debug node/$NODE -- chroot /host journalctl -u $UNIT" >&2
    exit 1
  fi
  oc debug "node/$NODE" -q -- chroot /host systemctl stop "$UNIT"
fi

echo "==> Waiting for $NODE to become Ready"
oc wait --for=condition=Ready "node/$NODE" --timeout=15m

echo "==> Uncordon $NODE"
oc adm uncordon "$NODE"
oc get node "$NODE"

# The kubelet stats endpoint can take a moment to answer after the restart.
AFTER="unavailable"
for (( i = 0; i < 12; i++ )); do
  AFTER=$(var_usage "$NODE") && break
  AFTER="unavailable"; sleep 5
done
echo "==> /var on $NODE"
echo "    before: $BEFORE"
echo "    after:  $AFTER"
