// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

import "./interfaces/IAlgebraPoolAPIStorage.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import './interfaces/IBribe.sol';
import './interfaces/IBribeFactory.sol';
import './interfaces/IERC20.sol';
import './interfaces/IGauge.sol';
import './interfaces/IGaugeCL.sol';
import './interfaces/IGaugeFactory.sol';
import './interfaces/IGaugeFactoryCL.sol';
import './interfaces/IGaugeManager.sol';
import './interfaces/IMinter.sol';
import './interfaces/IPairFactory.sol';
import './interfaces/IPairInfo.sol';
import './interfaces/IPermissionsRegistry.sol';
import './interfaces/ITokenHandler.sol';
import './interfaces/IVoter.sol';
import './interfaces/IVotingEscrow.sol';
import '@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol';
import '@cryptoalgebra/integral-core/contracts/interfaces/vault/IAlgebraCommunityVault.sol';
import '@cryptoalgebra/integral-farming/contracts/base/IncentiveKey.sol';
import '@cryptoalgebra/integral-farming/contracts/interfaces/IAlgebraEternalFarming.sol';
import {BlackTimeLibrary} from "./libraries/BlackTimeLibrary.sol";
import {IAlgebraCLFactory} from "./interfaces/IAlgebraCLFactory.sol";

