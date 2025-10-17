// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

interface IPairGenerator {
    function factory() external view returns (address);
    function pairCodeHash() external pure returns (bytes32);
    function getInitializable() external view returns (address, address, bool);
    function createPair(address token0, address token1, bool stable) external returns (address pair);
}
