// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

import './Pair.sol';
import './interfaces/IPairGenerator.sol';

contract PairGenerator is IPairGenerator {

    address public factory;

    address internal _temp0;
    address internal _temp1;
    bool internal _temp;

    event PairCreated(address indexed token0, address indexed token1, bool stable, address pair);

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
    }

    function pairCodeHash() external pure returns (bytes32) {
        return keccak256(type(Pair).creationCode);
    }

    function getInitializable() external view returns (address, address, bool) {
        return (_temp0, _temp1, _temp);
    }

    function createPair(address token0, address token1, bool stable) external onlyFactory returns (address pair) {
        bytes32 salt = keccak256(abi.encodePacked(token0, token1, stable)); // notice salt includes stable as well, 3 parameters
        (_temp0, _temp1, _temp) = (token0, token1, stable);
        pair = address(new Pair{salt:salt}());
        emit PairCreated(token0, token1, stable, pair);
    }
}