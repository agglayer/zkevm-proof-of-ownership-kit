#!/usr/bin/env python3
"""JSON-RPC allowlist proxy between the move.sh sandbox and the shadow-fork (Anvil).

Why: Anvil exposes "cheat" methods (anvil_setBalance, anvil_setStorageAt, anvil_setCode,
anvil_reset, evm_snapshot/evm_revert, ...). A move.sh that can call them can edit the state
directly instead of sending transactions, so the balance checks would pass without any
impersonated account authorising anything; anvil_reset can also make the fork container (which
does have internet access) fetch an arbitrary URL. So the sandbox only reaches the fork through
this proxy, which forwards a fixed set of methods and refuses everything else.

Allowed: eth_*, net_*, web3_*, anvil_impersonateAccount, anvil_stopImpersonating, evm_mine,
txpool_status, txpool_content.

One thing is adjusted: gas is free on the fork (see setup/fork.sh), so the fee fields of the
transactions sent with eth_sendTransaction / eth_sendUnsignedTransaction (gasPrice, maxFeePerGas,
maxPriorityFeePerGas) are set to 0, whatever the client estimated. Otherwise a plain `cast send`
from an impersonated account that holds no ETH would be refused for lack of funds, and move.sh
would need anvil_setBalance, which is not allowed.

Standard library only (it runs in the sandbox image next to bash/cast).
Environment: UPSTREAM (the fork's JSON-RPC URL), LISTEN_PORT (default 8545).
"""
import json
import os
import sys
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ["UPSTREAM"]
LISTEN_PORT = int(os.environ.get("LISTEN_PORT", "8545"))
ALLOWED_PREFIXES = ("eth_", "net_", "web3_")
ALLOWED_METHODS = {
    "anvil_impersonateAccount",
    "anvil_stopImpersonating",
    "evm_mine",
    "txpool_status",
    "txpool_content",
}
MAX_BODY = 4 * 1024 * 1024
UPSTREAM_TIMEOUT = 300


def allowed(method):
    return isinstance(method, str) and (method in ALLOWED_METHODS or method.startswith(ALLOWED_PREFIXES))


def error(req_id, message):
    return {"jsonrpc": "2.0", "id": req_id, "error": {"code": -32601, "message": message}}


def forward(request):
    data = json.dumps(request).encode()
    req = urllib.request.Request(UPSTREAM, data=data, headers={"Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=UPSTREAM_TIMEOUT) as resp:
        return json.loads(resp.read())


FEE_FIELDS = ("gasPrice", "maxFeePerGas", "maxPriorityFeePerGas")


def zero_fees(request):
    params = request.get("params")
    if isinstance(params, list) and params and isinstance(params[0], dict):
        for field in FEE_FIELDS:
            if field in params[0]:
                params[0][field] = "0x0"


def handle_one(request):
    if not isinstance(request, dict):
        return error(None, "invalid request")
    method = request.get("method")
    if not allowed(method):
        print("denied: %s" % method, file=sys.stderr, flush=True)
        return error(request.get("id"), "method not allowed in the sandbox: %s" % method)
    try:
        if method in ("eth_sendTransaction", "eth_sendUnsignedTransaction"):
            zero_fees(request)
        return forward(request)
    except Exception as exc:  # upstream down, timeout, bad JSON...
        return error(request.get("id"), "fork error: %s" % exc)


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_BODY:
                raise ValueError("bad length")
            body = json.loads(self.rfile.read(length))
        except Exception:
            self.send_error(400, "bad request")
            return
        if isinstance(body, list):
            result = [handle_one(item) for item in body]
        else:
            result = handle_one(body)
        payload = json.dumps(result).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self):
        self.send_error(405, "POST JSON-RPC only")

    def log_message(self, *args):  # quiet: denials are printed above
        pass


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", LISTEN_PORT), Handler).serve_forever()
