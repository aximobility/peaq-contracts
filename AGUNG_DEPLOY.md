# AGUNG_DEPLOY.md - zero to first risk attestation

> Step-by-step from a blank `.env` to "first `oracle.attest()` tx confirmed on agung". Intended for the first-ever deploy. Subsequent deploys are 3 commands max.

Wall-clock estimate: **~25 minutes** including funding wait + first verification.

---

## Pre-flight

You need:

- **Foundry** installed (`curl -L https://foundry.paradigm.xyz | bash && foundryup`)
- **Node 20+** + pnpm 9 (only for the platform-side smoke at the end)
- **A funded agung deployer EOA** — generate with `cast wallet new` if you don't have one
- **3-7 EOAs to act as ADMIN, ISSUER(s), ATTESTOR(s), APPROVER(s)** — for the first deploy these can all be the same EOA; production splits them across hardware wallets + a Safe multisig
- **Agung gas:** ~0.1 AGNG covers all three deploys + first attestation

Don't have AGNG? Web faucet: `https://docs.peaq.xyz/build/getting-started/get-test-tokens`. 3 AGNG/day per wallet — enough for 5 deploy txs + smoke txs (~0.025 AGNG total).

---

## 1. Generate / fund a deployer EOA

```bash
cast wallet new
# Successfully created new keypair.
# Address: 0x1234...
# Private key: 0xabcd...
```

Copy both. Send the address to the agung faucet. Verify funded:
```bash
cast balance 0xYOUR_DEPLOYER_ADDRESS --rpc-url https://peaq-agung.api.onfinality.io/public
# Expect: ~100000000000000000000 (0.1 AGNG in wei or larger)
```

---

## 2. Clone + install

```bash
git clone https://github.com/aximobility/peaq-contracts
cd peaq-contracts
make install        # forge install OZ + forge-std
make build          # confirm clean build before deploying anything
make test           # 51 tests must pass before you trust the deploy
```

Expected: `51 passed; 0 failed; 0 skipped (51 total tests)`.

---

## 3. Configure .env

```bash
cp .env.example .env
```

Edit `.env`:

```bash
# RPC (default agung public RPC; replace with private RPC for production runs)
PEAQ_RPC_HTTP_AGUNG=https://peaq-agung.api.onfinality.io/public

# Deployer (the EOA from step 1)
DEPLOYER_PRIVATE_KEY=0xabcd...        # private key from cast wallet new

# Roles (all the same address for first-ever deploy; split for prod)
ADMIN=0x1234...                       # your deployer address is fine for first deploy
ISSUERS=0x1234...
ATTESTORS=0x1234...
APPROVERS=0x1234...,0x5678...         # at least 2 distinct addresses required for K-of-M
```

**Important:** APPROVERS must be at least 2 distinct addresses (the deploy script enforces it). For a smoke test, generate a second EOA with `cast wallet new` and put both in.

---

## 4. Dry-run the deploy (no broadcast)

```bash
forge script script/Deploy.s.sol:Deploy --rpc-url agung
```

Expected output:
```
== Logs ==
  === AXI peaq-contracts deployment ===
  CredentialRevocationRegistry impl:  0x...
  CredentialRevocationRegistry proxy: 0x...
  InsuranceRiskOracle impl:           0x...
  InsuranceRiskOracle proxy:          0x...
  HighRiskCommandVault:               0x...
  Admin (DEFAULT_ADMIN_ROLE):         0xYOUR_ADMIN_ADDRESS

If you wish to simulate on-chain transactions pass a private key.
```

If it errors here — fix .env before the next step. **Wrong .env at this step = no on-chain damage.**

---

## 5. Real deploy (broadcasts on-chain)

```bash
make deploy-agung
```

Expected: 3 txs land within ~20 seconds (one per contract, plus 2 proxy deploys → total 5 txs).

The `broadcast/Deploy.s.sol/9990/run-latest.json` file lands with the canonical addresses. Save them:

```bash
jq '.transactions[] | {contractName, contractAddress}' broadcast/Deploy.s.sol/9990/run-latest.json
```

