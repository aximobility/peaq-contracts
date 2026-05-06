# Security Policy - peaq-contracts

> Public security disclosure policy for the AXI Mobility peaq smart contracts. Anyone who finds a vulnerability in `CredentialRevocationRegistry`, `HighRiskCommandVault`, or `InsuranceRiskOracle` should report it here.

## Scope

| In scope | Out of scope |
|---|---|
| `peaq-contracts/src/*.sol` (Solidity contracts) | Third-party services we depend on (peaq chain, Cloudflare, AWS, Convex) |
| Deployed instances on peaq Agung testnet | Social engineering attacks |
| Deployed instances on peaq mainnet (when promoted) | Physical access attacks |
| Issues in `script/Deploy.s.sol` and `script/Verify.s.sol` | Issues in non-`peaq-contracts` repos (file in their respective `SECURITY.md`) |
| Issues in `lib/forge-std` (forwarded upstream) | Self-inflicted issues (lost private key, compromised wallet) |

## How to report

**Email:** `security@aximobility.com`

**PGP key fingerprint:** *(to be published; see `keys/security.aximobility.com.asc` once committed)*

If email is not safe (e.g. you're in a regulated jurisdiction):
- Signal: ask via GitHub issue for the number (do not put attack details in the issue)
- Telegram: `@brian_mwai` (encrypted DMs)

## What to include

1. **Description** of the vulnerability (1-2 paragraphs)
2. **Reproduction steps** — concrete (foundry test case if applicable)
3. **Impact assessment** — what an attacker gains, what they need to do
4. **Suggested mitigation** if you have one
5. **Your name + handle** for the disclosure credit (or anonymous if preferred)

Please **do NOT** open a public GitHub issue or PR for an undisclosed vulnerability.

## Response SLA

| Stage | Time | What happens |
|---|---|---|
| Acknowledgement | within 24 hours | Brian or Joy confirms receipt |
| Triage | within 7 days | Severity assigned + reproduction confirmed |
| Patch + audit | within 30 days for critical/high; 90 days for medium/low | Fix written, tested, optionally audited |
| Public disclosure | coordinated with reporter | Joint advisory with credit (or anonymous) |
| Bounty payout (when active) | within 14 days of patch deploy | See bounty section below |

## Severity rubric

| Severity | Definition | Example |
|---|---|---|
| **Critical** | Direct loss of funds, mass forgery, or unconditional privilege escalation | Bypass K-of-M in `HighRiskCommandVault` to execute arbitrary command |
| **High** | Conditional privilege escalation, denial of service for >24h, or data integrity breach | Force-revoke a credential without ISSUER_ROLE under specific block conditions |
| **Medium** | Limited DoS, role-leak, or inconsistent state | DoS `revokeBatch` via crafted input that exhausts gas before reverting |
| **Low** | Best-practice deviation, inefficiency, or non-exploitable bug | Inefficient storage layout costing extra gas |
| **Informational** | Code quality, documentation, or non-security observation | NatSpec missing on internal helper |

## Bug bounty (Phase 5+)

**Status: not yet active.** The bounty program turns on after the external audit firm signs off on the contracts (Phase 5 per `axi-mobility/EXECUTION_ORDER.md`). Until then we still accept reports + acknowledge but do not pay bounty.

**Planned tiers (upon activation):**

| Tier | Severity | Payout (USDC) |
|---|---|---|
| Tier 1 | Critical | $5,000 |
| Tier 2 | High | $1,000 |
| Tier 3 | Medium | $250 |
| Tier 4 | Low / Informational | hall-of-fame credit only |

**Eligibility:**
- First valid report wins (no duplicates)
- Must follow this policy (private disclosure)
- Must give us reasonable time to patch before public disclosure
- No social engineering, physical attacks, or DoS attempts on production
- Reporter must not be employed by AXI Mobility or its contractors at time of report

## Safe Harbor

We commit to:
- Not pursuing legal action against good-faith researchers who follow this policy
- Acknowledging your contribution publicly (or anonymously, your choice)
- Coordinating disclosure timeline with you
- Treating your report confidentially until coordinated public disclosure

We reserve the right to revoke safe harbor for:
- Bad-faith research (intent to extort, mass exploitation, public disclosure before patch)
- Privacy violations (accessing user data beyond what's needed to demonstrate the bug)
- Service disruption (DoS, gas-burn attacks on production)

## What we've done

Per `AUDIT_CHECKLIST.md`:

- ✅ Solidity 0.8.24 (latest stable)
- ✅ OpenZeppelin v5 AccessControl (no bare admin checks)
- ✅ UUPS upgradeable with `_disableInitializers()` + UPGRADER_ROLE separation
- ✅ Custom errors throughout (no `require` strings)
- ✅ Reentrancy guards + state-machine guards
- ✅ Input validation at every public boundary
- ✅ 51 unit + fuzz tests passing
- ✅ Slither in CI severity-gated to high
- ✅ Deployed on Agung testnet for live testing
- ⬜ External audit (Phase 5 gate)
- ⬜ Echidna invariant testing
- ⬜ Mutation testing
- ⬜ Safe multisig admin (mandated before mainnet)

## Known patterns we're explicitly NOT defending against

| Pattern | Why ignored |
|---|---|
| Front-running of `HighRiskCommandVault.execute()` once K reached | By design; `execute()` is permissionless. Not a value-extraction attack. |
| Public visibility of risk attestations in `InsuranceRiskOracle` | By design; public attestation log is the product. |
| Public visibility of revocation reasons in `CredentialRevocationRegistry` | By design; reasons are part of the audit trail. |
| Block-timestamp manipulation to bypass `expiresAt` | Bounded by `60s..30d`; manipulation gives at most ±15s drift on peaq. |

## Cross-references

- `AUDIT_CHECKLIST.md` — full pre-audit hardening status
- `PEAQ_REVIEW.md` — peaq team integration review packet
- `threat-models/*.STRIDE.md` — per-contract threat model
- `OPS_RUNBOOK.md` — operational procedures
- `axi-mobility/SECURITY_AUDIT.md` — platform-wide 7-layer per-PR checklist

---

*Last updated 2026-05-06. Review quarterly + on every release.*
