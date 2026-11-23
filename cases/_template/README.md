# Case template

Create your case from the repo root with `cases/new-case.sh <your-case-id>` (e.g.
`cases/new-case.sh acme-eth-recovery`), which copies this whole directory to
`cases/<your-case-id>/` (a plain `cp -r` works too). Edit your copy — leave
`cases/_template/` itself untouched so other stakeholders can copy it too.

## 1. Fill in move.sh

Edit `move.sh` in your case directory: replace the TODO addresses and the `cast send` call with
whatever **moves your locked funds into the zkEVM bridge** (`0x2a3DD3EB832aF982ec71669E178424b10Dca2EDe`):

- `bridgeAsset` to network `0` (Ethereum) for ETH or a token, to the address that receives it there;
- `bridgeMessage` for a message to another network (it can carry ETH as value).

Each call is one **output** of your recovery: what Polygon recovers through the certificate. Call it
as many times as you need. The bridge can be called by the locked contract itself (through its own
logic, e.g. an `execute` function called by its owner) or by an EOA the funds were moved to first
(e.g. a `withdraw` to the owner, who then calls `bridgeAsset`). See
[`../../recovery-tx/impersonate-and-move.template.sh`](../../recovery-tx/impersonate-and-move.template.sh)
for the annotated template this was copied from.

You don't need to run it yourself: `submission/prepare-submission.sh` (step 2) starts a fresh
shadow-fork and runs `move.sh` on it. If you want to try it first, start a fork in its own
terminal (`cd setup && cp .env.example .env && source .env && ./fork.sh`, see the repo README),
leave it running and, from the repo root:

```bash
./recovery-tx/run.sh cases/<your-case-id>/move.sh
```

Stop that fork before step 2 (Ctrl-C in its terminal, or `docker rm -f zkevm-shadow-fork-8545`):
`prepare-submission.sh` starts its own fresh one on the same port and refuses to run while
something answers there.

`move.sh` runs inside a sandbox container (Docker, the Foundry image plus `jq` and `curl`; built the
first time you run it, which needs internet once): it only sees the fork (at `$RPC_URL`, which the
sandbox sets itself), has no internet and no access to your machine. So it must be
**self-contained** — it is the only case file the sandbox gets — and use `"${RPC_URL}"` as in the
template; it can use `bash`, `cast`/`forge`, `jq`, `curl` and the basic Linux utilities. It can only
**send transactions** from impersonated accounts (`anvil_impersonateAccount`) — the state cheat codes
(`anvil_setBalance`, `anvil_setStorageAt`, `anvil_setCode`, `anvil_reset`...) are refused, so
the result is exactly what the transactions do. Gas is free on the fork: an impersonated account
needs no ETH to send. The same
sandbox is used when Polygon verifies your submission.

If you ran it, note the transaction hashes it prints — you can use them in step 4.

## 2. Generate recovery.json

`recovery.json` is the list of outputs you recover. You don't write it: run, from the repo root,

```bash
./submission/prepare-submission.sh cases/<your-case-id>
```

On a fresh fork, it runs `move.sh` and writes `cases/<your-case-id>/recovery.json` from the bridge
calls it made (then it stops and asks for the signatures of step 3). It looks like:

```json
{
  "version": 1,
  "outputs": [
    {
      "leaf_type": 0,
      "origin_network": 0,
      "origin_address": "0x0000000000000000000000000000000000000000",
      "destination_network": 0,
      "destination_address": "0x...",
      "amount": "1000000000000000000",
      "metadata": "0x",
      "deposit_count": 123456,
      "from_address": "0x...",
      "txn_sender": "0x...",
      "to_address": "0x..."
    },
    {
      "leaf_type": 1,
      "origin_network": 1,
      "origin_address": "0x...",
      "destination_network": 0,
      "destination_address": "0x...",
      "amount": "0",
      "metadata": "0x...",
      "deposit_count": 123457,
      "from_address": "0x...",
      "txn_sender": "0x...",
      "to_address": "0x..."
    }
  ]
}
```

The fields are the ones of the bridge's `BridgeEvent`, with the names aggkit uses:

- `leaf_type` — `0` for a `bridgeAsset`, `1` for a `bridgeMessage`.
- `origin_network`, `origin_address` — for a `bridgeAsset`, the token as the bridge identifies it
  (`0` / `0x000...000` for ETH); for a `bridgeMessage`, the network and address that sent it.
- `destination_network`, `destination_address` — where the output goes (`0` is Ethereum; always `0`
  for a `bridgeAsset`).
- `amount` — in base units (wei for ETH), as a string; for a `bridgeMessage`, the ETH it carries.
- `metadata` — as emitted, not decoded (the message bytes of a `bridgeMessage`).
- `deposit_count` — the bridge's deposit counter for this call.
- `from_address` — who called the bridge; `txn_sender` and `to_address` — the transaction's sender
  and target.

