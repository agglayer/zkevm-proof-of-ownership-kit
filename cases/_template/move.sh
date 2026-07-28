#!/bin/bash
# Copied from recovery-tx/impersonate-and-move.template.sh — fill in the TODOs below
# with your case's specific addresses and contract call(s), then run it with:
#
#   ../../recovery-tx/run.sh cases/<your-case-id>/move.sh
#
# (see ../../recovery-tx/impersonate-and-move.template.sh for the annotated original)
set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"

# TODO: fill in your case's addresses.
LOCKED_CONTRACT="0x0000000000000000000000000000000000dEaD"  # the SC holding the funds
OWNER_ADDRESS="0x0000000000000000000000000000000000dEaD"    # address that must authorize the move — adjust/remove if not applicable to your case
DESTINATION_EOA="0x0000000000000000000000000000000000dEaD"  # where the recovered funds should end up

if ! command -v cast >/dev/null 2>&1; then
    echo "Error: 'cast' not found in \$PATH. Install the Foundry toolchain from https://getfoundry.sh" >&2
    exit 1
fi

echo "Impersonating ${OWNER_ADDRESS} ..."
cast rpc anvil_impersonateAccount "${OWNER_ADDRESS}" --rpc-url "${RPC_URL}" >/dev/null

# TODO: replace this call with whatever actually moves the funds for your case. Common
# shapes:
#   - a withdraw()-style method on the locked contract, callable by its owner
#   - an ERC20 transfer() called by the SC or its owner
#   - a multisig needing several impersonated signers to approve/execute (repeat the
#     impersonate + cast send block once per signer)
echo "Sending recovery tx from ${OWNER_ADDRESS} ..."
cast send --unlocked --from "${OWNER_ADDRESS}" "${LOCKED_CONTRACT}" \
    "withdraw(address)" "${DESTINATION_EOA}" \
    --rpc-url "${RPC_URL}"

echo
echo "Note the transactionHash printed above — you'll need it for submission."
echo "Every address impersonated above, plus the destination EOA, now needs a"
echo "signature — see ../../ownership-proof/ and README.md in this directory."
