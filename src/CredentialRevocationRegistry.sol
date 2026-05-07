// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {
    AccessControlUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ICredentialRevocationRegistry} from "./interfaces/ICredentialRevocationRegistry.sol";

/// @title CredentialRevocationRegistry
/// @notice Trustless on-chain status of AXI-issued credentials. Verifiers query
///         isRevoked(credentialHash) without trusting AXI's REST endpoint.
/// @dev    UUPS upgradeable so revocation logic can evolve (delegated revocation,
///         time-bounded revocation, batched proofs) without breaking integrators.
///         Issuers granted via AccessControl ISSUER_ROLE; admin retains revoke
///         authority over issuers themselves.
contract CredentialRevocationRegistry is
    Initializable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ICredentialRevocationRegistry
{
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    /// @notice Hard cap on revokeBatch size. Prevents issuer-key compromise from
    ///         griefing the chain via a single jumbo tx.
    uint256 public constant MAX_BATCH_SIZE = 100;

    mapping(bytes32 => RevocationRecord) private _records;
    uint256 private _totalRevoked;

    /// @dev Reserved storage slots for upgrade safety. See OZ docs on namespaced
    ///      storage + storage layout. Append new state variables BEFORE __gap
    ///      and decrement the array length accordingly.
    uint256[48] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address admin, address[] calldata initialIssuers) external initializer {
        __AccessControl_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);
        _grantRole(UPGRADER_ROLE, admin);

        uint256 len = initialIssuers.length;
        for (uint256 i; i < len;) {
            _grantRole(ISSUER_ROLE, initialIssuers[i]);
            emit IssuerAuthorised(initialIssuers[i], admin);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Revoke a single credential. Idempotent at the assertion layer:
    ///         re-revoking is rejected so callers can't bury earlier reasonCodes.
    function revoke(bytes32 credentialHash, bytes32 reasonCode)
        external
        override
        whenNotPaused
        onlyRole(ISSUER_ROLE)
    {
        if (credentialHash == bytes32(0)) revert EmptyCredentialHash();
        RevocationRecord storage rec = _records[credentialHash];
        if (rec.revoked) revert AlreadyRevoked(credentialHash);

        rec.revoked = true;
        rec.revokedAt = uint64(block.timestamp);
        rec.reasonCode = reasonCode;
        rec.revokedBy = msg.sender;

        unchecked {
            ++_totalRevoked;
        }
        emit CredentialRevoked(credentialHash, msg.sender, reasonCode);
    }

    /// @notice Revoke many credentials in one tx. Same reasonCode applies to all
    ///         (e.g. "issuer-key-compromised" sweeps a batch). Skips already-revoked
    ///         entries silently so a partial sweep can be safely retried.
    function revokeBatch(bytes32[] calldata credentialHashes, bytes32 reasonCode)
        external
        override
        whenNotPaused
        onlyRole(ISSUER_ROLE)
    {
        uint256 len = credentialHashes.length;
        if (len > MAX_BATCH_SIZE) revert BatchTooLarge(len, MAX_BATCH_SIZE);
        uint256 newlyRevoked;
        for (uint256 i; i < len;) {
            bytes32 ch = credentialHashes[i];
            if (ch != bytes32(0)) {
                RevocationRecord storage rec = _records[ch];
                if (!rec.revoked) {
                    rec.revoked = true;
                    rec.revokedAt = uint64(block.timestamp);
                    rec.reasonCode = reasonCode;
                    rec.revokedBy = msg.sender;
                    unchecked {
                        ++newlyRevoked;
                    }
                    emit CredentialRevoked(ch, msg.sender, reasonCode);
                }
            }
            unchecked {
                ++i;
            }
        }
        if (newlyRevoked != 0) {
            unchecked {
                _totalRevoked += newlyRevoked;
            }
        }
    }

    /// @notice Reverse a revocation. Restricted to admin to prevent issuer-level
    ///         compromise from un-revoking previously revoked credentials.
    function unrevoke(bytes32 credentialHash) external override whenNotPaused onlyRole(DEFAULT_ADMIN_ROLE) {
        RevocationRecord storage rec = _records[credentialHash];
        if (!rec.revoked) revert NotRevoked(credentialHash);
        rec.revoked = false;
        rec.revokedAt = 0;
        rec.reasonCode = bytes32(0);
        rec.revokedBy = address(0);
        unchecked {
            --_totalRevoked;
        }
        emit CredentialUnrevoked(credentialHash, msg.sender);
    }

    function isRevoked(bytes32 credentialHash) external view override returns (bool) {
        return _records[credentialHash].revoked;
    }

    function whyRevoked(bytes32 credentialHash) external view override returns (RevocationRecord memory) {
        return _records[credentialHash];
    }

    function totalRevoked() external view override returns (uint256) {
        return _totalRevoked;
    }

    // ---- Admin ----

    function authoriseIssuer(address issuer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(ISSUER_ROLE, issuer);
        emit IssuerAuthorised(issuer, msg.sender);
    }

    function revokeIssuer(address issuer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(ISSUER_ROLE, issuer);
        emit IssuerRevoked(issuer, msg.sender);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    /// @dev UUPS upgrade gate.
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}
}