You should see something like:
```json
{"contractName":"CredentialRevocationRegistry","contractAddress":"0xAbc..."}
{"contractName":"ERC1967Proxy","contractAddress":"0xDef..."}        # ← USE THIS as REVOCATION_REGISTRY_ADDRESS
{"contractName":"InsuranceRiskOracle","contractAddress":"0x123..."}
{"contractName":"ERC1967Proxy","contractAddress":"0x456..."}        # ← USE THIS as RISK_ORACLE_ADDRESS
{"contractName":"HighRiskCommandVault","contractAddress":"0x789..."} # ← USE THIS as COMMAND_VAULT_ADDRESS
```

**The PROXY address is what callers use, NOT the implementation.** Note that two of the three contracts are behind proxies (Registry + Oracle); Vault is direct.

---

## 6. Verify the deployment is healthy

Set the addresses you noted:

```bash
export REGISTRY_PROXY=0xDef...
export ORACLE_PROXY=0x456...
export VAULT=0x789...
export ADMIN=0x1234...
make verify-agung
```

Expected:
```
=== Verification ===
Registry totalRevoked: 0
Oracle floor bps:      7000
Oracle ceiling bps:    15000
Vault MIN_EXPIRY:      60
Vault MAX_EXPIRY:      2592000
All contracts healthy at admin: 0x1234...
```

If Verify reverts → admin address mismatch; check `.env`.

---

## 7. Smoke #1 - revoke an arbitrary credential hash

```bash
cast send \
  --rpc-url https://peaq-agung.api.onfinality.io/public \
  --private-key $DEPLOYER_PRIVATE_KEY \
  $REGISTRY_PROXY \
  "revoke(bytes32,bytes32)" \
  0x1111111111111111111111111111111111111111111111111111111111111111 \
  0x000000000000000000000000000000000000000000000000444f4e455f42595f      # hex of "DONE_BY_"
```

Then:
```bash
cast call \
  --rpc-url https://peaq-agung.api.onfinality.io/public \
  $REGISTRY_PROXY \
  "isRevoked(bytes32)(bool)" \
  0x1111111111111111111111111111111111111111111111111111111111111111
# Expect: true
```

---

## 8. Smoke #2 - first risk attestation

The Oracle requires an `anchorRoot` (bytes32). For the smoke we use a placeholder; production will use a real Merkle root from the platform's daily anchor cron.

```bash
cast send \
  --rpc-url https://peaq-agung.api.onfinality.io/public \
  --private-key $DEPLOYER_PRIVATE_KEY \
  $ORACLE_PROXY \
  "attest(bytes32,uint16,bytes32,uint32)" \
  0xaaaa000000000000000000000000000000000000000000000000000000000000 \
  420 \
  0xbbbb000000000000000000000000000000000000000000000000000000000000 \
  1850
```

Expected: tx hash returned + `RiskAttested` event in receipt.

```bash
cast call \
  --rpc-url https://peaq-agung.api.onfinality.io/public \
  $ORACLE_PROXY \
  "riskScore(bytes32)(uint16,uint64)" \
  0xaaaa000000000000000000000000000000000000000000000000000000000000
# Expect: (420, <recent unix timestamp>)

cast call \
  --rpc-url https://peaq-agung.api.onfinality.io/public \
  $ORACLE_PROXY \
  "priceMultiplierBps(bytes32)(uint16)" \
  0xaaaa000000000000000000000000000000000000000000000000000000000000
# Expect: 10360 (= 7000 + (15000-7000) * 420/1000)
```

**Math check:** insurer reading 10360 bps = 1.036× base premium = 3.6% surcharge over base. That's the score-420 vehicle's contractually-enforceable price.

---

## 9. Wire into the platform

In your `aximobility/platform` checkout:

```bash
cd /path/to/platform
cp .env.example .env.production       # if not already present
```

Edit `.env.production`:
```bash
PEAQ_NETWORK=agung
PEAQ_RPC_HTTP=https://peaq-agung.api.onfinality.io/public
PEAQ_EVM_PRIVATE_KEY=0x<the deployer key from step 1>

REVOCATION_REGISTRY_ADDRESS=0x<value from step 5>
RISK_ORACLE_ADDRESS=0x<value from step 5>
COMMAND_VAULT_ADDRESS=0x<value from step 5>
CONTRACT_WRITES_ENABLED=1
```

