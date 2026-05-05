// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHighRiskCommandVault} from "./interfaces/IHighRiskCommandVault.sol";

/// @title HighRiskCommandVault
/// @notice K-of-M on-chain approval for any AXI command flagged requiresApproval.
///         AXI proposes a payload-hash-bound command; K distinct on-chain approvers
///         each call approve(); once threshold met, anyone can call execute() to
///         retrieve the payload + emit the canonical event the AXI executor
///         listens for.
/// @dev    Intentionally NON-upgradeable. Upgradeable approval logic = trust-loop
///         re-entry which defeats the contract's purpose. To change behaviour,
///         deploy a new vault, migrate proposers + approvers, deprecate the old
///         contract via revoke-all-roles + pause.
contract HighRiskCommandVault is AccessControl, Pausable, ReentrancyGuard, IHighRiskCommandVault {
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant APPROVER_ROLE = keccak256("APPROVER_ROLE");
    bytes32 public constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    uint64 public constant MIN_EXPIRY_WINDOW = 60; // 1 minute
    uint64 public constant MAX_EXPIRY_WINDOW = 30 days;

    mapping(bytes32 => Command) private _commands;
    mapping(bytes32 => mapping(address => bool)) private _hasApproved;

    constructor(address admin, address[] memory initialProposers, address[] memory initialApprovers) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(PAUSER_ROLE, admin);

        uint256 pl = initialProposers.length;
        for (uint256 i; i < pl;) {
            _grantRole(PROPOSER_ROLE, initialProposers[i]);
            unchecked {
                ++i;
            }
        }

        uint256 al = initialApprovers.length;
        for (uint256 i; i < al;) {
            _grantRole(APPROVER_ROLE, initialApprovers[i]);
            emit ApproverAuthorised(initialApprovers[i], admin);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Propose a high-risk command. Stores the keccak256(payload) so the
    ///         eventual execute() call must present the same payload bytes.
    function propose(
        bytes32 commandType,
        bytes32 targetDid,
        bytes calldata payload,
        uint8 thresholdK,
        uint8 totalApprovers,
        uint64 expiresAt
    ) external override whenNotPaused onlyRole(PROPOSER_ROLE) returns (bytes32 commandId) {
        if (thresholdK == 0 || thresholdK > totalApprovers) {
            revert InvalidThreshold(thresholdK, totalApprovers);
        }
        uint64 nowTs = uint64(block.timestamp);
        if (expiresAt < nowTs + MIN_EXPIRY_WINDOW || expiresAt > nowTs + MAX_EXPIRY_WINDOW) {
            revert InvalidExpiry(expiresAt, nowTs);
        }

        bytes32 payloadHash = keccak256(payload);
        commandId = keccak256(
            abi.encode(commandType, targetDid, payloadHash, thresholdK, totalApprovers, nowTs, msg.sender)
        );

        if (_commands[commandId].status != Status.None) revert CommandAlreadyExists(commandId);

        _commands[commandId] = Command({
            commandType: commandType,
            targetDid: targetDid,
            payloadHash: payloadHash,
            thresholdK: thresholdK,
            totalApprovers: totalApprovers,
            approvalCount: 0,
            proposedAt: nowTs,
            expiresAt: expiresAt,
            status: Status.Proposed,
            proposer: msg.sender
        });

        emit CommandProposed(
            commandId, commandType, targetDid, msg.sender, thresholdK, totalApprovers, expiresAt
        );
    }

    function approve(bytes32 commandId) external override whenNotPaused onlyRole(APPROVER_ROLE) {
        Command storage cmd = _commands[commandId];
        if (cmd.status == Status.None) revert CommandNotFound(commandId);
        if (cmd.status != Status.Proposed) revert CommandNotProposed(commandId, cmd.status);
        if (block.timestamp > cmd.expiresAt) {
            // Storage write would be reverted with the rest of the tx; just revert.
            // markExpired() lets an indexer flip the status post-hoc without re-trying writes.
            revert CommandExpired(commandId, cmd.expiresAt);
        }
        if (_hasApproved[commandId][msg.sender]) revert AlreadyApproved(commandId, msg.sender);

        _hasApproved[commandId][msg.sender] = true;
        unchecked {
            ++cmd.approvalCount;
        }
        emit CommandApproved(commandId, msg.sender, cmd.approvalCount);

        if (cmd.approvalCount >= cmd.thresholdK) {
            cmd.status = Status.Approved;
        }
    }

    /// @notice Execute an approved command. Caller MUST present the original
    ///         payload bytes; we re-hash and compare to the stored payloadHash.
    ///         Permissionless — anyone (typically the AXI executor cron) can call.
    function execute(bytes32 commandId, bytes calldata payload)
        external
        override
        whenNotPaused
        nonReentrant
        onlyRole(EXECUTOR_ROLE)
    {
        Command storage cmd = _commands[commandId];
        if (cmd.status == Status.None) revert CommandNotFound(commandId);
        if (cmd.status != Status.Approved) revert CommandNotApproved(commandId, cmd.status);
        if (block.timestamp > cmd.expiresAt) {
            // Storage write would be reverted with the rest of the tx; just revert.
            // markExpired() lets an indexer flip the status post-hoc without re-trying writes.
            revert CommandExpired(commandId, cmd.expiresAt);
        }
        if (keccak256(payload) != cmd.payloadHash) {
            revert PayloadHashMismatch(cmd.payloadHash, keccak256(payload));
        }

        cmd.status = Status.Executed;
        emit CommandExecuted(commandId, msg.sender, payload);
    }

    /// @notice Cancel a proposed-or-approved command. Proposer or any APPROVER
    ///         may cancel. Executed commands cannot be cancelled.
    function cancel(bytes32 commandId) external override whenNotPaused {
        Command storage cmd = _commands[commandId];
        if (cmd.status == Status.None) revert CommandNotFound(commandId);
        if (cmd.status == Status.Executed || cmd.status == Status.Cancelled || cmd.status == Status.Expired) {
            revert CommandNotProposed(commandId, cmd.status);
        }
        if (msg.sender != cmd.proposer && !hasRole(APPROVER_ROLE, msg.sender)) {
            revert AccessControlUnauthorizedAccount(msg.sender, APPROVER_ROLE);
        }
        cmd.status = Status.Cancelled;
        emit CommandCancelled(commandId, msg.sender);
    }

    /// @notice Permissionless GC: flip a Proposed-or-Approved command past expiry to Expired.
    ///         Lets indexers + UIs settle the visible state without re-trying writes that revert.
    function markExpired(bytes32 commandId) external whenNotPaused {
        Command storage cmd = _commands[commandId];
        if (cmd.status != Status.Proposed && cmd.status != Status.Approved) {
            revert CommandNotProposed(commandId, cmd.status);
        }
        if (block.timestamp <= cmd.expiresAt) {
            revert CommandExpired(commandId, cmd.expiresAt);
        }
        cmd.status = Status.Expired;
    }

    function command(bytes32 commandId) external view override returns (Command memory) {
        return _commands[commandId];
    }

    function hasApproved(bytes32 commandId, address approver) external view override returns (bool) {
        return _hasApproved[commandId][approver];
    }

    // ---- Admin ----

    function authoriseProposer(address proposer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(PROPOSER_ROLE, proposer);
    }

    function authoriseApprover(address approver) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(APPROVER_ROLE, approver);
        emit ApproverAuthorised(approver, msg.sender);
    }

    function revokeApprover(address approver) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _revokeRole(APPROVER_ROLE, approver);
        emit ApproverRevoked(approver, msg.sender);
    }

    function authoriseExecutor(address executor) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _grantRole(EXECUTOR_ROLE, executor);
    }

    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(PAUSER_ROLE) {
        _unpause();
    }
}
