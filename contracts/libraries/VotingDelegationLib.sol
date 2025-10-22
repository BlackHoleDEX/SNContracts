// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity ^0.8.13;

import {IVotingDelegation} from "../interfaces/IVotingDelegation.sol";
import {IVotingEscrow} from "../interfaces/IVotingEscrow.sol";

contract VotingDelegationLib is IVotingDelegation {
    struct Checkpoint {
        uint timestamp;
        uint[] tokenIds;
    }

    // storage of checkpoints per account
    mapping(address => mapping(uint32 => Checkpoint)) public checkpoints;
    mapping(address => uint32) public numCheckpoints;

    uint public constant MAX_DELEGATES = 1024;

    IVotingEscrow public votingEscrow;

    address public team;

    constructor() {
        team = msg.sender;
    }

    modifier onlyVotingEscrow() {
        require(msg.sender == address(votingEscrow), "Not voting escrow");
        _;
    }

    function setTeam(address _team) external {
        require(msg.sender == team);
        team = _team;
    }
    
    function setVotingEscrow(address votingEscrow_) external {
        require(msg.sender == team);
        require(votingEscrow_ != address(0), "ZA");
        require(address(votingEscrow) == address(0), "Already set"); // only set once
        votingEscrow = IVotingEscrow(votingEscrow_);
    }
    

    function findCheckpointToWrite(address account, uint256 currentTimestamp) internal view returns (uint32) {
        uint32 n = numCheckpoints[account];
        if (n > 0 && checkpoints[account][n - 1].timestamp == currentTimestamp) {
            return n - 1;
        } else {
            return n;
        }
    }

    function moveTokenDelegates(address srcRep, address dstRep, uint _tokenId) external override onlyVotingEscrow {
        if (srcRep != dstRep && _tokenId > 0) {
            if (srcRep != address(0)) {
                uint32 srcRepNum = numCheckpoints[srcRep];
                uint[] storage srcRepOld = srcRepNum > 0 ? checkpoints[srcRep][srcRepNum - 1].tokenIds : checkpoints[srcRep][0].tokenIds;
                uint32 nextSrcRepNum = findCheckpointToWrite(srcRep, block.timestamp);
                bool _isCheckpointInNewBlock = (srcRepNum > 0) ? (nextSrcRepNum != srcRepNum - 1) : true;
                Checkpoint storage cpSrcRep = checkpoints[srcRep][nextSrcRepNum];
                uint[] storage srcRepNew = cpSrcRep.tokenIds;
                cpSrcRep.timestamp = block.timestamp;
                uint256 length = srcRepOld.length;
                for (uint i = 0; i < length;) {
                    uint tId = srcRepOld[i];
                    if (_isCheckpointInNewBlock) {
                        if (votingEscrow.ownerOf(tId) == srcRep) {
                            srcRepNew.push(tId);
                        }
                        i++;
                    } else {
                        if (votingEscrow.ownerOf(tId) != srcRep) {
                            srcRepNew[i] = srcRepNew[length - 1];
                            srcRepNew.pop();
                            length--;
                        } else {
                            i++;
                        }
                    }
                }
                numCheckpoints[srcRep] = nextSrcRepNum + 1;
            }

            if (dstRep != address(0)) {
                uint32 dstRepNum = numCheckpoints[dstRep];
                uint[] storage dstRepOld = dstRepNum > 0 ? checkpoints[dstRep][dstRepNum - 1].tokenIds : checkpoints[dstRep][0].tokenIds;
                uint32 nextDstRepNum = findCheckpointToWrite(dstRep, block.timestamp);
                bool _isCheckpointInNewBlock = (dstRepNum > 0) ? (nextDstRepNum != dstRepNum - 1) : true;
                Checkpoint storage cpDstRep = checkpoints[dstRep][nextDstRepNum];
                uint[] storage dstRepNew = cpDstRep.tokenIds;
                cpDstRep.timestamp = block.timestamp;
                require(dstRepOld.length + 1 <= MAX_DELEGATES, "tokens>1");
                if (_isCheckpointInNewBlock) {
                    for (uint i = 0; i < dstRepOld.length; i++) {
                        uint tId = dstRepOld[i];
                        dstRepNew.push(tId);
                    }
                }
                dstRepNew.push(_tokenId);
                numCheckpoints[dstRep] = nextDstRepNum + 1;
            }
        }
    }

    function moveAllDelegates(address owner, address srcRep, address dstRep) external override onlyVotingEscrow {
        address _owner = owner;
        address _srcRep = srcRep;
        address _dstRep = dstRep;
        if (_srcRep != _dstRep) {
            if (_srcRep != address(0)) {
                uint32 srcRepNum = numCheckpoints[_srcRep];
                uint[] storage srcRepOld = srcRepNum > 0 ? checkpoints[_srcRep][srcRepNum - 1].tokenIds : checkpoints[_srcRep][0].tokenIds;
                uint32 nextSrcRepNum = findCheckpointToWrite(_srcRep, block.timestamp);
                bool _isCheckpointInNewBlock = (srcRepNum > 0) ? (nextSrcRepNum != srcRepNum - 1) : true;
                Checkpoint storage cpSrcRep = checkpoints[_srcRep][nextSrcRepNum];
                uint[] storage srcRepNew = cpSrcRep.tokenIds;
                cpSrcRep.timestamp = block.timestamp;

                uint256 length = srcRepOld.length;
                for (uint i = 0; i < length;) {
                    uint tId = srcRepOld[i];
                    if (_isCheckpointInNewBlock) {
                        if (votingEscrow.ownerOf(tId) != _owner) {
                            srcRepNew.push(tId);
                        }
                        i++;
                    } else {
                        if (votingEscrow.ownerOf(tId) == _owner) {
                            srcRepNew[i] = srcRepNew[length - 1];
                            srcRepNew.pop();
                            length--;
                        } else {
                            i++;
                        }
                    }
                }
                numCheckpoints[_srcRep] = nextSrcRepNum + 1;
            }

            if (_dstRep != address(0)) {
                uint32 dstRepNum = numCheckpoints[_dstRep];
                uint[] storage dstRepOld = dstRepNum > 0 ? checkpoints[_dstRep][dstRepNum - 1].tokenIds : checkpoints[_dstRep][0].tokenIds;
                uint32 nextDstRepNum = findCheckpointToWrite(_dstRep, block.timestamp);
                bool _isCheckpointInNewBlock = (dstRepNum > 0) ? (nextDstRepNum != dstRepNum - 1) : true;
                Checkpoint storage cpDstRep = checkpoints[_dstRep][nextDstRepNum];
                uint[] storage dstRepNew = cpDstRep.tokenIds;
                cpDstRep.timestamp = block.timestamp;
                uint ownerTokenCount = votingEscrow.ownerToNFTokenCountFn(_owner);
                require(dstRepOld.length + ownerTokenCount <= MAX_DELEGATES, "tokens>1");
                if (_isCheckpointInNewBlock) {
                    for (uint i = 0; i < dstRepOld.length; i++) {
                        uint tId = dstRepOld[i];
                        dstRepNew.push(tId);
                    }
                }
                for (uint i = 0; i < ownerTokenCount; i++) {
                    uint tId = votingEscrow.tokenOfOwnerByIndex(_owner, i);
                    dstRepNew.push(tId);
                }
                numCheckpoints[_dstRep] = nextDstRepNum + 1;
            }
        }
    }

    function getPastVotesIndex(address account, uint timestamp) public view override returns (uint32) {
        uint32 nCheckpoints = numCheckpoints[account];
        if (nCheckpoints == 0) {
            return type(uint32).max;
        }
        if (checkpoints[account][0].timestamp > timestamp) {
            return type(uint32).max;
        }
        if (checkpoints[account][nCheckpoints - 1].timestamp <= timestamp) {
            return (nCheckpoints - 1);
        }
        uint32 lower = 0;
        uint32 upper = nCheckpoints - 1;
        while (upper > lower) {
            uint32 center = upper - (upper - lower) / 2;
            Checkpoint storage cp = checkpoints[account][center];
            if (cp.timestamp <= timestamp) {
                lower = center;
            } else {
                upper = center - 1;
            }
        }
        return lower;
    }

    function getLatestTokenIds(address account) external view override returns (uint[] memory) {
        uint32 n = numCheckpoints[account];
        if (n == 0) return new uint[](0);
        return checkpoints[account][n - 1].tokenIds;
    }

    function getTokenIdsAt(address account, uint32 index) external view override returns (uint[] memory) {
        return checkpoints[account][index].tokenIds;
    }

    function getTokenIdsAtTimestamp(address account, uint timestamp) public view returns (uint[] memory) {
        uint32 nCheckpoints = getPastVotesIndex(account, timestamp);
        if (nCheckpoints == type(uint32).max) {
            return new uint[](0);
        }
        return checkpoints[account][nCheckpoints].tokenIds;
    }
}