// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

interface IInsuranceRiskOracle {
    struct RiskAttestation {
        uint16 score;
        uint64 attestedAt;
        bytes32 anchorRoot;
        uint32 sampleSizeKm;
        address attestor;
    }

    event RiskAttested(
        bytes32 indexed vehicleDid,
        uint16 score,
        bytes32 anchorRoot,
        uint32 sampleSizeKm,
        address indexed attestor
    );
    event AttestorAuthorised(address indexed attestor, address indexed grantedBy);
    event AttestorRevoked(address indexed attestor, address indexed revokedBy);
    event ScoreCurveUpdated(uint16 maxScore, uint16 floorMultiplierBps, uint16 ceilingMultiplierBps);
    event MaxAttestationAgeUpdated(uint64 previousSeconds, uint64 newSeconds, address indexed updatedBy);

    error InvalidScore(uint16 score, uint16 maxScore);
    error EmptyVehicleDid();
    error EmptyAnchorRoot();
    error AttestationTooStale(uint64 attestedAt, uint64 maxAgeSeconds);
    error NoAttestation(bytes32 vehicleDid);

    function attest(bytes32 vehicleDid, uint16 score, bytes32 anchorRoot, uint32 sampleSizeKm) external;

    function riskScore(bytes32 vehicleDid) external view returns (uint16 score, uint64 attestedAt);

    function priceMultiplierBps(bytes32 vehicleDid) external view returns (uint16);

    function latestAttestation(bytes32 vehicleDid) external view returns (RiskAttestation memory);

    function attestationCount(bytes32 vehicleDid) external view returns (uint256);

    function attestationAt(bytes32 vehicleDid, uint256 index) external view returns (RiskAttestation memory);
}
