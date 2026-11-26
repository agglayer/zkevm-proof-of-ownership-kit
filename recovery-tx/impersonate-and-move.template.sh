#!/bin/bash
# TEMPLATE — copy this file into your case directory (cases/<your-case-id>/move.sh, see
# cases/_template/) and fill in the TODOs below before running it.
#
# Moves the funds locked in a Smart Contract into the zkEVM bridge (bridgeAsset to Ethereum,
# and/or bridgeMessage), against the local shadow-fork started by setup/fork.sh. The bridge can be
# called by the locked contract itself (through its own logic, e.g. an execute function) or by an
# EOA the funds were moved to first. Each BridgeEvent becomes one output of recovery.json
# (recovery-tx/build-recovery.sh), i.e. a bridge exit of the recovery certificate. Every EOA
# impersonated here must submit a signature afterwards, via ownership-proof/, before any
# recovery certificate can be generated. See cases/_template/README.md.
#
# Requires: the Foundry toolchain (for `cast`), and setup/fork.sh already running.
set -euo pipefail

RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"

# TODO: fill in your case's addresses.
LOCKED_CONTRACT="0x0000000000000000000000000000000000dEaD"  # the SC holding the funds
OWNER_ADDRESS="0x0000000000000000000000000000000000dEaD"    # address that must authorize the move — adjust/remove if not applicable to your case
DESTINATION_ADDRESS="0x0000000000000000000000000000000000dEaD"  # where the recovered funds should end up on Ethereum
AMOUNT_WEI="0"                                                   # how much ETH to bridge, in wei
BRIDGE="0x2a3DD3EB832aF982ec71669E178424b10Dca2EDe"             # the zkEVM bridge (do not change)

if ! command -v cast >/dev/null 2>&1; then
    echo "Error: 'cast' not found in \$PATH. Install the Foundry toolchain from https://getfoundry.sh" >&2
    exit 1
fi

echo "Impersonating ${OWNER_ADDRESS} ..."
cast rpc anvil_impersonateAccount "${OWNER_ADDRESS}" --rpc-url "${RPC_URL}" >/dev/null

# TODO: replace this call with whatever moves YOUR locked funds into the bridge. Common
# shapes:
#   - an execute(target, value, data)-style method on the locked contract, callable by its owner
#   - a withdraw to an EOA, then that EOA calls the bridge itself
#   - a multisig needing several impersonated signers to approve/execute (repeat the
#     impersonate + cast send block once per signer)
# The bridge calls the contract can make:
#   bridgeAsset(uint32 destinationNetwork, address destinationAddress, uint256 amount, address token, bool forceUpdateGlobalExitRoot, bytes permitData)
#     destinationNetwork must be 0 (Ethereum); token 0x0...0 for ETH (send amount as value),
#     or the ERC-20 address (the contract must approve the bridge first)
#   bridgeMessage(uint32 destinationNetwork, address destinationAddress, bool forceUpdateGlobalExitRoot, bytes metadata)
#     optionally with ETH as value
# One call = one output in recovery.json; call it as many times as you need.
#
# Example below: the owner calls a hypothetical execute(address,uint256,bytes) on the locked
# contract, which calls bridgeAsset for AMOUNT_WEI of ETH. --unlocked sends the tx unsigned,
# which Anvil accepts from an impersonated account (fork.sh also runs with --auto-impersonate,
# so the anvil_impersonateAccount call above is a belt-and-braces step, not strictly required).
BRIDGE_CALL="$(cast calldata "bridgeAsset(uint32,address,uint256,address,bool,bytes)" \
    0 "${DESTINATION_ADDRESS}" "${AMOUNT_WEI}" 0x0000000000000000000000000000000000000000 true 0x)"
echo "Sending recovery tx from ${OWNER_ADDRESS} ..."
cast send --unlocked --from "${OWNER_ADDRESS}" "${LOCKED_CONTRACT}" \
    "execute(address,uint256,bytes)" "${BRIDGE}" "${AMOUNT_WEI}" "${BRIDGE_CALL}" \
    --rpc-url "${RPC_URL}"

echo
echo "Note the transactionHash printed above — you can build recovery.json from it with"
echo "recovery-tx/build-recovery.sh. Every EOA impersonated above now needs a signature —"
echo "see ownership-proof/ and cases/<your-case-id>/README.md."
