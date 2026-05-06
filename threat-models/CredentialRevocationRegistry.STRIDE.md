# STRIDE Threat Model · CredentialRevocationRegistry

> Per-contract threat model. Pairs with `AUDIT_CHECKLIST.md` (general hardening) and `SECURITY.md` (disclosure). For external auditors.

## Contract under review

`peaq-contracts/src/CredentialRevocationRegistry.sol` (UUPS proxy, OpenZeppelin AccessControl)

**Purpose:** revocable W3C VCs (driver licenses, NTSA inspections, insurance binders). Insurers + regulators consult before underwriting / inspection.

## Attack surface

```
   Trusted ──► ISSUER_ROLE  ──► revoke(hash, reasonCode)
                              ──► revokeBatch(hashes[], reasonCode)
   Untrusted ──► public      ──► isRevoked(hash) → bool
                              ──► metadata(hash) → (revokedAt, revoker, reasonCode)
   Trusted ──► PAUSER_ROLE   ──► pause() / unpause()
   Trusted ──► UPGRADER_ROLE ──► upgradeToAndCall(newImpl, data)
   Trusted ──► DEFAULT_ADMIN ──► grantRole / revokeRole
```

## STRIDE per-flow

### S — Spoofing

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Caller spoofs ISSUER_ROLE | `revoke()` | low | high | OZ AccessControl + per-issuer scope (only the issuer of a credential can revoke it) — enforced via internal mapping `credentialIssuer[hash]` |
| Caller spoofs PAUSER_ROLE | `pause()` | low | medium | AccessControl |
| EOA replays a captured `revoke()` tx | mempool | low | low (idempotent re-revoke reverts) | `AlreadyRevoked` custom error preserves earlier `reasonCode` |

### T — Tampering

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Modify a revocation post-hoc | storage | low | critical | Append-only design; once revoked, state immutable. Re-revoke reverts. |
| Replace implementation with malicious impl | UUPS upgrade | low | catastrophic | UPGRADER_ROLE separated from DEFAULT_ADMIN_ROLE; multisig 4-of-7 before mainnet |
| Storage collision in upgrade | UUPS upgrade | medium pre-mitigation | critical | OZ v5 namespaced storage + `forge inspect storage-layout` diff in CI |

### R — Repudiation

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Issuer denies revoking a credential | revoker mapping | low | medium | `metadata(hash)` returns revoker address publicly + `Revoked` event indexed |
| Audit trail tampering | event log | impossible | n/a | Events emitted on every state change; cannot rewrite past blocks |

### I — Information disclosure

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Revoker identity public | `metadata().revoker` | by design | n/a | Public revoker is a feature for compliance audit |
| Reason code public | `metadata().reasonCode` | by design | n/a | Public reasonCode is required for insurance underwriter consumption |
| Credential hash leaks PII | hash content | low | medium | Hash is keccak256 of credential payload; no preimage on-chain. Operators must not put PII in the hash input. Documented in OPS_RUNBOOK. |

### D — Denial of service

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| `revokeBatch()` gas-exhaust DoS | batch size | medium | medium | Recommended cap of 100 per batch documented. Caller-bounded. Future: enforce on-chain `MAX_BATCH_SIZE = 100`. |
| Issuer's wallet drained → can't revoke | wallet balance | medium | medium | Issuer warned to maintain min balance; PAUSER can pause if needed |
| Pause stuck closed | PAUSER_ROLE | low | high | DEFAULT_ADMIN can grant a fresh PAUSER; multisig 4-of-7 prevents single-sig hostage |

### E — Elevation of privilege

| Threat | Surface | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| Compromised ISSUER_ROLE → mass revoke valid credentials | AccessControl | medium | high | Per-issuer scope + revocable role + emergency `pause()` + multisig DEFAULT_ADMIN |
| UPGRADER_ROLE compromise → drain via malicious impl | UUPS | low | catastrophic | Multisig 4-of-7 before mainnet (mandated, not optional) |
| Front-running a `grantRole` to insert a malicious role | mempool | low | critical | DEFAULT_ADMIN_ROLE on multisig; role grants emit auditable events |

## DREAD scoring (1-10 each, total max 50)

| Threat | D | R | E | A | D | Total |
|---|---|---|---|---|---|---|
| UUPS storage collision in upgrade | 9 | 4 | 6 | 9 | 7 | **35** |
| UPGRADER_ROLE compromise via single-sig | 10 | 3 | 5 | 9 | 8 | **35** |
| Compromised ISSUER_ROLE → mass revoke | 7 | 5 | 6 | 7 | 6 | **31** |
| Reentrancy in revoke (theoretical only; no external calls) | 0 | 0 | 0 | 0 | 0 | **0** |
| `revokeBatch` gas DoS | 4 | 9 | 7 | 4 | 5 | **29** |
| Replay attack on signed propose (n/a here) | 0 | 0 | 0 | 0 | 0 | **0** |

Top risks: UUPS storage collision + UPGRADER role compromise. Both mitigated by Safe multisig + storage-layout CI check (mandated for mainnet promotion).

## Open issues for the audit firm

1. Should `revokeBatch` enforce on-chain `MAX_BATCH_SIZE` rather than rely on documentation? Recommend yes; cheap to add.
2. Should `metadata()` redact revoker identity for non-issuer queries? **No** — reveals revoker is a compliance feature.
3. Should `pause()` automatically expire after N days to prevent forever-paused state? Discuss; lean toward yes with 30d auto-unpause.
4. Should we add a `setIssuer(hash, issuer)` admin escape hatch for misconfigured issuance? Lean toward yes for Phase 1; remove in Phase 5.

## Cross-references

- `AUDIT_CHECKLIST.md` — general hardening checklist
- `SECURITY.md` — disclosure policy
- `threat-models/HighRiskCommandVault.STRIDE.md` — sibling threat model
- `threat-models/InsuranceRiskOracle.STRIDE.md` — sibling threat model
- OZ v5 AccessControl docs · OZ UUPS upgrade docs
