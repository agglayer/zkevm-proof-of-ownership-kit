# Case template

Create your case from the repo root with `cases/new-case.sh <your-case-id>` (e.g.
`cases/new-case.sh acme-eth-recovery`), which copies this whole directory to
`cases/<your-case-id>/` (a plain `cp -r` works too). Edit your copy — leave
`cases/_template/` itself untouched so other stakeholders can copy it too.

## 1. Declare what you recover, then fill in move.sh

First, fill in `recovery.json` in your case directory: the explicit statement of what
you want to recover and where it should end up. Polygon checks the simulation against it.

```json
{
  "locked_contract": "0x...",
  "destination": "0x...",
  "funds": [
    { "token": "native", "amount": "1000000000000000000" },
    { "token": "0x...", "amount": "5000000", "symbol": "USDC" }
  ]
}
```

- `locked_contract` — the Smart Contract holding the funds.
- `destination` — the final wallet (EOA) that receives them; it must sign too (step 2).
- `funds` — one entry per asset: `"native"` or the token's address, and the `amount` in
  base units (wei for ETH) **as a string**. List each token once; add the amounts up.

Check it (from the repo root):

```bash
./recovery-tx/validate-recovery.sh cases/<your-case-id>/recovery.json
```

Then edit `move.sh` in your case directory: replace the TODO addresses and the `cast send`
call with whatever actually moves your locked funds to your destination EOA. See
[`../../recovery-tx/impersonate-and-move.template.sh`](../../recovery-tx/impersonate-and-move.template.sh)
for the annotated template this was copied from.

You don't need to run it yourself: `submission/prepare-submission.sh` (step 4) starts a fresh
shadow-fork and runs `move.sh` on it. If you want to try it first, start a fork in its own
terminal (`cd setup && cp .env.example .env && source .env && ./fork.sh`, see the repo README),
leave it running and, from the repo root:

```bash
./recovery-tx/run.sh cases/<your-case-id>/move.sh
```

Stop that fork before step 4 (Ctrl-C in its terminal, or `docker rm -f zkevm-shadow-fork-8545`):
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

If you ran it, note the transaction hash it prints — you can use it in step 3.

## 2. Sign the ownership-proof message

For every EOA impersonated in `move.sh`, **and** for your destination EOA, sign the
proof message. Contracts impersonated in `move.sh` have no private key — sign instead
with the EOA(s) that control them on-chain (owner, multisig signers, admin).

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
ADDRESS=0x... NONCE=<same-nonce> ./ownership-proof/sign-message.sh --print-message
```

Paste the message verbatim (don't retype it), publish the signature, and add an entry
to `signatures.json` with that exact message and the signature hash Etherscan shows.
Keep the Etherscan link for your submission.

`signatures.json` in this directory ends up with one entry per address:

```json
[
  {
    "address": "0x...",
    "message": "I confirm ownership of 0x... for zkEVM fund recovery — nonce: ... — date: ...",
    "signature": "0x..."
  }
]
```

## 3. (Optional) Double-check you didn't miss a signature

From the repo root, pass every tx hash `move.sh` printed:

```bash
./recovery-tx/list-impersonated.sh --signatures cases/<your-case-id>/signatures.json <tx-hash> [<tx-hash> ...]
```

This reads each transaction's mined receipt to find who actually sent it, verifies
every signature in `signatures.json` (via `ownership-proof/verify-signature.sh`, the same
check Polygon runs on your submission), and fails loudly if any entry is invalid or any
EOA sender is still missing. Contract senders are listed separately, as a reminder to
cover them with their controlling EOAs' signatures. It only checks senders, though —
it can't know about your destination EOA (it never sends anything), so that signature
is still on you to remember.

## 4. Package and submit

`submission/prepare-submission.sh` does the checks of steps 1 to 3 for you, guides you through what is missing and packages the result. It starts a
**fresh fork** itself (with `setup/fork.sh`, using the same `L2_RPC_URL`... settings; `source setup/.env`
first if you use one) and stops it when it ends, so stop any fork you have running on the
same port before. Run, from the repo root:

```bash
./submission/prepare-submission.sh cases/<your-case-id>
```

It validates `recovery.json`, runs `move.sh`, checks that the funds declared in
`recovery.json` really moved from the locked contract to your destination, works out
which EOAs were impersonated, checks that `signatures.json` (filled in beforehand, step 2) has a valid signature for each of them and for the
destination, writes `cases/<your-case-id>/<your-case-id>-<timestamp>.tgz` and tells you
where to send it and how to verify it. It never
signs: if a signature is missing it stops and prints the exact command to make it; sign,
run it again. (The scripts in `submission/helpers/` are the steps it runs; you don't need to call them.)

Then follow [`../../submission/SUBMIT.md`](../../submission/SUBMIT.md) and email the
`.tgz` to [`zkevm-claims@polygon.technology`](mailto:zkevm-claims@polygon.technology).
