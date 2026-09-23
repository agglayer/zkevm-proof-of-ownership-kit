#!/bin/bash
# Runs a case's move.sh (copied and filled in from impersonate-and-move.template.sh)
# against the local shadow-fork started by setup/fork.sh.
#
# Usage: recovery-tx/run.sh cases/<your-case-id>/move.sh
set -euo pipefail

script_path="${1:?Usage: recovery-tx/run.sh <path-to-move.sh>}"
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"

if ! command -v cast >/dev/null 2>&1; then
    echo "Error: 'cast' not found in \$PATH. Install the Foundry toolchain from https://getfoundry.sh" >&2
    exit 1
fi

if [ ! -f "${script_path}" ]; then
    echo "Error: '${script_path}' not found." >&2
    exit 1
fi

if ! curl -sS -X POST "${RPC_URL}" -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' >/dev/null; then
    echo "Error: could not reach ${RPC_URL} — is setup/fork.sh running?" >&2
    exit 1
fi

RPC_URL="${RPC_URL}" bash "${script_path}"
