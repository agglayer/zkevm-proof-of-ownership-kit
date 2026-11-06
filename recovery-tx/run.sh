#!/bin/bash
# Runs a case's move.sh (copied and filled in from impersonate-and-move.template.sh)
# against the local shadow-fork started by setup/fork.sh — inside a sandbox container.
#
# The sandbox is a Docker container made from the Foundry image (bash, cast, forge) plus jq
# and curl, and nothing else, that can only talk to the fork:
#   - it sits on a throwaway Docker network created with --internal (no route to the internet
#     or to your machine) and reaches the fork only through an RPC allowlist proxy
#     (sandbox/rpc-proxy.py, another container on that network, named "anvil": the script's
#     RPC_URL is http://anvil:8545). The proxy forwards eth_*, net_*, web3_*, anvil_impersonateAccount,
#     anvil_stopImpersonating, evm_mine and txpool_* and refuses everything else, so move.sh cannot
#     edit the state directly (anvil_setBalance, anvil_setStorageAt, anvil_setCode...) nor make the
#     fork fetch a URL (anvil_reset): it can only send transactions from impersonated accounts. The
#     fork is attached to a second internal network, shared only with the proxy;
#   - gas is free on the fork (setup/fork.sh; the proxy zeroes the fee fields of the transactions):
#     an impersonated account without ETH can send, so there is no need for anvil_setBalance;
#   - move.sh is mounted read-only as the only file it sees: it must be self-contained (it is
#     also the only case file that goes into the package); the root filesystem is read-only
#     (just a small /tmp), no Linux capabilities, no privilege escalation, and limits on
#     memory, CPUs, processes and run time;
#   - nothing of yours is passed in: no environment, no keys, no home directory.
# So move.sh must reach the fork through "${RPC_URL}" (the template does) and may only use
# bash, the Foundry tools (cast, forge, anvil), jq, curl and the basic Linux utilities.
#
# The image is built from recovery-tx/sandbox/Dockerfile the first time (needs internet then,
# for apt) and tagged with a hash of the Dockerfile and the base image, so it is rebuilt only
# when either changes.
#
# Requires: docker (daemon running), curl. The fork must be the container started by
# setup/fork.sh (named zkevm-shadow-fork-<port>), reachable at RPC_URL on this machine.
#
# Usage: recovery-tx/run.sh cases/<your-case-id>/move.sh
#
# Env overrides:
#   RPC_URL          the fork's JSON-RPC as seen from this machine (default http://127.0.0.1:8545)
#   SANDBOX_IMAGE    use this image as the sandbox instead of building the one above (it needs
#                    bash, curl, python3 (it also runs the proxy) and whatever your move.sh uses)
#   ANVIL_IMAGE      Foundry image the sandbox image is built from (default ghcr.io/foundry-rs/foundry:v1.5.1)
#   SANDBOX_TIMEOUT  seconds before the script is killed (default 600)
#   SANDBOX_MEMORY   memory limit (default 512m)
set -euo pipefail

script_path="${1:?Usage: recovery-tx/run.sh <path-to-move.sh>}"
RPC_URL="${RPC_URL:-http://127.0.0.1:8545}"
SANDBOX_IMAGE="${SANDBOX_IMAGE:-}"
FOUNDRY_IMAGE="${ANVIL_IMAGE:-ghcr.io/foundry-rs/foundry:v1.5.1}"
SANDBOX_TIMEOUT="${SANDBOX_TIMEOUT:-600}"
SANDBOX_MEMORY="${SANDBOX_MEMORY:-512m}"

for bin in docker curl; do
    if ! command -v "${bin}" >/dev/null 2>&1; then
        echo "Error: '${bin}' not found in \$PATH." >&2
        [ "${bin}" = "docker" ] && echo "Install Docker from https://docs.docker.com/get-docker/" >&2
        exit 1
    fi
done
if ! docker info >/dev/null 2>&1; then
    echo "Error: docker is installed but its daemon is not reachable." >&2
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

# A Bash regex (BSD sed on stock macOS does not support \| in basic regular expressions).
fork_port=""
rpc_re='^http://(127\.0\.0\.1|localhost):([0-9]{1,5})/?$'
if [[ "${RPC_URL}" =~ ${rpc_re} ]]; then
    fork_port="${BASH_REMATCH[2]}"
fi
if [ -z "${fork_port}" ]; then
    echo "Error: RPC_URL must be http://127.0.0.1:<port> (the fork on this machine); it is ${RPC_URL}." >&2
    exit 1
fi
fork_container="zkevm-shadow-fork-${fork_port}"
if ! docker inspect -f '{{.State.Running}}' "${fork_container}" 2>/dev/null | grep -qx true; then
    echo "Error: the container ${fork_container} is not running. The sandbox attaches to the fork started by setup/fork.sh (ANVIL_PORT=${fork_port})." >&2
    exit 1
fi

sandbox_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sandbox"
# The sandbox image: built once from recovery-tx/sandbox/Dockerfile, tagged by a hash of it.
if [ -z "${SANDBOX_IMAGE}" ]; then
    if command -v sha256sum >/dev/null 2>&1; then
        image_hash="$(cat "${sandbox_dir}/Dockerfile" <(printf '%s' "${FOUNDRY_IMAGE}") | sha256sum | cut -c1-12)"
    else
        image_hash="$(cat "${sandbox_dir}/Dockerfile" <(printf '%s' "${FOUNDRY_IMAGE}") | shasum -a 256 | cut -c1-12)"
    fi
    SANDBOX_IMAGE="zkevm-kit-sandbox:${image_hash}"
    if ! docker image inspect "${SANDBOX_IMAGE}" >/dev/null 2>&1; then
        echo "Building the sandbox image ${SANDBOX_IMAGE} (first run only; needs internet) ..." >&2
        docker build -q --build-arg "FOUNDRY_IMAGE=${FOUNDRY_IMAGE}" -t "${SANDBOX_IMAGE}" "${sandbox_dir}" >/dev/null \
            || { echo "Error: could not build the sandbox image from ${sandbox_dir}/Dockerfile." >&2; exit 1; }
    fi
