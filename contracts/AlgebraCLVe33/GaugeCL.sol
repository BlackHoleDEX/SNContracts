// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import '@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol';

import '../interfaces/IAlgebraEternalFarmingCustom.sol';

import '../interfaces/IAlgebraCustomCommunityVault.sol';
import '../interfaces/IGaugeFactoryCL.sol';
import '../interfaces/IGaugeManager.sol';
import '@cryptoalgebra/integral-periphery/contracts/interfaces/INonfungiblePositionManager.sol';
import '@cryptoalgebra/integral-farming/contracts/interfaces/IAlgebraEternalFarming.sol';
import '@cryptoalgebra/integral-farming/contracts/interfaces/IAlgebraEternalVirtualPool.sol';
import '@cryptoalgebra/integral-farming/contracts/interfaces/IFarmingCenter.sol';
import '@cryptoalgebra/integral-farming/contracts/base/IncentiveKey.sol';
import '@cryptoalgebra/integral-core/contracts/interfaces/IERC20Minimal.sol';

import '../interfaces/IBribe.sol';
import {BlackTimeLibrary} from "../libraries/BlackTimeLibrary.sol";
import {IncentiveId} from '@cryptoalgebra/integral-farming/contracts/libraries/IncentiveId.sol';
import {REFERRAL_FEE_DENOMINATOR} from '../libraries/Constants.sol';
import '../interfaces/IGaugeCL.sol';