Then either:
- **Local smoke**: boot mock-convex + run the CLI:
  ```bash
  cd servers/mock-convex && pnpm dev
  # in another terminal:
  axi contracts attest-risk \
    --did 0xaaaa000000000000000000000000000000000000000000000000000000000000 \
    --score 420 \
    --anchor-root 0xbbbb000000000000000000000000000000000000000000000000000000000000 \
    --km 1850
  ```
- **AWS deploy**: hydrate Secrets Manager:
  ```bash
  pnpm tsx scripts/bootstrap-secrets.ts --env-file .env.production --target dev --confirm dev --apply
  ```

---

## 10. Confirm the platform sees the on-chain state

```bash
axi contracts attest-risk \
  --did 0xaaaa... \
  --score 420 \
  --anchor-root 0xbbbb... \
  --km 1850
# Expect:
# ✓ risk.attest | audit=01HVN...
#   txHash: 0x<some 0x64-hex>
```

The platform now mirrors the on-chain state in its `Vehicle` row's `attributes.lastRiskScore`, `lastRiskAttestedAt`, `lastRiskAnchorRoot`, `lastRiskTxHash`. Nightly cron will keep it fresh.

---

## What to do if something goes wrong

| Symptom | Cause | Fix |
|---|---|---|
| `forge script` reverts with "ADMIN must be set" | `.env` ADMIN=0x or empty | Set ADMIN to a real EOA |
| `forge script` reverts with "At least two APPROVERS required" | APPROVERS has only 1 address | Add a second comma-separated EOA |
| Deploy tx hangs forever | RPC overloaded | Switch to a private RPC (alchemy/onfinality paid tier) |
| `verify-agung` reverts with `Registry admin missing` | ADMIN env doesn't match what the deploy used | Re-export the real admin address you used at deploy time |
| `cast send revoke` reverts with `AccessControl` | The deployer EOA was not granted ISSUER_ROLE | Check `.env` ISSUERS includes the deployer address |
| `cast send attest` reverts with `InvalidScore` | Score > 1000 | Score is uint16 in 0..1000 range |
| `cast send attest` reverts with `EmptyAnchorRoot` | Passed bytes32(0) | Use any non-zero bytes32 |
| `axi contracts attest-risk` returns "contracts-bridge-not-initialized" | Platform env missing one of the addresses | Verify all 3 \*\_ADDRESS values are set + non-zero |
| `axi contracts ...` returns "CONTRACT_WRITES_ENABLED is not set" | Safe default | Set `CONTRACT_WRITES_ENABLED=1` in .env / Secrets Manager |

---

## Rollback

If you decide the deploy is wrong (configuration mistake, revealed key, etc.):

1. **Pause everything immediately** (admin only):
   ```bash
   cast send --rpc-url agung --private-key $ADMIN_KEY $REGISTRY_PROXY "pause()"
   cast send --rpc-url agung --private-key $ADMIN_KEY $ORACLE_PROXY "pause()"
   cast send --rpc-url agung --private-key $ADMIN_KEY $VAULT "pause()"
   ```
   Pause blocks all writes; reads keep working.

2. **Revoke compromised role** (e.g. if ISSUER key was leaked):
   ```bash
   cast send --rpc-url agung --private-key $ADMIN_KEY $REGISTRY_PROXY \
     "revokeIssuer(address)" 0xLEAKED_ADDRESS
   ```

3. **Re-deploy with new addresses** — agung deploys are cheap. Just re-run `make deploy-agung` with corrected `.env`. The old contracts can be left paused; nothing reads them anymore once the platform's `*_ADDRESS` env vars point at the new proxies.

4. **For mainnet**: same procedure but pause-then-investigate-then-decide. Don't redeploy on mainnet without an audit-approved delta.

---

## What's next after agung is healthy

| Step | Why |
|---|---|
| Run platform smoke against agung for 1 week | Catches any RPC, throughput, or wiring bug |
| Engage external audit (per `aximobility/platform/AUDIT_PLAN.md`) | Required before mainnet |
| Deploy Safe multisig on peaq mainnet for ADMIN | Required before mainnet |
| Mainnet deploy via `make deploy-mainnet` | After audit acceptance gate |
| Insurer integration: ROAM's insurance partner reads `riskScore()` | Unlocks the $50k-200k/yr per 100-vehicle insurance arbitrage |