fi

suffix="${fork_port}-$$"
net_a="zkevm-sandbox-a-${suffix}"   # move.sh <-> proxy
net_b="zkevm-sandbox-b-${suffix}"   # proxy <-> fork
sandbox="zkevm-sandbox-run-${suffix}"
proxy="zkevm-sandbox-proxy-${suffix}"
work_dir="$(mktemp -d)"
nets_created=0
attached=0

# shellcheck disable=SC2329  # invoked by the EXIT trap below
cleanup() {
    local rc=$?
    set +e
    docker rm -f "${sandbox}" "${proxy}" >/dev/null 2>&1
    [ "${attached}" -eq 0 ] || docker network disconnect -f "${net_b}" "${fork_container}" >/dev/null 2>&1
    [ "${nets_created}" -eq 0 ] || docker network rm "${net_a}" "${net_b}" >/dev/null 2>&1
    rm -rf "${work_dir}"
    return "${rc}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# The files are copied to a directory the container's user can read, whatever the permissions
# of the originals.
mkdir -p "${work_dir}/sandbox" "${work_dir}/proxy"
cp "${script_path}" "${work_dir}/sandbox/move.sh"
cp "${sandbox_dir}/rpc-proxy.py" "${work_dir}/proxy/rpc-proxy.py"
chmod 755 "${work_dir}" "${work_dir}/sandbox" "${work_dir}/proxy"
chmod 644 "${work_dir}/sandbox/move.sh" "${work_dir}/proxy/rpc-proxy.py"

# Both networks are --internal (no route out). The fork is attached to net_b only for the proxy.
docker network create --internal "${net_a}" >/dev/null
docker network create --internal "${net_b}" >/dev/null
nets_created=1
docker network connect --alias anvil-real "${net_b}" "${fork_container}" >/dev/null
attached=1

# The proxy: reachable from the sandbox as "anvil", forwards only an allowlist of JSON-RPC methods
# to the fork (see rpc-proxy.py: no anvil_setBalance / setStorageAt / setCode / reset, ...).
docker run -d --name "${proxy}" --network "${net_a}" --network-alias anvil \
    --read-only --tmpfs /tmp:rw,nosuid,size=16m \
    --cap-drop ALL --security-opt no-new-privileges --pids-limit 64 --memory 128m --cpus 1 \
    -e HOME=/tmp -e UPSTREAM=http://anvil-real:8545 \
    -v "${work_dir}/proxy:/proxy:ro" \
    --entrypoint python3 "${SANDBOX_IMAGE}" /proxy/rpc-proxy.py >/dev/null
docker network connect "${net_b}" "${proxy}" >/dev/null
proxy_wait=0
until docker exec "${proxy}" curl -s -m 2 -X POST localhost:8545 -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}' 2>/dev/null | grep -q '"result"'; do
    proxy_wait=$((proxy_wait + 1))
    if [ "${proxy_wait}" -ge 30 ]; then
        docker logs "${proxy}" >&2 2>&1 || true
        echo "Error: the sandbox's RPC proxy did not come up." >&2
        exit 1
    fi
    sleep 1
done

# The fork's head is still the real block, with its real base fee: mine the first block of the
# fork (base fee 0, see setup/fork.sh) so that gas estimation gives 0 and an account without ETH
# can send.
docker exec "${proxy}" curl -s -m 10 -X POST localhost:8545 -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"evm_mine","params":[],"id":1}' >/dev/null || true

echo "Running ${script_path} in a sandbox (${SANDBOX_IMAGE}; network: only the fork, through an RPC allowlist)." >&2
# The container's stdout/stderr are move.sh's own: callers read the tx receipt from them.
# --entrypoint bash: the image's entrypoint is not used. HOME and /tmp are a small tmpfs.
docker run --rm --name "${sandbox}" \
    --network "${net_a}" \
    --read-only --tmpfs /tmp:rw,nosuid,size=64m \
    --cap-drop ALL --security-opt no-new-privileges \
    --pids-limit 256 --memory "${SANDBOX_MEMORY}" --cpus 1 \
    -e HOME=/tmp -e RPC_URL=http://anvil:8545 -e ETH_RPC_URL=http://anvil:8545 \
    -v "${work_dir}/sandbox:/sandbox:ro" -w /tmp \
    --entrypoint bash "${SANDBOX_IMAGE}" /sandbox/move.sh </dev/null &
run_pid=$!
# Watchdog (no `timeout` on stock macOS): kills the container if it runs too long.
# Its output goes to /dev/null: a leftover `sleep` must not keep the caller's pipe (tee) open.
( exec >/dev/null 2>&1; sleep "${SANDBOX_TIMEOUT}"; touch "${work_dir}/timed_out"; docker rm -f "${sandbox}" ) &
watchdog_pid=$!
set +e
wait "${run_pid}"
run_rc=$?
set -e
pkill -P "${watchdog_pid}" 2>/dev/null || true
kill "${watchdog_pid}" 2>/dev/null || true
wait "${watchdog_pid}" 2>/dev/null || true
if [ -f "${work_dir}/timed_out" ]; then
    echo "Error: move.sh was killed after ${SANDBOX_TIMEOUT}s (SANDBOX_TIMEOUT)." >&2
    exit 124
fi
exit "${run_rc}"
