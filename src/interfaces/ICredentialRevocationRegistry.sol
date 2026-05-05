// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

interface ICredentialRevocationRegistry {
    struct RevocationRecord {
        bool revoked;
        uint64 revokedAt;
        bytes32 reasonCode;
        address revokedBy;
    }

    event CredentialRevoked(bytes32 indexed credentialHash, address indexed issuer, bytes32 reasonCode);
    event CredentialUnrevoked(bytes32 indexed credentialHash, address indexed issuer);
    event IssuerAuthorised(address indexed issuer, address indexed grantedBy);
    event IssuerRevoked(address indexed issuer, address indexed revokedBy);

    error AlreadyRevoked(bytes32 credentialHash);
    error NotRevoked(bytes32 credentialHash);
    error EmptyCredentialHash();

    function revoke(bytes32 credentialHash, bytes32 reasonCode) external;
    function revokeBatch(bytes32[] calldata credentialHashes, bytes32 reasonCode) external;
    function unrevoke(bytes32 credentialHash) external;
    function isRevoked(bytes32 credentialHash) external view returns (bool);
    function whyRevoked(bytes32 credentialHash) external view returns (RevocationRecord memory);
    function totalRevoked() external view returns (uint256);
}
