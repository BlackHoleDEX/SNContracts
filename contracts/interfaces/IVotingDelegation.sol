// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity ^0.8.13;

interface IVotingDelegation {
    function moveTokenDelegates(address srcRep, address dstRep, uint _tokenId) external;
    function moveAllDelegates(address owner, address srcRep, address dstRep) external;

    function getPastVotesIndex(address account, uint timestamp) external view returns (uint32);

    function getLatestTokenIds(address account) external view returns (uint[] memory);
    function getTokenIdsAt(address account, uint32 index) external view returns (uint[] memory);
    function getTokenIdsAtTimestamp(address account, uint timestamp) external view returns (uint[] memory);
}