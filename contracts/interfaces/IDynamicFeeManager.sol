pragma solidity ^0.8.13;

interface IDyanmicFeeManager {
    function feeConfig() external view returns (uint16 alpha1, uint16 alpha2, uint32 beta1, uint32 beta2, uint16 gamma1, uint16 gamma2, uint16 baseFee);
}