**Check it**: it is what you recover, and what you sign. If it is not what you want, fix `move.sh`,
delete `recovery.json` and run the command again. Without a fork at hand, check the file's format
with `./recovery-tx/validate-recovery.sh cases/<your-case-id>/recovery.json`.

## 3. Sign the ownership-proof message

**Sign last:** the signed message carries a hash of your `recovery.json` and `move.sh`, so a signature
only counts for those exact files. If you change either file afterwards — even a space — every
signature is invalid and you must sign again (empty `signatures.json` with
`echo '[]' > cases/<your-case-id>/signatures.json`, then every address). Read `move.sh` and
`recovery.json` before signing: by signing you approve them.

For every EOA impersonated in `move.sh`, sign the proof message. Contracts impersonated in
`move.sh` have no private key — sign instead with the EOA(s) that control them on-chain (owner,
multisig signers, admin).

Use the exact same `NONCE` for every signature in this case — it's what lets Polygon
match all the signatures to the same submission. The nonce is just a label: any short string
of letters, digits, `-` and `_` (no spaces). To get a unique one:

```bash
export NONCE="$(date -u +%Y%m%d%H%M%S)-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
```

(or run `submission/prepare-submission.sh` with an empty `signatures.json`: it prints the nonce it
would use inside the signing commands). The date in the message is the day you sign, UTC.

**Option A — with this kit (from the repo root).** Pick the signer flag that matches
where the key lives; the key itself is never passed on the command line:

```bash
ADDRESS=0x... NONCE=<pick-one-nonce-and-reuse-it-for-this-case> \
  ./ownership-proof/sign-message.sh cases/<your-case-id>/signatures.json --ledger
# or: --trezor | --account <foundry-keystore-name> | --interactive (hidden key prompt)
```

**Option B — without a terminal (e.g. a hardware wallet in the browser).** Print the
exact message, then sign it at [etherscan.io/verifiedSignatures](https://etherscan.io/verifiedSignatures)
with the wallet that owns the address:

```bash
CASE_DIR=cases/<your-case-id> ADDRESS=0x... NONCE=<same-nonce> ./ownership-proof/sign-message.sh --print-message
```

Paste the message verbatim (don't retype it), publish the signature, and add an entry
to `signatures.json` with that exact message and the signature hash Etherscan shows.
Keep the Etherscan link for your submission.

`signatures.json` in this directory ends up with one entry per address:

```json
[
  {
    "address": "0x...",
    "message": "I confirm ownership of 0x... for zkEVM fund recovery — case hash: ... — nonce: ... — date: ...",
    "signature": "0x..."
  }
]
```

## 4. (Optional) Double-check you didn't miss a signature

From the repo root, pass every tx hash `move.sh` printed:

```bash
./recovery-tx/list-impersonated.sh --signatures cases/<your-case-id>/signatures.json <tx-hash> [<tx-hash> ...]
```

This reads each transaction's mined receipt to find who actually sent it, verifies
every signature in `signatures.json` (via `ownership-proof/verify-signature.sh`, the same
check Polygon runs on your submission), and fails loudly if any entry is invalid or any
EOA sender is still missing. Contract senders are listed separately, as a reminder to
cover them with their controlling EOAs' signatures.

With the same tx hashes, `./recovery-tx/build-recovery.sh <tx-hash> ...` prints the `recovery.json`
they give (it needs the fork they ran on).

## 5. Package and submit

`submission/prepare-submission.sh` does the checks of steps 2 to 4 for you, guides you through what is missing and packages the result. It starts a
**fresh fork** itself (with `setup/fork.sh`, using the same `L2_RPC_URL`... settings; `source setup/.env`
first if you use one) and stops it when it ends, so stop any fork you have running on the
same port before. Run, from the repo root:

```bash
./submission/prepare-submission.sh cases/<your-case-id>
```

It runs `move.sh`, checks that its bridge calls give exactly your `recovery.json` (each called by a
locked contract, not by an impersonated address), works out which EOAs were impersonated, checks
that `signatures.json` (filled in beforehand, step 3) has a valid signature for each of them, writes `cases/<your-case-id>/<your-case-id>-<timestamp>.tgz` and tells you
where to send it and how to verify it. It never
signs: if a signature is missing it stops and prints the exact command to make it; sign,
run it again. (The scripts in `submission/helpers/` are the steps it runs; you don't need to call them.)

Then follow [`../../submission/SUBMIT.md`](../../submission/SUBMIT.md) and email the
`.tgz` to [`zkevm-claims@polygon.technology`](mailto:zkevm-claims@polygon.technology).
