// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IInsuranceRiskOracle} from "./interfaces/IInsuranceRiskOracle.sol";

/// @title InsuranceRiskOracle
/// @notice Per-vehicle risk score attested by AXI's authorised attestors. Insurers
///         price premiums by reading riskScore() + priceMultiplierBps() directly
///         from the chain. Each attestation cites the on-chain Merkle anchorRoot
///         that justifies the score, so insurers can independently re-derive.
/// @dev    UUPS upgradeable. Score curve is parameterised so the admin can recalibrate
///         the score → premium multiplier without redeploying. Score itself is
///         capped 0-1000; lower = safer.
contract InsuranceRiskOracle is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    IInsuranceRiskOracle
{
    bytes32 public constant ATTESTOR_ROLE = keccak256("ATTESTOR_ROLE");
    bytes32 public constant CALIBRATOR_ROLE = keccak256("CALIBRATOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    uint16 public constant MAX_SCORE = 1000;

    /// @notice Hard ceiling any premium multiplier the curve can be calibrated to.
    ///         3.0x. Stops a mis-calibration from pricing a vehicle out of cover.
    uint16 public constant MAX_MULTIPLIER_BPS = 30_000;

    /// @dev Thrown when a zero address is supplied where a real account is required.
    error ZeroAddress();
    /// @dev Thrown when a score→premium curve is nonsensical (floor>ceiling) or above the cap.
    error InvalidCurve(uint16 floorBps, uint16 ceilingBps);
    /// @dev Thrown when the staleness window is zero (would mark every score stale).
    error InvalidMaxAge();

    mapping(bytes32 => RiskAttestation) private _latest;
    mapping(bytes32 => RiskAttestation[]) private _history;

    /// @notice Score → premium-multiplier curve in basis points (10_000 = 1.0x).
    /// @dev    Linear interpolation between floor + ceiling over 0..MAX_SCORE.
    ///         Default: floor 7_000 (30% discount at score=0), ceiling 15_000
    ///         (50% surcharge at score=MAX_SCORE).
    uint16 public floorMultiplierBps;
    uint16 public ceilingMultiplierBps;

    /// @notice Maximum age (seconds) before riskScore() reverts as stale.
    uint64 public maxAttestationAgeSeconds;

    /// @dev Reserved storage slots for upgrade safety. Append new state vars
    ///      BEFORE __gap and decrement the array length accordingly.
    uint256[47] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address admin,
        address[] calldata initialAttestors,
        uint16 floorBps,
        uint16 ceilingBps,
        uint64 maxAgeSeconds
    ) external initializer {
        if (admin == address(0)) revert ZeroAddress();
        _validateCurve(floorBps, ceilingBps);
        if (maxAgeSeconds == 0) revert InvalidMaxAge();
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CALIBRATOR_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        uint256 len = initialAttestors.length;
        for (uint256 i; i < len;) {
            _grantRole(ATTESTOR_ROLE, initialAttestors[i]);
            emit AttestorAuthorised(initialAttestors[i], admin);
            unchecked {
                ++i;
            }
        }

        floorMultiplierBps = floorBps;
        ceilingMultiplierBps = ceilingBps;
        maxAttestationAgeSeconds = maxAgeSeconds;
        emit ScoreCurveUpdated(MAX_SCORE, floorBps, ceilingBps);
    }

    /// @notice Publish a new risk attestation for a vehicle. Cites the on-chain
    ///         Merkle anchorRoot that justifies the derivation.
    function attest(bytes32 vehicleDid, uint16 score, bytes32 anchorRoot, uint32 sampleSizeKm)
        external
        override
        whenNotPaused
        onlyRole(ATTESTOR_ROLE)
    {
        if (vehicleDid == bytes32(0)) revert EmptyVehicleDid();
        if (anchorRoot == bytes32(0)) revert EmptyAnchorRoot();
        if (score > MAX_SCORE) revert InvalidScore(score, MAX_SCORE);

        RiskAttestation memory rec = RiskAttestation({
            score: score,
            attestedAt: uint64(block.timestamp),
            anchorRoot: anchorRoot,
            sampleSizeKm: sampleSizeKm,
            attestor: msg.sender
        });

        _latest[vehicleDid] = rec;
        _history[vehicleDid].push(rec);

        emit RiskAttested(vehicleDid, score, anchorRoot, sampleSizeKm, msg.sender);
    }

    /// @notice Latest score + when it was set. Reverts if no attestation exists or
    ///         the attestation is older than maxAttestationAgeSeconds.
    function riskScore(bytes32 vehicleDid) external view override returns (uint16, uint64) {
        RiskAttestation storage rec = _latest[vehicleDid];
        if (rec.attestedAt == 0) revert NoAttestation(vehicleDid);
        if (block.timestamp > rec.attestedAt + maxAttestationAgeSeconds) {
            revert AttestationTooStale(rec.attestedAt, maxAttestationAgeSeconds);
        }
        return (rec.score, rec.attestedAt);
    }

    /// @notice Premium multiplier in basis points. 10_000 = 1.0x base premium.
    /// @dev    Linear interpolation: at score=0 returns floorMultiplierBps,
    ///         at score=MAX_SCORE returns ceilingMultiplierBps.
    function priceMultiplierBps(bytes32 vehicleDid) external view override returns (uint16) {
        RiskAttestation storage rec = _latest[vehicleDid];
        if (rec.attestedAt == 0) revert NoAttestation(vehicleDid);
        // Match riskScore() staleness semantics: a stale score must not silently
        // price a premium. Both read paths fail closed past the freshness window.
        if (block.timestamp > rec.attestedAt + maxAttestationAgeSeconds) {
            revert AttestationTooStale(rec.attestedAt, maxAttestationAgeSeconds);
        }
        return _multiplierFromScore(rec.score);
    }

    function latestAttestation(bytes32 vehicleDid) external view override returns (RiskAttestation memory) {
        return _latest[vehicleDid];
    }

    function attestationCount(bytes32 vehicleDid) external view override returns (uint256) {
        return _history[vehicleDid].length;
    }

    function attestationAt(bytes32 vehicleDid, uint256 index)
        external
        view
        override
        returns (RiskAttestation memory)
    {
        return _history[vehicleDid][index];
    }

    /// @dev Curve sanity: floor must not exceed ceiling, ceiling must not exceed the cap.
    function _validateCurve(uint16 floorBps, uint16 ceilingBps) internal pure {
        if (floorBps > ceilingBps || ceilingBps > MAX_MULTIPLIER_BPS) {
            revert InvalidCurve(floorBps, ceilingBps);
        }
    }

    function _multiplierFromScore(uint16 score) internal view returns (uint16) {
        // Linear interp: bps = floor + (ceiling - floor) * score / MAX_SCORE.
        // Computed in uint256 to avoid overflow then narrowed back to uint16.
        uint256 floorBps = floorMultiplierBps;
        uint256 ceilBps = ceilingMultiplierBps;
        if (ceilBps <= floorBps) return uint16(floorBps);
        uint256 spread = ceilBps - floorBps;
        uint256 result = floorBps + (spread * uint256(score)) / uint256(MAX_SCORE);
        return uint16(result);
    }

    // ---- Admin / calibration ----

    function authoriseAttestor(address attestor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(ATTESTOR_ROLE, attestor);
        emit AttestorAuthorised(attestor, msg.sender);
    }

    function revokeAttestor(address attestor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(ATTESTOR_ROLE, attestor);
        emit AttestorRevoked(attestor, msg.sender);
    }

    function recalibrate(uint16 floorBps, uint16 ceilingBps) external onlyRole(CALIBRATOR_ROLE) {
        _validateCurve(floorBps, ceilingBps);
        floorMultiplierBps = floorBps;
        ceilingMultiplierBps = ceilingBps;
        emit ScoreCurveUpdated(MAX_SCORE, floorBps, ceilingBps);
    }

    function setMaxAttestationAge(uint64 maxAgeSeconds) external onlyRole(CALIBRATOR_ROLE) {
        if (maxAgeSeconds == 0) revert InvalidMaxAge();
        uint64 previous = maxAttestationAgeSeconds;
        maxAttestationAgeSeconds = maxAgeSeconds;
        emit MaxAttestationAgeUpdated(previous, maxAgeSeconds, msg.sender);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
