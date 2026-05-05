// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

interface IHighRiskCommandVault {
    enum Status {
        None,
        Proposed,
        Approved,
        Executed,
        Cancelled,
        Expired
    }

    struct Command {
        bytes32 commandType;
        bytes32 targetDid;
        bytes32 payloadHash;
        uint8 thresholdK;
        uint8 totalApprovers;
        uint8 approvalCount;
        uint64 proposedAt;
        uint64 expiresAt;
        Status status;
        address proposer;
    }

    event CommandProposed(
        bytes32 indexed commandId,
        bytes32 indexed commandType,
        bytes32 indexed targetDid,
        address proposer,
        uint8 thresholdK,
        uint8 totalApprovers,
        uint64 expiresAt
    );
    event CommandApproved(bytes32 indexed commandId, address indexed approver, uint8 newApprovalCount);
    event CommandExecuted(bytes32 indexed commandId, address indexed executor, bytes payload);
    event CommandCancelled(bytes32 indexed commandId, address indexed canceller);
    event ApproverAuthorised(address indexed approver, address indexed grantedBy);
    event ApproverRevoked(address indexed approver, address indexed revokedBy);

    error CommandAlreadyExists(bytes32 commandId);
    error CommandNotFound(bytes32 commandId);
    error CommandNotProposed(bytes32 commandId, Status status);
    error CommandNotApproved(bytes32 commandId, Status status);
    error CommandExpired(bytes32 commandId, uint64 expiresAt);
    error AlreadyApproved(bytes32 commandId, address approver);
    error InvalidThreshold(uint8 thresholdK, uint8 totalApprovers);
    error InvalidExpiry(uint64 expiresAt, uint64 nowTs);
    error PayloadHashMismatch(bytes32 expected, bytes32 provided);

    function propose(
        bytes32 commandType,
        bytes32 targetDid,
        bytes calldata payload,
        uint8 thresholdK,
        uint8 totalApprovers,
        uint64 expiresAt
    ) external returns (bytes32 commandId);

    function approve(bytes32 commandId) external;
    function execute(bytes32 commandId, bytes calldata payload) external;
    function cancel(bytes32 commandId) external;

    function command(bytes32 commandId) external view returns (Command memory);
    function hasApproved(bytes32 commandId, address approver) external view returns (bool);
}
