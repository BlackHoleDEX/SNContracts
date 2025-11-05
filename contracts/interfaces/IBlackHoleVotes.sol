// SPDX-License-Identifier: GPL-3.0-or-later
// BlackHole Foundation 2025

pragma solidity 0.8.13;

// import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

interface IBlackHoleVotes {

    /**
     * @dev Returns the current amount of votes that `account` has.
    */
    function getVotes(uint256 tokenId) external view returns (uint256);

    /**
     * @dev Returns the amount of votes that `account` had at a specific moment in the past. If the `clock()` is
     * configured to use block numbers, this will return the value at the end of the corresponding block.
     */
    function getPastVotes(uint256 tokenId, uint256 timepoint) external view returns (uint256);

    /**
     * @dev Returns the total supply of votes available at a specific moment in the past. If the `clock()` is
     * configured to use block numbers, this will return the value at the end of the corresponding block.
     *
     * NOTE: This value is the sum of all available votes.
     */
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256);


    function getsmNFTPastVotes(uint256 tokenId, uint256 timepoint) external view returns (uint256);

   
    function getsmNFTPastTotalSupply() external view returns (uint256);

    function calculate_sm_nft_bonus(uint amount) external view returns (uint);
}