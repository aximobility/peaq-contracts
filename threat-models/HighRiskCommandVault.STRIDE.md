# STRIDE Threat Model · HighRiskCommandVault

> Per-contract threat model for the K-of-M approval vault.

## Contract under review

`peaq-contracts/src/HighRiskCommandVault.sol` (UUPS proxy, OpenZeppelin AccessControl + ReentrancyGuard + Pausable)

**Purpose:** K-of-M approval for fleet-wide commands (lock 47 vehicles, mass route override, broadcast >100 messages). Required by `axi-mobility/apps/admin/ADMIN_DATA_HANDLING.md` governance.

## Attack surface

```
   Trusted ──► PROPOSER_ROLE ──► propose(commandType, targetDid, payloadHash, K, M, expiresAt) → commandId
   Trusted ──► APPROVER_ROLE ──► approve(commandId)
   Trusted ──► PROPOSER_ROLE ──► cancel(commandId) (proposer only)
   Untrusted ──► public      ──► execute(commandId, payload) (permissionless once K reached)
   Untrusted ──► public      ──► markExpired(commandId) (anyone can flip status)
   Untrusted ──► public      ──► getCommand(commandId) view
   Trusted ──► PAUSER_ROLE   ──► pause() / unpause()
   Trusted ──► UPGRADER_ROLE ──► upgradeToAndCall
   Trusted ──► DEFAULT_ADMIN ──► grantRole / revokeRole
```

## State machine (forward path only)

```
Proposed ──approve(K times)──► Approved ──execute(once)──► Executed (terminal)
   │                              │
   ├──cancel()──► Cancelled (terminal, proposer only)
   ├──markExpired()──► Expired (terminal, anyone after expiresAt)
   └──pause→halt all transitions
```

`Cancelled`, `Expired`, `Executed` are terminal. No backwards transitions. Enforced via `_setStatus()` internal helper.

## STRIDE per-flow

### S — Spoofing

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Spoof PROPOSER_ROLE | `propose()` | low | medium | AccessControl |
| Spoof APPROVER_ROLE | `approve()` | low | high | AccessControl + per-command approver tracking (each approver counted once) |
| Replay captured `propose()` | mempool | low | low | `commandId = keccak256(commandType, targetDid, payloadHash, K, M, nowTs, proposer)` — same proposer + identical args same block reverts with `CommandAlreadyExists` |
| Replay captured `approve()` | mempool | low | low | Per-command approver mapping; second approve from same approver no-op |
| Permissionless `execute()` front-run | mempool | medium | low (no funds, just timing) | By design; documented MEV note. Not value-extraction. |

### T — Tampering

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Modify command after Proposed | storage | low | critical | State machine guards + immutable `payloadHash` after propose |
| Modify K or M after propose | storage | low | high | K/M stored on `propose`; cannot mutate (no setter) |
| Bypass state machine | storage | low | critical | `_setStatus()` reverts on disallowed transitions; `nonReentrant` modifier on `execute` |
| Storage collision in UUPS upgrade | UUPS | low | catastrophic | OZ v5 namespaced storage + storage-layout CI |
| Force command into Approved without K signatures | storage | low | catastrophic | Only `approve()` increments approval count; counter checked against K in `execute()` |

### R — Repudiation

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Approver denies approving | event log | impossible | n/a | `Approved` event with approver + commandId emitted; on-chain trail |
| Proposer denies proposing | event log | impossible | n/a | `Proposed` event with proposer + commandId + all args |
| Executor denies executing | event log | impossible | n/a | `Executed` event with executor + commandId + payload |

### I — Information disclosure

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Pending command intentions visible on-chain | `getCommand()` view | by design | low | We store `payloadHash` only; full payload off-chain. Front-running risk acknowledged (see Spoofing/permissionless execute). |
| Approver list public | per-command approver mapping | by design | low | Public approval is the audit feature |
| Command type leaks operational detail | `commandType` enum | by design | low | Generic enum (`LOCK_FLEET`, `ROUTE_OVERRIDE`, `BROADCAST`); not specific to bike or driver |

### D — Denial of service

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Spam `propose()` to fill storage | propose | medium | medium | PROPOSER_ROLE-gated; cost = gas. Documented as operational risk; PAUSER can pause. |
| `markExpired()` race vs `execute()` | mempool | low | low | Both flip status atomically; whichever lands first wins. Either outcome is acceptable. |
| Pause stuck closed | PAUSER_ROLE | low | high | DEFAULT_ADMIN can grant fresh PAUSER; multisig prevents single-sig hostage |
| K or M too large (gas exhaust) | propose validation | low | low | Bounded `1 ≤ K ≤ M ≤ 10` enforced in propose() |

### E — Elevation of privilege

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Compromised PROPOSER → spam high-risk proposes | PROPOSER_ROLE | medium | medium | Each proposer has rate-limit (proposed; bound by gas cost in practice) + revocable role + multisig DEFAULT_ADMIN |
| Compromised APPROVER + collusion to reach K | APPROVER_ROLE | medium | catastrophic | M ≥ K + 1; require diverse approver origins (distinct hardware wallets); operational practice |
| UPGRADER compromise → swap impl, drain or freeze | UUPS | low | catastrophic | UPGRADER_ROLE separated; multisig 4-of-7 mandated before mainnet |
| Front-run `grantRole(APPROVER)` to insert malicious approver before next propose | mempool | low | critical | DEFAULT_ADMIN_ROLE on multisig; role grants emit auditable events that operators monitor |

## DREAD scoring

| Threat | D | R | E | A | D | Total |
|---|---|---|---|---|---|---|
| UPGRADER compromise via single-sig | 10 | 3 | 5 | 9 | 8 | **35** |
| UUPS storage collision in upgrade | 9 | 4 | 6 | 9 | 7 | **35** |
| Compromised APPROVERs collude to reach K | 9 | 4 | 6 | 7 | 6 | **32** |
| State machine bypass via reentrancy | 9 | 2 | 4 | 9 | 6 | **30** |
| Front-run `execute()` once K reached | 3 | 9 | 8 | 3 | 6 | **29** |

## Invariants we WANT external audit to formally verify

1. **State monotonicity**: `Proposed → Approved → Executed` is the only forward path; `Cancelled`/`Expired`/`Executed` are terminal. (Foundry invariant test draft: `assert(canTransitionFrom(prev, next))` for all 25 pairs.)
2. **K-approval before execute**: `executed[commandId] == false || approvalCount[commandId] >= K` (if-and-only-if).
3. **Approver uniqueness**: `approve()` from same approver twice does not increment count.
4. **Replay safety**: Two `propose()` calls in the same block with identical args revert the second.
5. **No fund movement** (the vault holds zero ETH/PEAQ; verify `address(this).balance == 0` always).

## Open issues for the audit firm

1. Should `propose()` charge a refundable bond to deter spam? Lean no for Phase 1; revisit if observed spam.
2. Should `cancel()` allow APPROVER (rather than only proposer) once K reached? Lean no; only proposer revokes.
3. Should `execute()` require msg.sender to have an EXECUTOR_ROLE rather than be permissionless? Lean no per documented MEV analysis (no value extraction).
4. Should we emit `MarkedExpired` even when called by non-admin? Yes; document as feature.
5. Echidna run against state machine — recommend.

## Cross-references

- `AUDIT_CHECKLIST.md`
- `SECURITY.md`
- `threat-models/CredentialRevocationRegistry.STRIDE.md`
- `threat-models/InsuranceRiskOracle.STRIDE.md`
- `axi-mobility/apps/admin/ADMIN_DATA_HANDLING.md` (the K-of-M policy this contract enforces)