contract GaugeManager is IGaugeManager, OwnableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeERC20Upgradeable for IERC20Upgradeable;
    address[] public pools;
    
    address public minter; 
    uint256 internal index; 
    address public base; 
    address public bribefactory; 
    address public _ve; 
    mapping(address => uint256) internal supplyIndex;              // gauge    => index
    mapping(address => uint256) public claimable;                  // gauge    => claimable $DEXTOKEN
    mapping(address => address) public gauges;                  // pool     => gauge
    mapping(address => uint256) public gaugesDistributionTimestmap;// gauge    => last Distribution Time
    mapping(address => address) public poolForGauge;            // gauge    => pool    
    mapping(address => address) public internal_bribes;         // gauge    => internal bribe (only fees)
    mapping(address => address) public external_bribes;         // gauge    => external bribe (real bribes)
    
    address public permissionRegistry;  
    address public voter;  
    address public tokenHandler;
    address public blackGovernor;
    address public algebraPoolAPIStorage;
    address public gaugeFactory;
    address public gaugeFactoryCL;
    address public pairFactory;
    address public pairFactoryCL;

    mapping(address => bool) public isGauge;                    // gauge    => boolean [is a gauge?]
    mapping(address => bool) public isCLGauge;
    mapping(address => bool) public isAlive;                    // gauge    => boolean [is the gauge alive?]
    IGaugeManager.FarmingParam public farmingParam;
    bytes16 public constant alphabet = "0123456789abcdef";

    event GaugeCreated(address indexed gauge, address creator, address internal_bribe, address indexed external_bribe, address indexed pool);
    event GaugeKilled(address indexed gauge);
    event GaugeRevived(address indexed gauge);
    event NotifyReward(address indexed sender, address indexed reward, uint256 amount);
    event DistributeReward(address indexed sender, address indexed gauge, uint256 amount);
    event SetMinter(address indexed old, address indexed latest);
    event SetBribeFactory(address indexed old, address indexed latest);
    event SetPermissionRegistry(address indexed old, address indexed latest);
    event SetAlgebraPoolAPIStorage(address indexed old, address indexed latest);
    event SetGaugeFactory(address indexed old, address indexed latest);
    event SetGaugeFactoryCL(address indexed old, address indexed latest);
    event SetPairFactory(address indexed old, address indexed latest);
    event SetPairFactoryCL(address indexed old, address indexed latest);
    event SetVoter(address indexed old, address indexed latest);
    event SetBlackGovernor(address indexed old, address indexed latest);
    mapping(address => uint256) public feeDistributionTimestmap;// gauge    => last Distribution Time

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address __ve, address _tokenHandler, address _gaugeFactory, address _gaugeFactoryCL, 
                        address _pairFactory, address _pairFactoryCL, address _permissionRegistory) initializer public {
     __Ownable_init();
     __ReentrancyGuard_init();
      _ve = __ve;  
      base = IVotingEscrow(__ve).token();  
      tokenHandler = _tokenHandler;
      permissionRegistry = _permissionRegistory;
      gaugeFactory = _gaugeFactory;
      gaugeFactoryCL = _gaugeFactoryCL;
      pairFactory = _pairFactory;
      pairFactoryCL = _pairFactoryCL;
    }

    modifier GaugeAdmin() {
        require(IPermissionsRegistry(permissionRegistry).hasRole("GAUGE_ADMIN",msg.sender), 'GAUGE_ADMIN');
        _;
    }

    modifier Governance() {
        require(IPermissionsRegistry(permissionRegistry).hasRole("GOVERNANCE",msg.sender), 'GOVERNANCE');
        _;
    }

    modifier EpochManagerOrGaugeAdmin() {
        require(IPermissionsRegistry(permissionRegistry).hasRole("EPOCH_MANAGER", msg.sender) || IPermissionsRegistry(permissionRegistry).hasRole("GAUGE_ADMIN",msg.sender), 'EPOCH_MANAGER_OR_GAUGE_ADMIN');
        _;
    }

    /// @notice Set a new Bribe Factory
    function setBribeFactory(address _bribeFactory) external GaugeAdmin {
        require(_bribeFactory.code.length > 0, "CODELEN");
        require(_bribeFactory != address(0), "ZA");
        emit SetBribeFactory(bribefactory, _bribeFactory);
        bribefactory = _bribeFactory;
    }

    /// @notice Set a new PermissionRegistry
    function setPermissionsRegistry(address _permissionRegistry) external onlyOwner {
        require(_permissionRegistry.code.length > 0, "CODELEN");
        require(_permissionRegistry != address(0), "ZA");
        emit SetPermissionRegistry(permissionRegistry, _permissionRegistry);
        permissionRegistry = _permissionRegistry;
    }

    /// @notice Set a new algebraPoolAPIStorage
    function setAlgebraPoolApiStorage(address _algebraPoolAPIStorage) external onlyOwner {
        require(_algebraPoolAPIStorage.code.length > 0, "CODELEN");
        require(_algebraPoolAPIStorage != address(0), "ZA");
        require(_algebraPoolAPIStorage != algebraPoolAPIStorage, "NA");
        emit SetAlgebraPoolAPIStorage(algebraPoolAPIStorage, _algebraPoolAPIStorage);
        algebraPoolAPIStorage = _algebraPoolAPIStorage;
    }

    function setVoter(address _voter) external GaugeAdmin{
        require(_voter.code.length > 0, "CODELEN");
        require(_voter != address(0), "ZA");
        emit SetVoter(voter, _voter);
        voter = _voter;
    }


    function getBlackGovernor() external view returns (address){
        return blackGovernor;
    }

    function setBlackGovernor(address _blackGovernor) external GaugeAdmin {
        require(_blackGovernor != address(0), "ZA");
        emit SetBlackGovernor(blackGovernor, _blackGovernor);
        blackGovernor = _blackGovernor;
    }
    
    /* -----------------------------------------------------------------------------
    --------------------------------------------------------------------------------
    --------------------------------------------------------------------------------
                                    GAUGE CREATION
    --------------------------------------------------------------------------------
    --------------------------------------------------------------------------------
    ----------------------------------------------------------------------------- */
    /// @notice create multiple gauges
    function createGauges(address[] memory _pool, uint256[] memory _gaugeTypes) external nonReentrant returns(address[] memory, address[] memory, address[] memory)  {
        uint poolLen = _pool.length;
        require(poolLen == _gaugeTypes.length, "MISMATCH_LEN");
        require(poolLen <= 10, "MAXVAL");
        address[] memory _gauge = new address[](poolLen);
        address[] memory _int = new address[](poolLen);
        address[] memory _ext = new address[](poolLen);

        uint i = 0;
        for(i; i < poolLen; i++){
            (_gauge[i], _int[i], _ext[i]) = _createGauge(_pool[i], _gaugeTypes[i], address(0));
        }
        return (_gauge, _int, _ext);
    }

    /// @notice create a gauge  
    function createGauge(address _pool, uint256 _gaugeType) external nonReentrant returns (address _gauge, address _internal_bribe, address _external_bribe)  {
        (_gauge, _internal_bribe, _external_bribe) = _createGauge(_pool, _gaugeType, address(0));
    }

    function createGaugeWithBonusReward(address _pool, uint256 _gaugeType, address bonusRewardToken) external nonReentrant returns (address _gauge, address _internal_bribe, address _external_bribe)  {
        (_gauge, _internal_bribe, _external_bribe) = _createGauge(_pool, _gaugeType, bonusRewardToken);
    }


    /// @notice create a gauge
    /// @param  _pool       LP address 
    /// @param  _gaugeType  the type of the gauge you want to create
    /// @dev    To create stable/Volatile pair gaugeType = 0, Concentrated liquidity = 1, ...
    ///         Make sure to use the corrcet gaugeType or it will fail

    function _createGauge(address _pool, uint256 _gaugeType, address bonusRewardToken) internal returns (address _gauge, address _internal_bribe, address _external_bribe) {
        require(gauges[_pool] == address(0x0), "DNE");
        require(_pool.code.length > 0, "CODELEN");
        bool isPair;

        address tokenA = address(0);
        address tokenB = address(0);

        // for future implementation add isPair() in factory
        if(_gaugeType == 0){
            isPair = IPairFactory(pairFactory).isPair(_pool);
        } 
        if(_gaugeType == 1) {
            /**
            As long as pools are created by our own custom pool deployer, we are allowing to create gauges.
            */
            address customDeployer = IAlgebraPoolAPIStorage(algebraPoolAPIStorage).pairToDeployer(_pool);
            if ((customDeployer != address(0))) {
                (tokenA) = IPairInfo(_pool).token0();
                (tokenB) = IPairInfo(_pool).token1();
                address _poolAddress = IAlgebraCLFactory(pairFactoryCL).customPoolByPair(customDeployer, tokenA, tokenB);
                isPair = (_poolAddress == _pool);
            }
        }

        if (isPair) {
            (tokenA) = IPairInfo(_pool).token0();
            (tokenB) = IPairInfo(_pool).token1();
            require(ITokenHandler(tokenHandler).isWhitelisted(tokenA) && ITokenHandler(tokenHandler).isWhitelisted(tokenB), "!WHITELISTED");
            require(ITokenHandler(tokenHandler).isConnector(tokenA) || ITokenHandler(tokenHandler).isConnector(tokenB), "!CONNECTOR");
        } 
        // If not a recognized pair/pool, only GaugeAdmin may proceed
        else {
            require(IPermissionsRegistry(permissionRegistry).hasRole("GAUGE_ADMIN",msg.sender), 'GAUGE_ADMIN');
            require(ITokenHandler(tokenHandler).isWhitelisted(_pool), "!WHITELISTED");
            _gaugeType = 0;
        }

        (_internal_bribe, _external_bribe) = _deployBribes(_pool, isPair? tokenA: _pool, isPair? tokenB: _pool, _gaugeType);
        // create basic pair gauge when gaugeType is 0 or not a recognized pair (To allow single token gauges)
        if(_gaugeType == 0) {
            _gauge = IGaugeFactory(gaugeFactory).createGauge(base, _ve, _pool, address(this), _internal_bribe, _external_bribe, isPair);
        }
        if(_gaugeType == 1) {
            if (bonusRewardToken == address(0)) {
                bonusRewardToken = base;
            }
            require(ITokenHandler(tokenHandler).isConnector(bonusRewardToken), "!BONUS_CONNECTOR");
            _gauge = IGaugeFactoryCL(gaugeFactoryCL).createGauge(base, _ve, _pool, address(this), _internal_bribe, _external_bribe, farmingParam, bonusRewardToken);
            isCLGauge[_gauge] = true;
            setGaugeAsCommunityFeeReceiver(_gauge, _pool);
        }
        // approve spending for $DEXTOKEN
        IERC20(base).approve(_gauge, type(uint256).max);
        _saveBribeData(_pool, _gauge, _internal_bribe, _external_bribe);
        emit GaugeCreated(_gauge, msg.sender, _internal_bribe, _external_bribe, _pool);
    }

    function _saveBribeData(address _pool, address _gauge, address _internal_bribe, address _external_bribe) private {
        // save data
        internal_bribes[_gauge] = _internal_bribe;
        external_bribes[_gauge] = _external_bribe;
        gauges[_pool] = _gauge;
        poolForGauge[_gauge] = _pool;
        isGauge[_gauge] = true;
        isAlive[_gauge] = true;
        pools.push(_pool);

        // update index 
        supplyIndex[_gauge] = index; // new gauges are set to the default global state
    }
    
    function _deployBribes(address _pool, address tokenA, address tokenB, uint256 _gaugeType) private returns (address _internal_bribe, address _external_bribe) 
    {
        // create internal and external bribe
        address _owner = IPermissionsRegistry(permissionRegistry).blackTeamMultisig();
        string memory _internalType;
        string memory _extrenalType;
        if(_gaugeType == 0) {
            _internalType =  string.concat("Supernova LP Fees: ", IERC20(_pool).symbol() );
            _extrenalType = string.concat("Supernova Bribes: ", IERC20(_pool).symbol() );
        }
        if(_gaugeType == 1) {
            string memory poolStr = addressToString(_pool);
            _internalType = string.concat("Supernova LP Fees: ", poolStr);
            _extrenalType = string.concat("Supernova Bribes: ", poolStr);
        }
        
        _internal_bribe = IBribeFactory(bribefactory).createBribe(_owner, tokenA, tokenB, _internalType);
        _external_bribe = IBribeFactory(bribefactory).createBribe(_owner, tokenA, tokenB, _extrenalType);
    }

    function addressToString(address _addr) internal pure returns (string memory) {
        bytes20 value = bytes20(_addr);

        bytes memory str = new bytes(42);
        str[0] = '0';
        str[1] = 'x';

        for (uint i = 0; i < 20; i++) {
            str[2 + i * 2] = alphabet[uint8(value[i] >> 4)];
            str[3 + i * 2] = alphabet[uint8(value[i] & 0x0f)];
        }

        return string(str);
    }


        // set Gauge Address as communityFeeReceiver in CommunityVault 
    function setGaugeAsCommunityFeeReceiver(address _gauge, address _pool) internal {
        address communityVault = IAlgebraPool(_pool).communityVault();
        IAlgebraCommunityVault(communityVault).changeCommunityFeeReceiver(_gauge);
    }

    /// @notice notify reward amount for gauge
    /// @dev    the function is called by the minter each epoch
    /// @param  amount  amount to distribute
    function notifyRewardAmount(uint256 amount) external {
        require(msg.sender == minter, "NA");
        IERC20Upgradeable(base).safeTransferFrom(msg.sender, address(this), amount);

        uint256 _ratio = 0;
        uint256 epochStart = BlackTimeLibrary.epochStart(block.timestamp);
        uint256 totalWeight = IVoter(voter).getEpochTotalWeight(epochStart);
        require(totalWeight > 0, "NO_EPOCH_WEIGHTS");
        _ratio = amount * 1e18 / totalWeight;     // 1e18 adjustment is removed during claim
        if (_ratio > 0) {
            index += _ratio;
        }

        emit NotifyReward(msg.sender, base, amount);
    }


    function carryForwardTotalVotesForNextEpoch() external nonReentrant EpochManagerOrGaugeAdmin {
        IVoter(voter).checkpointTotalWeightForNextEpoch();
    }

    function carryForwardVotesForNextEpoch(uint256 _start, uint256 _finish) external nonReentrant EpochManagerOrGaugeAdmin {
        for (uint256 x = _start; x < _finish; x++) {
            address _pool = pools[x];
            IVoter(voter).checkpointPoolWeightsForNextEpoch(_pool);
        }
    }

   function distributeFees(uint256 _start, uint256 _finish) external nonReentrant EpochManagerOrGaugeAdmin {
        for (uint256 x = _start; x < _finish; x++) {
            address _pool = pools[x];
            _distributeFees(_pool);
        }
    }


    function _distributeFees(address _pool) internal {
        uint256 lastTimestamp = feeDistributionTimestmap[_pool];
        uint256 currentTimestamp = BlackTimeLibrary.epochStart(block.timestamp);
        if(lastTimestamp < currentTimestamp){
            if (isGauge[gauges[_pool]] && isAlive[gauges[_pool]]){
                feeDistributionTimestmap[_pool] = currentTimestamp;
                if(!isCLGauge[gauges[_pool]]) {
                    IGauge(gauges[_pool]).claimFees();
                } else {
                    IAlgebraPool algebraPool = IAlgebraPool(_pool);
                    address _token0 = algebraPool.token0();
                    address _token1 = algebraPool.token1();
                    address communityVault = algebraPool.communityVault();
                    uint _balanceToken0 = IERC20(_token0).balanceOf(communityVault);
                    IAlgebraCommunityVault(communityVault).withdraw(_token0, _balanceToken0);
                    
                    uint _balanceToken1 = IERC20(_token1).balanceOf(communityVault);
                    IAlgebraCommunityVault(communityVault).withdraw(_token1, _balanceToken1);
                    IGaugeCL(gauges[_pool]).claimFees();
                }
            }
        }
    }


    function distribute(uint256 _start, uint256 _finish) external nonReentrant EpochManagerOrGaugeAdmin {
        IMinter(minter).update_period();
        for (uint256 x = _start; x < _finish; x++) {
            _distribute(gauges[pools[x]]);
        }
    }

    /// @notice distribute the emission
    function _distribute(address _gauge) internal {

        uint256 lastTimestamp = gaugesDistributionTimestmap[_gauge];
        uint256 currentTimestamp = BlackTimeLibrary.epochStart(block.timestamp);
        if(lastTimestamp < currentTimestamp){
            _updateForAfterDistribution(_gauge); // should set claimable to 0 if killed

            uint256 _claimable = claimable[_gauge];

            // distribute only if claimable is > 0, currentEpoch != lastepoch and gauge is alive
            if (_claimable > 0 && isAlive[_gauge] && !IGauge(_gauge).emergency()) {
                claimable[_gauge] = 0;
                gaugesDistributionTimestmap[_gauge] = currentTimestamp;
                if(!isCLGauge[_gauge]) {
                    IGauge(_gauge).notifyRewardAmount(base, _claimable);
                } else {
                    (IncentiveKey memory incentivekey, uint256 rewardRate, uint128 bonusRewardRate) = 
                        IGaugeCL(_gauge).notifyRewardAmount(base, _claimable);
                    IAlgebraEternalFarming(farmingParam.algebraEternalFarming).setRates(incentivekey, uint128(rewardRate), bonusRewardRate);
                }
                emit DistributeReward(msg.sender, _gauge, _claimable);
            }
        }
    }

    /// @notice distribute rewards for given gauges and rewards
    function distributeRewards(address[] memory _gauges, uint256[] memory _rewards) external nonReentrant GaugeAdmin {
        require(_gauges.length == _rewards.length, "Length mismatch");
        // tranfer total rewards amount to this address
        uint256 totalRewards = 0;
        for (uint256 x = 0; x < _rewards.length; x++) {
            totalRewards += _rewards[x];
        }
        IERC20Upgradeable(base).safeTransferFrom(msg.sender, address(this), totalRewards);        
        for (uint256 x = 0; x < _gauges.length; x++) {
            if(!isCLGauge[_gauges[x]]) {
                IGauge(_gauges[x]).notifyRewardAmount(base, _rewards[x]);
            } else {
                (IncentiveKey memory incentivekey, uint256 rewardRate, uint128 bonusRewardRate) =
                    IGaugeCL(_gauges[x]).notifyRewardAmount(base, _rewards[x]);
                IAlgebraEternalFarming(farmingParam.algebraEternalFarming).setRates(incentivekey, uint128(rewardRate), bonusRewardRate);
            }
            emit DistributeReward(msg.sender, _gauges[x], _rewards[x]);
        }
    }


    /* -----------------------------------------------------------------------------
    --------------------------------------------------------------------------------
    --------------------------------------------------------------------------------
                                    HELPERS
    --------------------------------------------------------------------------------
    --------------------------------------------------------------------------------
    ----------------------------------------------------------------------------- */
 
  
    /// @notice update info for gauges
    /// @dev    this function track the gauge index to emit the correct $DEXTOKEN amount after the distribution
    function _updateForAfterDistribution(address _gauge) private {
        address _pool = poolForGauge[_gauge];
        //uint256 _supplied = weightsPerEpoch[_time][_pool];
        uint256 epochStart = BlackTimeLibrary.epochStart(block.timestamp);
        uint256 _supplied = IVoter(voter).getEpochPoolWeight(epochStart, _pool);

        if (_supplied > 0) {
            uint256 _supplyIndex = supplyIndex[_gauge];
            uint256 _index = index; // get global index0 for accumulated distro
            // SupplyIndex will be updated for Killed Gauges as well so we don't need to update index while reviving gauge.
            supplyIndex[_gauge] = _index; // update _gauge current position to global position
            uint256 _delta = _index - _supplyIndex; // see if there is any difference that need to be accrued
            if (_delta > 0) {
                uint256 _share = _supplied * _delta / 1e18; // add accrued difference for each supplied token
                if (isAlive[_gauge]) {
                    claimable[_gauge] += _share;
                } else {
                    IERC20Upgradeable(base).safeTransfer(minter, _share); // send rewards back to Minter so they're not stuck in GaugeManager
                }
            }
        } else {
            supplyIndex[_gauge] = index; // new users are set to the default global state
        }
    }

    /* -----------------------------------------------------------------------------
    --------------------------------------------------------------------------------
    --------------------------------------------------------------------------------
                                    GOVERNANCE
    --------------------------------------------------------------------------------
    --------------------------------------------------------------------------------
    ----------------------------------------------------------------------------- */
    

     /// @notice Kill a malicious gauge 
    /// @param  _gauge gauge to kill
    function killGauge(address _gauge) external Governance {
        require(isAlive[_gauge], "DEAD");
        isAlive[_gauge] = false;

        // Return claimable back to minter
        uint256 _claimable = claimable[_gauge];
        claimable[_gauge] = 0;
        if (_claimable > 0) {
            IERC20Upgradeable(base).safeTransfer(minter, _claimable);
        }
        // Reset allowance for killed gauge
        IERC20(base).approve(_gauge, 0);

        // We shouldn't update totalWeight because if we decrease it other pools will get more emission while in current scenario 
        // emissionAmount of killed gauge will get transferred back to Minter
        // We're decreasing totalWeight in case of Reset functionality while resetting vote from killed gauge.
        //totalWeight = totalWeight - weights[poolForGauge[_gauge]];
        emit GaugeKilled(_gauge);
    }

    /// @notice Revive a malicious gauge 
    /// @param  _gauge gauge to revive
    function reviveGauge(address _gauge) external Governance {
        require(!isAlive[_gauge], "ALIVE");
        require(isGauge[_gauge], 'NOT_GAUGE');
        isAlive[_gauge] = true;

        // Restore allowance for revived gauge
        IERC20(base).approve(_gauge, type(uint256).max);
        emit GaugeRevived(_gauge);
    }


    function setFarmingParam(address _farmingCenter, address _algebraEternalFarming, address _nfpm) external GaugeAdmin {
        farmingParam = IGaugeManager.FarmingParam(_farmingCenter, _algebraEternalFarming, _nfpm);
    }

    /// @notice claim LP gauge rewards
    function claimRewards(address[] memory _gauges) external {
        uint gaugesLen = _gauges.length;
        for (uint256 i = 0; i < gaugesLen; i++) {
            IGauge(_gauges[i]).getReward(msg.sender);
        }
    }


    /// @notice claim bribes rewards given a TokenID
    function claimBribes(address[] memory _bribes, address[][] memory _tokens, uint256 _tokenId) external {
        require(IVotingEscrow(_ve).isApprovedOrOwner(msg.sender, _tokenId), "NAO");
        uint bribesLen = _bribes.length;
        for (uint256 i = 0; i < bribesLen; i++) {
            IBribe(_bribes[i]).getReward(_tokenId, _tokens[i]);
        }
    }

    function fetchInternalBribeFromPool(address _pool) external view returns (address) {
        return internal_bribes[gauges[_pool]];
    }

    function fetchExternalBribeFromPool(address _pool) external view returns (address) {
        return external_bribes[gauges[_pool]];
    }

    function isGaugeAliveForPool(address _pool) external view returns (bool) {
        return isGauge[gauges[_pool]] && isAlive[gauges[_pool]];
    }

        /// @notice Set a new Minter
    function setMinter(address _minter) external GaugeAdmin {
        require(_minter != address(0), "ZA");
        require(_minter.code.length > 0, "CODELEN");
        emit SetMinter(minter, _minter);
        minter = _minter;
    }

    function updateGaugeFactory(address _gaugeFactory) external GaugeAdmin {
        require(_gaugeFactory != address(0), "ZA");
        require(_gaugeFactory.code.length > 0, "CODELEN");
        require(_gaugeFactory != gaugeFactory, "NA");
        emit SetGaugeFactory(gaugeFactory, _gaugeFactory);
        gaugeFactory = _gaugeFactory;
    }

    function updateGaugeFactoryCL(address _gaugeFactoryCL) external GaugeAdmin {
        require(_gaugeFactoryCL != address(0), "ZA");
        require(_gaugeFactoryCL.code.length > 0, "CODELEN");
        require(_gaugeFactoryCL != gaugeFactoryCL, "NA");
        emit SetGaugeFactoryCL(gaugeFactoryCL, _gaugeFactoryCL);
        gaugeFactoryCL = _gaugeFactoryCL;
    }

    function updatePairFactory(address _pairFactory) external GaugeAdmin {
        require(_pairFactory != address(0), "ZA");
        require(_pairFactory.code.length > 0, "CODELEN");
        require(_pairFactory != pairFactory, "NA");
        emit SetPairFactory(pairFactory, _pairFactory);
        pairFactory = _pairFactory;
    }

    function updatePairFactoryCL(address _pairFactoryCL) external GaugeAdmin {
        require(_pairFactoryCL != address(0), "ZA");
        require(_pairFactoryCL.code.length > 0, "CODELEN");
        require(_pairFactoryCL != pairFactoryCL, "NA");
        emit SetPairFactoryCL(pairFactoryCL, _pairFactoryCL);
        pairFactoryCL = _pairFactoryCL;
    }

    function acceptAlgebraFeeChangeProposal (address _pool, uint16 newAlgebraFee) external GaugeAdmin {
        address communityVault = IAlgebraPool(_pool).communityVault();
        IAlgebraCommunityVault(communityVault).acceptAlgebraFeeChangeProposal(newAlgebraFee);
    }

    function length() external view returns(uint) {
        return pools.length;
    }
}