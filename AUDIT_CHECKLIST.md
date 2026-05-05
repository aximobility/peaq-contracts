# AUDIT_CHECKLIST.md - peaq-contracts pre-audit hardening

> Brian gives this to the audit firm at engagement kickoff. Each item is either ✅ done, 🟡 in progress, or ⬜ pending. The audit cost goes up linearly with the number of trivial findings — the closed items below are the ones we already paid for.

Pair with `aximobility/platform/AUDIT_PLAN.md` for the full engagement structure (scope, threat model, firm requirements, budget, post-audit gate).

---

## Code quality

- ✅ Solidity 0.8.24 (latest stable, custom errors, transient storage available)
- ✅ Optimizer 10_000 runs + via-IR
- ✅ `forge fmt --check` enforced in CI
- ✅ All state-changing fns emit events; all reverts use custom errors
- ✅ All public fns have NatSpec
- ✅ All access-controlled fns use OpenZeppelin AccessControl, never bare `msg.sender == admin`
- ✅ All loops use `unchecked { ++i }` for index increment + bounded inputs
- ✅ Deprecated patterns (no `tx.origin`, no `block.timestamp` for randomness, no `delegatecall` to user input)
- ⬜ Cyclomatic complexity ≤ 10 per function (verify via slither)
- ⬜ All `internal` fns have explicit visibility annotations

## Storage layout (UUPS-specific)

- ✅ All upgradeable contracts inherit `Initializable` first
- ✅ `_disableInitializers()` in implementation constructor
- ✅ Storage gaps NOT used — relying on appendix-only-add convention + OZ v5 namespaced storage
- ⬜ Run `forge inspect storage-layout` against current + proposed v2 before any upgrade
- ⬜ `slither-check-upgradeability` clean against every proposed upgrade

## Access control

- ✅ DEFAULT_ADMIN_ROLE separated from operational roles (ISSUER / ATTESTOR / APPROVER / EXECUTOR)
- ✅ Each role grant emits an audit event (IssuerAuthorised / AttestorAuthorised / etc.)
- ✅ UPGRADER_ROLE separated from DEFAULT_ADMIN_ROLE in UUPS contracts
- ⬜ DEFAULT_ADMIN_ROLE assigned to a Safe multisig (4-of-7 recommended) before mainnet
- ⬜ Role-revoke transactions tested in a dry-run on agung
- ⬜ Emergency `pause()` exercise: someone other than admin attempts to call, reverts as expected

## Reentrancy + state-machine

- ✅ Vault.execute uses `nonReentrant` modifier
- ✅ Status transitions are guarded — `Proposed` → `Approved` → `Executed` is the only forward path
- ✅ Cancelled/Expired/Executed are terminal (no re-entry)
- ✅ markExpired() only flips status, doesn't release funds
- ⬜ Foundry invariant tests cover state-machine: `assert(status_is_monotonic)`
- ⬜ Echidna run completed with no counterexamples

## Input validation

- ✅ All `bytes32` non-zero checks at the boundary
- ✅ Score range checked `0 <= score <= 1000`
- ✅ Threshold checked `1 <= K <= M <= 10`
- ✅ Expiry window enforced `60s <= expiresAt - now <= 30 days`
- ✅ Payload-hash binding: `execute()` requires payload bytes that re-hash to the stored payloadHash
- ⬜ Fuzz tests with `bound()` on every numeric input

## Replay + idempotency

- ✅ Vault commandId derived from `(commandType, targetDid, payloadHash, K, M, nowTs, proposer)` — same proposer can't re-propose with identical args in same block
- ✅ Registry.revoke is idempotent at boundary (re-revoke reverts so caller doesn't bury earlier reasonCode)
- ✅ Oracle.attest can be called multiple times — each call appends to history
- ⬜ Run a replay attack scenario: capture a signed propose() then replay → expect `CommandAlreadyExists`

## Front-running + MEV

- ✅ No public bidding / auction surface
- ✅ No arbitrage opportunity in any view function
- ✅ approve() is per-approver; ordering doesn't matter (idempotent at K)
- ⬜ Document: Vault.execute is permissionless once K reached, so an attacker could front-run the AXI executor → not a value-extraction attack (no funds), but document anyway

## Gas

- ✅ `forge snapshot --check` baseline committed
- ✅ All loops bounded by caller-provided arrays (revokeBatch hashes.length); recommend cap of 100 per batch in operator docs
- ⬜ Run gas attack: revokeBatch with 10000 entries → DoS via block gas limit; document max batch size

## External dependencies

- ✅ OpenZeppelin v5 (latest audited line)
- ✅ Pinned via git submodule SHA in `.gitmodules` + `lib/`
- ⬜ Re-pin to specific OZ release tag (currently `master` per default `forge install` behavior)
- ⬜ npm audit / snyk on the platform-side `@axi/contracts-bridge` transitive deps

## Tests

- ✅ 51 unit + fuzz tests passing across 3 contracts
- ✅ Per-contract test file mirrors public surface 1:1
- ✅ Each error path has a dedicated test (Reject* tests)
- ✅ Each event has at least one `vm.expectEmit` assertion
- ⬜ Branch coverage > 95% (run `forge coverage`)
- ⬜ Mutation testing (necmutator or hand-mutate critical paths)
- ⬜ Differential testing against a reference impl in another language (Halmos symbolic, not blocking)

## Deploy + ops

- ✅ Foundry deploy script with role configuration via env vars
- ✅ Verify script that asserts post-deploy role state
- ✅ Slither in CI (severity-gated to high)
- ⬜ Etherscan-class verification on peaq mainnet (requires PEAQ_MAINNET_VERIFIER_KEY)
- ⬜ Subscan integration documented in deploy README
- ⬜ Multisig setup runbook (Safe on peaq EVM; signers + threshold + escape hatch)
- ⬜ DR runbook: contract pause + key rotation procedure

## Documentation

- ✅ Per-contract NatSpec
- ✅ Mermaid sequence diagrams in README
- ✅ Roles + admin model table in README
- ✅ Gas snapshot in README
- ⬜ Threat model doc per contract (STRIDE + DREAD)
- ⬜ Public security policy (`SECURITY.md`) with disclosure email + PGP key
- ⬜ Bug bounty scope + payout scale published

## Audit-ready artefacts

- ⬜ Frozen commit SHA tagged `audit-v1` before kickoff
- ⬜ `audit/` directory with: SBOM (CycloneDX), test report, gas report, slither report
- ⬜ Threat model artefact attached to engagement scope
- ⬜ Auditor-only `.env` with funded agung deployer key + read-only mainnet RPC

---

## Sign-off (per release)

| Role | Name | Signature | Date |
|---|---|---|---|
| Tech Lead (Brian Mwai) | | | |
| External Auditor | | | |
| Multisig Signer 1 | | | |
| Multisig Signer 2 | | | |

Mainnet deploy is gated on all-rows-signed + the post-audit acceptance gate in `aximobility/platform/AUDIT_PLAN.md` Section "Post-audit acceptance gate for mainnet".
