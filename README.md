<p align="center">
  <img src="docs/branding/axi-peaq-banner.png" alt="AXI x peaq" width="360">
</p>

<p align="center">
  <img alt="License" src="https://img.shields.io/badge/license-Apache--2.0-blue">
  <img alt="Solidity" src="https://img.shields.io/badge/solidity-0.8.24-363636?logo=solidity">
  <img alt="Foundry" src="https://img.shields.io/badge/built%20with-Foundry-FFCC00">
  <img alt="peaq" src="https://img.shields.io/badge/peaq-mainnet%20%2B%20agung-7B5BFF">
  <img alt="OpenZeppelin v5" src="https://img.shields.io/badge/OpenZeppelin-v5-4E5EE4">
  <img alt="Tests" src="https://img.shields.io/badge/tests-57%20passing-brightgreen">
</p>

# peaq-contracts

Three smart contracts on the peaq blockchain that take AXI Mobility out of the way when somebody else needs to verify our work.

The off-chain code that calls these contracts lives in [`peaq-integration`](https://github.com/aximobility/peaq-integration).

---

## Why these exist

We run a fleet platform. Customers (insurers, regulators, lenders) often need to check facts about our fleet without trusting us to tell the truth. These three contracts let them check directly, on a public chain.

| Contract | What it answers | Who reads it |
|---|---|---|
| **CredentialRevocationRegistry** | "Has this license / inspection / insurance been revoked?" | Roadside inspectors, insurance underwriters, fleet partners |
| **InsuranceRiskOracle** | "What's the latest risk score for this vehicle or driver?" | Insurance underwriters before quoting premiums |
| **HighRiskCommandVault** | "Did multiple authorised people approve this fleet-wide action before it ran?" | Auditors, regulators, our own customers |

If we vanish tomorrow, these contracts keep working. The data stays verifiable.

---

## What's deployed

| Contract | Type | Network | Why this design |
|---|---|---|---|
| `CredentialRevocationRegistry` | Upgradeable (UUPS) | peaq EVM | Bug fixes happen; the storage layout doesn't |
| `InsuranceRiskOracle` | Upgradeable (UUPS) | peaq EVM | The score formula calibrates over time |
| `HighRiskCommandVault` | Permanent (not upgradeable) | peaq EVM | An upgradeable approval gate isn't an approval gate |

All three live on **chain ID 3338 (mainnet)** when promoted, **9990 (Agung testnet)** today.

---

## Try it

You need [Foundry](https://book.getfoundry.sh) and a funded Agung wallet. (Need test tokens? Use the Agung faucet form on [docs.peaq.xyz](https://docs.peaq.xyz/peaqchain/build/getting-started/get-test-tokens) — 3 AGNG per wallet per day.)

```bash
git clone https://github.com/aximobility/peaq-contracts
cd peaq-contracts
make install        # Pull OpenZeppelin and forge-std
make build
make test           # 57 tests across the three contracts
```

Deploy to Agung:

```bash
cp .env.example .env    # Fill in your keys + role addresses
make deploy-agung
make verify-agung       # Confirms all roles set correctly post-deploy
```

Step-by-step deploy walkthrough: [`AGUNG_DEPLOY.md`](AGUNG_DEPLOY.md).

---

## How each contract works

### CredentialRevocationRegistry — revoke a credential, anyone can verify

Every credential we issue (driver license, NTSA inspection, insurance binder, tracker assignment) gets hashed. We store the hash off-chain. When a credential gets revoked, we record the hash on-chain with a reason code.

```solidity
// AXI revokes
revoke(0xabcd...1234, REASON_EXPIRED);

// Anyone reads
isRevoked(0xabcd...1234);          // → true
whyRevoked(0xabcd...1234);         // → (timestamp, revoker, REASON_EXPIRED)
```

Rules:
- Any address holding `ISSUER_ROLE` can revoke any credential hash — the contract does not scope revocation to the original issuer. The role set is the trust boundary: `DEFAULT_ADMIN_ROLE` (the 4-of-7 multisig) grants and revokes issuers, and is the only role that can `unrevoke`.
- Re-revoking is rejected so the original reason code stays intact.
- One transaction can revoke up to 100 credentials at once (handy when an issuer's key gets rotated).
- The contract has a kill switch (`pause()`) for incidents.

### InsuranceRiskOracle — publish a risk score, anyone uses it

Once a month (or after a triggering event), we compute a risk score for each vehicle from telemetry, driver behaviour, and maintenance history. The score lives on-chain alongside a Merkle root that proves it came from real data.

```solidity
// AXI publishes
attest(
  vehicleDid:  0xroamBike117P,
  score:       720,                  // 0..1000, lower = safer
  anchorRoot:  0x...,                // points to the daily Merkle root
  sampleSize:  4_200                 // km of data behind this score
);

// Insurance underwriter reads
(score, lastUpdated) = riskScore(vehicleDid:  0xroamBike117P);
multiplierBps        = priceMultiplierBps(vehicleDid:  0xroamBike117P);
// → 720 → multiplier 0.92x → 8% premium discount
```

Rules:
- Scores expire after 7 days unless re-attested. No stale data being used to price stale risk.
- Every attestation is kept (you can read score history, not just the latest).
- The score-to-premium curve is recalibratable without redeploying — calibrators tune the floor and ceiling.

### HighRiskCommandVault — many approvers, one execution

Some fleet actions are too risky for one person. Locking 47 bikes, broadcasting a message to all riders, pulling funds from the operations account. This contract makes those actions wait for K signatures from M approvers before an authorised executor can run them.

```solidity
// 1. AXI ops proposes
commandId = propose(
  commandType:    HASH_LOCK_FLEET,
  targetDid:      0xfleet,
  payload:        <encoded action>,
  thresholdK:     2,                  // need 2 approvals
  totalApprovers: 3,                  // out of 3 named approvers
  expiresAt:      now + 1 hour
);

// 2. Approvers sign
approve(commandId);                   // approver B
approve(commandId);                   // approver C → status flips to Approved

// 3. An EXECUTOR_ROLE holder executes (AXI's executor cron)
execute(commandId, <same payload>);
```

Rules:
- The payload bytes are hash-locked at propose time. Execute must present the exact same bytes.
- Once K signatures hit, the command flips to `Approved`. Execution is then gated to `EXECUTOR_ROLE` holders — `execute()` carries `onlyRole(EXECUTOR_ROLE)`. The K-of-M step is the approval; execution is a single accountable role so payload delivery to the off-chain executor is traceable.
- `thresholdK` and `totalApprovers` are values the proposer declares. The contract enforces `0 < thresholdK <= totalApprovers` but does **not** bind `totalApprovers` to the live `APPROVER_ROLE` member count — keep them in sync with the real approver set when proposing.
- Proposals expire. Anyone past expiry can mark the proposal expired (gas-paid by them).
- Either the proposer or any single `APPROVER_ROLE` holder can `cancel()` a Proposed-or-Approved command — one approver can veto.
- The contract is **not** upgradeable. An upgradeable approval gate is a back door.

---

## Roles + admin

Each contract uses OpenZeppelin AccessControl. We do not have a single admin god-mode.

| Contract | Role | Held by | What they can do |
|---|---|---|---|
| Registry | DEFAULT_ADMIN | 4-of-7 multisig | Grant/revoke roles · pause · admin-unrevoke |
| Registry | ISSUER | AXI Convex action wallet | Revoke + batch revoke credentials |
| Registry | UPGRADER | 4-of-7 multisig | Push contract upgrades |
| Oracle | DEFAULT_ADMIN | 4-of-7 multisig | Grant/revoke roles |
| Oracle | ATTESTOR | AXI Atlas-Harness wallet | Publish risk scores |
| Oracle | CALIBRATOR | Risk-team multisig | Tune the score-to-premium curve |
| Oracle | UPGRADER | 4-of-7 multisig | Push contract upgrades |
| Vault | DEFAULT_ADMIN | 4-of-7 multisig | Grant/revoke roles |
| Vault | PROPOSER | AXI Convex action wallet | Open approval requests |
| Vault | APPROVER | Named operators on hardware wallets | Approve requests |
| Vault | EXECUTOR | Atlas-Harness wallet | Run approved commands |

The 4-of-7 multisig is a Safe wallet on peaq EVM, signed across founders + ops leads. Single-key admin is only used in development.

---

## Gas (rough numbers, current snapshot)

| Action | Gas | Cost @ 1 gwei |
|---|---|---|
| `Registry.revoke` | ~70k | ~$0.0001 |
| `Registry.revokeBatch(10)` | ~280k | ~$0.0004 |
| `Oracle.attest` | ~110k | ~$0.0002 |
| `Vault.propose` | ~180k | ~$0.0003 |
| `Vault.approve` | ~55k | ~$0.0001 |
| `Vault.execute` | ~50k | ~$0.0001 |

`make snapshot` after any change will catch regressions.

---

## How we tested

**57 tests passing** across the three contracts. They cover:

- Every public function's happy path.
- Every error path with a dedicated `Reject*` test.
- Every event with a `vm.expectEmit` assertion.
- Fuzzing on numeric inputs (score, threshold, timestamps).
- State-machine guards on the vault (you cannot reach `Executed` without K approvals).

What's still planned:

- Echidna invariant runs against the vault state machine.
- Mutation testing on the critical paths.
- Branch coverage > 95%.

Full hardening checklist: [`AUDIT_CHECKLIST.md`](AUDIT_CHECKLIST.md). About 80% of items are already closed.

---

## Security

- **Vulnerabilities:** report them privately per [`SECURITY.md`](SECURITY.md). 24-hour acknowledgement; 7-day triage.
- **Threat models** per contract: [`threat-models/`](threat-models/) (CredentialRevocationRegistry · HighRiskCommandVault · InsuranceRiskOracle).
- **External audit** is required before mainnet handles any treasury-scale operation. Scope is defined in [`AUDIT_CHECKLIST.md`](AUDIT_CHECKLIST.md) and the partner platform's `AUDIT_PLAN.md`.

---

## Documentation in this repo

| File | What's in it |
|---|---|
| [`MILESTONES.md`](MILESTONES.md) | Partnership-facing update for the peaq team — what we built, why, how, what's next |
| [`PEAQ_REVIEW.md`](PEAQ_REVIEW.md) | Technical review packet — for engineers reviewing the code |
| [`AGUNG_DEPLOY.md`](AGUNG_DEPLOY.md) | 25-minute step-by-step deploy walkthrough |
| [`AUDIT_CHECKLIST.md`](AUDIT_CHECKLIST.md) | Pre-audit hardening status (about 80% closed) |
| [`SECURITY.md`](SECURITY.md) | Disclosure policy + bounty plan |
| [`OPS_RUNBOOK.md`](OPS_RUNBOOK.md) | Operational procedures — who pushes which lever in an incident |
| [`threat-models/*.STRIDE.md`](threat-models/) | Per-contract STRIDE + DREAD analysis |

---

## Contributing

PRs welcome. CI runs:

- `forge fmt --check`
- `forge build --sizes`
- `forge test -vv`
- `forge snapshot --check` (no unexplained gas regressions)
- Slither (no high-severity findings allowed)

---

## License

Apache-2.0. Same licence as `peaq-integration` and the peaq protocol.
