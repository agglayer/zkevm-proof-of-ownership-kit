#!/bin/bash
# Spins up an Anvil shadow-fork of Polygon zkEVM mainnet, pinned to the exact block the
# chain halted at, after confirming that block is indeed the network's latest published
# block (i.e. nothing has been produced since — you are forking the real halt state,
# not an arbitrary block).
#
# Requires: docker (with its daemon running), curl, jq. Anvil itself runs from the official
# Foundry image, so it does not need to be installed. The rest of the kit does need `cast`
# (Foundry toolchain, https://getfoundry.sh); this script only warns if it is missing.
#
# Env overrides (see .env.example):
#   L2_RPC_URL   L2 JSON-RPC endpoint to fork from (default: public zkEVM mainnet RPC)
#   ANVIL_PORT   Local port Anvil listens on (default: 8545)
#   BLOCK_TIME   Anvil --block-time in seconds (default: 2)
#   ANVIL_IMAGE  Foundry Docker image Anvil runs from (default: ghcr.io/foundry-rs/foundry:v1.5.1)
#   FORK_LOG     File the full output (this script's and Anvil's) is saved to, on top of
#                being shown on screen (default: fork.log next to this script). It is
#                overwritten on every start. Submit it with your case.
#   FORK_BLOCK   FOR TESTING ONLY. Block to fork at (default: the network's halt block,
#                33391890). It must still equal the RPC's latest block, so point
#                L2_RPC_URL at a test node whose head is that block. A non-default value
#                is flagged with a warning in the output, so it is visible in fork.log.
set -euo pipefail

L2_RPC_URL="${L2_RPC_URL:-https://zkevm-rpc.com/}"
ANVIL_PORT="${ANVIL_PORT:-8545}"
BLOCK_TIME="${BLOCK_TIME:-2}"
ANVIL_IMAGE="${ANVIL_IMAGE:-ghcr.io/foundry-rs/foundry:v1.5.1}"
FORK_LOG="${FORK_LOG:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fork.log}"

# The network's halt block. Only override it (FORK_BLOCK) for tests. Whatever the value, it's
# re-verified against the RPC below on every run — the script refuses to start if it doesn't
# match, rather than silently forking the wrong state.
halt_block=33391890
fork_block="${FORK_BLOCK:-${halt_block}}"
if ! [[ "${fork_block}" =~ ^[0-9]{1,16}$ ]]; then
    echo "Error: FORK_BLOCK must be a decimal block number, got: ${fork_block}" >&2
    exit 1
fi

missing=""
for bin in docker curl jq; do
    command -v "$bin" >/dev/null 2>&1 || missing="${missing} ${bin}"
done
if [ -n "${missing}" ]; then
    echo "Error: missing required tool(s):${missing}" >&2
    case "${missing}" in *docker*) echo "  docker: install Docker from https://docs.docker.com/get-docker/" >&2 ;; esac
    case "${missing}" in *curl*) echo "  curl:   install it with your package manager (apt, brew, ...)" >&2 ;; esac
    case "${missing}" in *jq*) echo "  jq:     install it with your package manager (apt, brew, ...)" >&2 ;; esac
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    echo "Error: docker is installed but its daemon is not reachable." >&2
    echo "Start Docker (e.g. open Docker Desktop) and check that your user may run 'docker'." >&2
    exit 1
fi
if ! command -v cast >/dev/null 2>&1; then
    echo "Warning: 'cast' not found. It is not needed to start the fork, but the next steps are (install the Foundry toolchain from https://getfoundry.sh)." >&2
fi

# Anvil runs inside a container, where 127.0.0.1/localhost is the container itself: an RPC
# served on this machine (e.g. a test node) is reached through host.docker.internal instead.
fork_url="$(printf '%s' "${L2_RPC_URL}" | sed -e 's#^\([a-zA-Z]*://\)localhost\([:/]\)#\1host.docker.internal\2#' -e 's#^\([a-zA-Z]*://\)127\.0\.0\.1\([:/]\)#\1host.docker.internal\2#')"

# From here on everything printed (this script and Anvil) goes to the screen and to
# FORK_LOG. The RPC URL may carry an API key, so every occurrence of it is replaced by a
# masked copy (path and query string hidden) before it reaches either. `tee -i` ignores
# Ctrl-C so the log is complete; it ends by itself when Anvil closes the pipe.
masked_url="$(printf '%s' "${L2_RPC_URL}" | sed -e 's/?.*$/?***/' -e 's#^\([a-zA-Z]*://[^/]*\)/..*$#\1/***#')"
mask_secrets() {
    local line
    while IFS= read -r line || [ -n "${line}" ]; do
        line="${line//"${L2_RPC_URL}"/${masked_url}}"
        printf '%s\n' "${line//"${fork_url}"/${masked_url}}"
    done
}
exec > >(mask_secrets | tee -i "${FORK_LOG}") 2>&1
echo "Saving the full output to ${FORK_LOG}"
if [ "${fork_block}" -ne "${halt_block}" ]; then
    echo "WARNING: FORK_BLOCK=${fork_block} overrides the halt block (${halt_block}). Testing only: a submission built on this fork will not be accepted."
fi

echo "Fetching latest block from ${masked_url} ..."
hex_block="$(curl -sS -X POST "${L2_RPC_URL}" \
    -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | jq -r '.result')"

if [ -z "${hex_block}" ] || [ "${hex_block}" = "null" ]; then
    echo "Error: could not fetch eth_blockNumber from ${L2_RPC_URL}" >&2
    exit 1
fi
if ! [[ "${hex_block}" =~ ^0x[0-9a-fA-F]{1,16}$ ]]; then
    echo "Error: eth_blockNumber from ${L2_RPC_URL} is not a hex quantity: ${hex_block}" >&2
    exit 1
fi

latest_block="$((16#${hex_block#0x}))"
echo "Latest published block on the network: ${latest_block} (${hex_block})"

if [ "${fork_block}" -ne "${latest_block}" ]; then
    echo "Error: fork_block (${fork_block}) does not match the network's latest block (${latest_block})." >&2
    echo "This usually means the RPC endpoint is stale or wrong — do not proceed without understanding why." >&2
    exit 1
fi

echo "fork_block matches the network's latest block: ${fork_block}"
echo "Starting Anvil shadow-fork (${ANVIL_IMAGE}) on http://127.0.0.1:${ANVIL_PORT} ..."

# Batch mining via --block-time (auto-mine would produce one block per tx), no block gas
# cap so a single block can hold every pending tx, auto-impersonate so any account can
# send txs without a per-tx anvil_impersonateAccount call, and generous fork-backend
# retries/timeout + no internal rate limiting since every cold storage slot is a
# round-trip to the upstream RPC.
#
# Anvil listens on all interfaces inside the container, but the port is published on this
# machine's loopback only: the fork is unlocked (auto-impersonate), so it must not be
# reachable from the network.
exec docker run --rm --init \
    --name "zkevm-shadow-fork-${ANVIL_PORT}" \
    --add-host host.docker.internal:host-gateway \
    -p "127.0.0.1:${ANVIL_PORT}:8545" \
    --entrypoint anvil \
    "${ANVIL_IMAGE}" \
    --host 0.0.0.0 \
    --port 8545 \
    --fork-url "${fork_url}" \
    --fork-block-number "${fork_block}" \
    --block-time "${BLOCK_TIME}" \
    --disable-block-gas-limit \
    --auto-impersonate \
    --retries 10 \
    --fork-retry-backoff 1000 \
    --timeout 120000 \
    --no-rate-limit
