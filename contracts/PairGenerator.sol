// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

import './Pair.sol';
import './interfaces/IPairGenerator.sol';

contract PairGenerator is IPairGenerator {

    address public factory;

    address internal _tempToken0;
    address internal _tempToken1;
    bool internal _tempStable;

    event PairCreated(address indexed token0, address indexed token1, bool stable, address pair);
    event UpdateFactory(address indexed factory);
    constructor(){
        factory = msg.sender; // Deployer becomes the factory initially
    }

    modifier onlyFactory(){
        require(msg.sender == factory, "!factory");
        _;
    }

    function setFactory(address _factory) external onlyFactory {
        require(_factory != address(0), "Invalid factory address");
        factory = _factory;
        emit UpdateFactory(_factory);
    }

    function pairCodeHash() external pure returns (bytes32) {
        return keccak256(type(Pair).creationCode);
    }

    function getInitializable() external view returns (address, address, bool) {
        return (_tempToken0, _tempToken1, _tempStable);
    }

    function createPair(address token0, address token1, bool stable) external onlyFactory returns (address pair) {
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, stable)); // notice salt includes stable as well, 3 parameters
        (_tempToken0, _tempToken1, _tempStable) = (token0, token1, stable);
        pair = address(new Pair{salt:salt}());
        emit PairCreated(token0, token1, stable, pair);
    }
}