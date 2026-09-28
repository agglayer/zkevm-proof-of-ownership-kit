# Case template

Copy this whole directory to `cases/<your-case-id>/` (e.g. `cases/acme-eth-recovery/`)
before editing anything — leave `cases/_template/` itself untouched so other
stakeholders can copy it too.

## 1. Start the shadow-fork

From the repo root, in its own terminal:

```bash
cd setup
cp .env.example .env   # optional, defaults work out of the box
source .env
./fork.sh
```

Leave it running — everything below connects to it.

## 2. Fill in and run move.sh

Edit `move.sh` in your case directory: replace the TODO addresses and the `cast send`
call with whatever actually moves your locked funds to your destination EOA. See
[`../../recovery-tx/impersonate-and-move.template.sh`](../../recovery-tx/impersonate-and-move.template.sh)
for the annotated template this was copied from.

Then, from the repo root:

```bash
./recovery-tx/run.sh cases/<your-case-id>/move.sh
```

Note the transaction hash it prints — you'll need it for submission.

## 3. Sign the ownership-proof message

For every EOA impersonated in `move.sh`, **and** for your destination EOA, sign the
proof message. Contracts impersonated in `move.sh` have no private key — sign instead
with the EOA(s) that control them on-chain (owner, multisig signers, admin).

Use the exact same `NONCE` for every signature in this case — it's what lets Polygon
match all the signatures to the same submission.

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

## 4. Double-check you didn't miss a signature

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

## 5. Submit

Once `move.sh` ran successfully and `signatures.json` has one entry per impersonated
address plus your destination EOA, follow
[`../../submission/SUBMIT.md`](../../submission/SUBMIT.md).