contract GaugeCL is ReentrancyGuard, Ownable, IGaugeCL {

    using SafeERC20 for IERC20;
    
    IERC20 public immutable rewardToken;
    IERC20 public immutable bonusRewardToken;
    address public immutable VE;
    address public immutable DISTRIBUTION;
    address public immutable internal_bribe;
    address public immutable external_bribe;

    uint256 public immutable DURATION;
    uint256 internal _periodFinish;
    uint256 public rewardRate;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    IFarmingCenter public immutable farmingCenter;
    IAlgebraEternalFarming public immutable algebraEternalFarming;
    IAlgebraPool public immutable algebraPool;
    address public immutable poolAddress;
    INonfungiblePositionManager public immutable nonfungiblePositionManager;


    bool public emergency;
    address immutable factory;
    uint16 private constant ALGEBRA_FEE_DENOMINATOR = 1000;

    event RewardAdded(uint256 reward);
    event Deposit(address indexed user, uint256 amount);
    event Withdraw(address indexed user, uint256 amount);
    event Harvest(address indexed user, uint256 reward);
    event ClaimFees(address indexed from, uint256 claimed0, uint256 claimed1);
    event EmergencyActivated();
    event EmergencyDeactivated();

    constructor(address _rewardToken, address _ve, address _pool, address _distribution, address _internal_bribe, 
        address _external_bribe, IGaugeManager.FarmingParam memory _farmingParam, address _bonusRewardToken, address _factory) {
        factory = _factory;
        rewardToken = IERC20(_rewardToken);     // main reward
        bonusRewardToken = IERC20(_bonusRewardToken);
        VE = _ve;                               // vested
        poolAddress = _pool;
        algebraPool = IAlgebraPool(_pool);
        DISTRIBUTION = _distribution;           // distro address (GaugeManager)
        DURATION = BlackTimeLibrary.WEEK;                   

        internal_bribe = _internal_bribe;       // lp fees goes here
        external_bribe = _external_bribe;       // bribe fees goes here
        farmingCenter = IFarmingCenter(_farmingParam.farmingCenter);
        algebraEternalFarming = IAlgebraEternalFarming(_farmingParam.algebraEternalFarming);
        nonfungiblePositionManager = INonfungiblePositionManager(_farmingParam.nfpm);
        emergency = false;
    }

    modifier onlyDistribution() {
        require(msg.sender == DISTRIBUTION, "NA");
        _;
    }

    modifier isNotEmergency() {
        require(!emergency, "emergency");
        _;
    }

    function activateEmergencyMode() external onlyOwner {
        require(!emergency, "emergency");
        emergency = true;
        emit EmergencyActivated();
    }

    function stopEmergencyMode() external onlyOwner {
        require(emergency, "emergency");
        emergency = false;
        emit EmergencyDeactivated();
    }

    function balanceOf(uint256 tokenId) external view returns (uint256) {
        (IERC20Minimal rewardTokenAdd, IERC20Minimal bonusRewardTokenAdd, IAlgebraPool pool, uint256 nonce) = 
                algebraEternalFarming.incentiveKeys(poolAddress);
        IncentiveKey memory incentivekey = IncentiveKey(rewardTokenAdd, bonusRewardTokenAdd, pool, nonce);
        (uint128 liquidity,,,,) = algebraEternalFarming.farms(tokenId, IncentiveId.compute(incentivekey));
        return liquidity;
    }

    function earned(uint256 tokenId) external view returns (uint256 reward, uint256 bonusReward) {

        (IERC20Minimal rewardTokenAdd, IERC20Minimal bonusRewardTokenAdd, IAlgebraPool pool, uint256 nonce) = 
                algebraEternalFarming.incentiveKeys(poolAddress);
        IncentiveKey memory incentivekey = IncentiveKey(rewardTokenAdd, bonusRewardTokenAdd, pool, nonce);
        /// @notice reward amounts can be outdated by using getRewardInfo, actual amounts could be obtained via static call of `collectRewards` in FarmingCenter
        (reward, bonusReward) = IAlgebraEternalFarmingCustom(address(algebraEternalFarming)).getRewardInfo(incentivekey, tokenId);
        return (reward, bonusReward);
    }

    function deposit(uint256 tokenId) external nonReentrant isNotEmergency {
        require(msg.sender == nonfungiblePositionManager.ownerOf(tokenId));
        
        nonfungiblePositionManager.approveForFarming(tokenId, true, address(farmingCenter));

        (IERC20Minimal rewardTokenAdd, IERC20Minimal bonusRewardTokenAdd, IAlgebraPool pool, uint256 nonce) = 
                algebraEternalFarming.incentiveKeys(poolAddress);
        IncentiveKey memory incentivekey = IncentiveKey(rewardTokenAdd, bonusRewardTokenAdd, pool, nonce);
        farmingCenter.enterFarming(incentivekey, tokenId);
        emit Deposit(msg.sender, tokenId);
    }

    function withdraw(uint256 tokenId) external nonReentrant isNotEmergency {
        require(msg.sender == nonfungiblePositionManager.ownerOf(tokenId));
        
        (IERC20Minimal rewardTokenAdd, IERC20Minimal bonusRewardTokenAdd, IAlgebraPool pool, uint256 nonce) = 
                algebraEternalFarming.incentiveKeys(poolAddress);
        IncentiveKey memory incentivekey = IncentiveKey(rewardTokenAdd, bonusRewardTokenAdd, pool, nonce);
        farmingCenter.exitFarming(incentivekey, tokenId);
        emit Withdraw(msg.sender, tokenId);
    }

    function notifyRewardAmount(address token, uint256 reward) external nonReentrant 
        isNotEmergency onlyDistribution returns (IncentiveKey memory, uint256, uint128) {
        require(token == address(rewardToken), "not rew token");
        // Transfer emission to Farming Virtual Pool address
        uint256 duration = BlackTimeLibrary.epochNext(block.timestamp) - block.timestamp;
        if (block.timestamp >= _periodFinish) {
            rewardRate = reward / duration;
        } else {
            uint256 leftover = duration * rewardRate;
            rewardRate = (reward + leftover) / duration;
        }
        _periodFinish = BlackTimeLibrary.epochNext(block.timestamp);
        (IERC20Minimal rewardTokenAdd, IERC20Minimal bonusRewardTokenAdd, IAlgebraPool pool, uint256 nonce) = 
                algebraEternalFarming.incentiveKeys(poolAddress);
        IncentiveKey memory incentivekey = IncentiveKey(rewardTokenAdd, bonusRewardTokenAdd, pool, nonce);
        
        // set RewardRate to AlgebraVirtual Pool
        (,,address virtualPoolAddress,,,) = algebraEternalFarming.incentives(IncentiveId.compute(incentivekey));
        (,uint128 bonusRewardRate) = IAlgebraEternalVirtualPool(virtualPoolAddress).rewardRates();
        
        rewardToken.safeTransferFrom(msg.sender, address(this), reward);
        IERC20(token).forceApprove(address(algebraEternalFarming), reward);
        // transfer emission Reward to Algebra Virtual Pool
        algebraEternalFarming.addRewards(incentivekey, uint128(reward), 0);
        emit RewardAdded(reward);
        return(incentivekey, rewardRate, bonusRewardRate);
    }

    function gaugeBalances() external view returns (uint256 token0, uint256 token1){
        address _token0 = algebraPool.token0();
        address _token1 = algebraPool.token1();
        token0 = IERC20(_token0).balanceOf(address(this));
        token1 = IERC20(_token1).balanceOf(address(this));
    }


    function claimFees() external nonReentrant returns (uint256 claimed0, uint256 claimed1) {
        return _claimFees();
    }

    function _claimFees() internal returns (uint256 claimed0, uint256 claimed1) {
        address _token0 = algebraPool.token0();
        address _token1 = algebraPool.token1();
        // Fetch fee from the whole epoch which just ended and transfer it to internal Bribe address.
        claimed0 = IERC20(_token0).balanceOf(address(this));
        claimed1 = IERC20(_token1).balanceOf(address(this));

        if (claimed0 > 0 || claimed1 > 0) {
            // Deduct dibsPercentage from fee accrued and transfer to dibs address(Foundation address)
            
            uint256 referralFee = IGaugeFactoryCL(factory).dibsPercentage();
            address dibs = IGaugeFactoryCL(factory).dibs();
            uint256 _dibsFeeToken0 = (dibs != address(0)) ? (claimed0 * referralFee / REFERRAL_FEE_DENOMINATOR) : 0;
            uint256 _dibsFeeToken1 = (dibs != address(0)) ? (claimed1 * referralFee / REFERRAL_FEE_DENOMINATOR) : 0;

            if (_dibsFeeToken0 > 0) {
                _safeTransfer(_token0, dibs, _dibsFeeToken0); // Transfer dibs fees
                claimed0 = claimed0 - _dibsFeeToken0;
            }

            if (_dibsFeeToken1 > 0) {
                _safeTransfer(_token1, dibs, _dibsFeeToken1); // Transfer dibs fees
                claimed1 =  claimed1 - _dibsFeeToken1;
            }

            if (claimed0  > 0) {
                IERC20(_token0).forceApprove(internal_bribe, claimed0);
                IBribe(internal_bribe).notifyRewardAmount(_token0, claimed0);
            } 
            if (claimed1  > 0) {
                IERC20(_token1).forceApprove(internal_bribe, claimed1);
                IBribe(internal_bribe).notifyRewardAmount(_token1, claimed1);
            } 
            emit ClaimFees(msg.sender, claimed0, claimed1);
        }
    }

    ///@notice get total reward for the duration
    function rewardForDuration() external view returns (uint256) {
        return rewardRate * DURATION;
    }

    function _safeTransfer(address token,address to,uint256 value) internal {
        require(token.code.length > 0);
        (bool success, bytes memory data) = token.call(abi.encodeCall(IERC20.transfer, (to, value)));
        require(success && (data.length == 0 || abi.decode(data, (bool))));
    }

    function stakedFees() external view returns (uint256 totalFeeToken0, uint256 totalFeeToken1) {
        // Balance of token0/token1 at Gauge Address and AlgebraCommunityVault address.
        
        uint256 gaugeAccruedFeeToken0 = IERC20(algebraPool.token0()).balanceOf(address(this));
        uint256 gaugeAccruedFeeToken1 = IERC20(algebraPool.token1()).balanceOf(address(this));
        (uint256 communityVaultAccruedFeeToken0, uint256 communityVaultAccruedFeeToken1) 
                = getCommunityVaultAccruedFee();

        totalFeeToken0 = gaugeAccruedFeeToken0 + communityVaultAccruedFeeToken0;
        totalFeeToken1 = gaugeAccruedFeeToken1 + communityVaultAccruedFeeToken1;
        
        uint256 referralFee = IGaugeFactoryCL(factory).dibsPercentage();
        address dibs = IGaugeFactoryCL(factory).dibs();
        uint256 _dibsFeeToken0 = (dibs != address(0)) ? (totalFeeToken0 * referralFee / REFERRAL_FEE_DENOMINATOR) : 0;
        uint256 _dibsFeeToken1 = (dibs != address(0)) ? (totalFeeToken1 * referralFee / REFERRAL_FEE_DENOMINATOR) : 0;
        
        totalFeeToken0 -= _dibsFeeToken0;
        totalFeeToken1 -= _dibsFeeToken1;
    }

    function getCommunityVaultAccruedFee() internal view returns (uint256 communityVaultAccruedFeeToken0, uint256 communityVaultAccruedFeeToken1) {
        address communityVaultAddress = algebraPool.communityVault();
        communityVaultAccruedFeeToken0 = IERC20(algebraPool.token0()).balanceOf(communityVaultAddress);
        communityVaultAccruedFeeToken1 = IERC20(algebraPool.token1()).balanceOf(communityVaultAddress);

        (uint128 communityFeePending0, uint128 communityFeePending1) = algebraPool.getCommunityFeePending();
        communityVaultAccruedFeeToken0 += communityFeePending0;
        communityVaultAccruedFeeToken1 += communityFeePending1;

        uint16 algebraFee = IAlgebraCustomCommunityVault(communityVaultAddress).algebraFee();
        uint256 algebraFeeToken0 = communityVaultAccruedFeeToken0 * algebraFee / ALGEBRA_FEE_DENOMINATOR;
        uint256 algebraFeeToken1 = communityVaultAccruedFeeToken1 * algebraFee / ALGEBRA_FEE_DENOMINATOR;
        communityVaultAccruedFeeToken0 -= algebraFeeToken0;
        communityVaultAccruedFeeToken1 -= algebraFeeToken1;
    }

    ///@notice total liquidity in the active tick
    function totalActiveSupply() public view returns (uint256 _totalActiveSupply) {
        (IERC20Minimal rewardTokenAdd, IERC20Minimal bonusRewardTokenAdd, IAlgebraPool pool, uint256 nonce) = 
            algebraEternalFarming.incentiveKeys(poolAddress);
        IncentiveKey memory incentivekey = IncentiveKey(rewardTokenAdd, bonusRewardTokenAdd, pool, nonce);
        bytes32 incentiveId = IncentiveId.compute(incentivekey);
        
        // set RewardRate to AlgebraVirtual Pool
        (,,address virtualPoolAddress,,,) = algebraEternalFarming.incentives(incentiveId);
        _totalActiveSupply = IAlgebraEternalVirtualPool(virtualPoolAddress).currentLiquidity();    
    }

}


