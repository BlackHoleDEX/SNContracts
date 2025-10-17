// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;


import '../libraries/Math.sol';
import '../interfaces/IBribeAPI.sol';
import '../interfaces/IGaugeAPI.sol';

import '../interfaces/IGaugeFactory.sol';
import '../interfaces/IERC20.sol';
import '../interfaces/IMinter.sol';
import '../interfaces/IPair.sol';
import '../interfaces/IPairInfo.sol';
import '../interfaces/IPairFactory.sol';
import '../interfaces/IVoter.sol';
import '../interfaces/IGaugeManager.sol';
import '../interfaces/IVotingEscrow.sol';
import '../../contracts/Pair.sol';
import '../interfaces/IRouter.sol';
import '../interfaces/IAlgebraPoolAPIStorage.sol';

import '../interfaces/IAlgebraCLFactory.sol';

import '@cryptoalgebra/integral-periphery/contracts/interfaces/IQuoterV2.sol';
import '@cryptoalgebra/integral-core/contracts/interfaces/IAlgebraPool.sol';

import "hardhat/console.sol";

import {BlackTimeLibrary} from "../libraries/BlackTimeLibrary.sol";

contract BlackholePairAPIV2 {

    struct pairInfo {
        // pair info
        address pair_address; 			// pair contract address
        string symbol; 				    // pair symbol
        string name;                    // pair name
        uint decimals; 			        // pair decimals
        bool stable; 				    // pair pool type (stable = false, means it's a variable type of pool)
        uint total_supply; 			    // pair tokens supply
    
        // token pair info
        address token0; 				// pair 1st token address
        string token0_symbol; 			// pair 1st token symbol
        uint token0_decimals; 		    // pair 1st token decimals
        uint reserve0; 			        // pair 1st token reserves (nr. of tokens in the contract)
        uint claimable0;                // claimable 1st token from fees (for unstaked positions)

        address token1; 				// pair 2nd token address
        string token1_symbol;           // pair 2nd token symbol
        uint token1_decimals;    		// pair 2nd token decimals
        uint reserve1; 			        // pair 2nd token reserves (nr. of tokens in the contract)
        uint claimable1; 			    // claimable 2nd token from fees (for unstaked positions)

        // pairs gauge
        address gauge; 				    // pair gauge address
        uint gauge_total_supply; 		// pair staked tokens (less/eq than/to pair total supply)
        uint emissions; 			    // pair emissions (per second)
        uint total_emissions; 			// total pair emissions (per second)
        address emissions_token; 		// pair emissions token address
        uint emissions_token_decimals; 	// pair emissions token decimals

        // User deposit
        uint account_lp_balance; 		// account LP tokens balance
        uint account_token0_balance; 	// account 1st token balance
        uint account_token1_balance; 	// account 2nd token balance
        uint account_gauge_balance;     // account pair staked in gauge balance
        uint account_gauge_earned; 		// account earned emissions for this pair

        uint account_staked_unlock;     // account pair staked in gauge balance

        // votes
        uint votes;

        // fees
        uint staked_token0_fees;      // staked token 0 fees accumulated till now
        uint staked_token1_fees;      // staked token 1 fees accumulated till now

        // bribes
        Bribes internal_bribes;
        Bribes external_bribes;
    }

    struct tokenBribe {
        address token;
        uint8 decimals;
        uint256 amount;
        string symbol;
    }
    

    struct pairBribeEpoch {
        uint256 epochTimestamp;
        uint256 totalVotes;
        address pair;
        tokenBribe[] bribes;
    }

    struct Bribes {
        address bribeAddress;
        address[] tokens;
        string[] symbols;
        uint[] decimals;
        uint[] amounts;
    }

    struct Rewards {
        Bribes[] bribes;
    }

    struct swapRoute{
        uint amountOut;
        uint hops;
        route[] routes;
    }

    struct route {
        address pair;
        address from;
        address to;
        bool stable;
        bool concentrated;
        uint amountOut;
        address receiver;
        uint160 sqrtPriceAfter;
    }

    struct SwapRouteHelperData {
        address _pair1;
        address _pair2;
        address _pairMid;
        bool isBasic1;
        bool isBasic2; 
        bool isBasicMid; 
        address otherToken1;
        address otherToken2;
        uint256 minAmount;
        bool foundPath;
        uint deployersLength;
        uint tempAmountOut;
        uint160 sqrtPriceAfter;
    }

    struct CLOutputData {
        uint256 amountOut;
        uint256 amountIn;
        uint160 sqrtPriceX96After;
        uint32 initializedTicksCrossed;
        uint256 gasEstimate;
        uint16 fee;
    }

    uint256 public constant MAX_PAIRS = 1000;
    uint256 public constant MAX_EPOCHS = 200;
    uint256 public constant MAX_REWARDS = 16;

    IPairFactory public pairFactory;
    IAlgebraCLFactory public algebraFactory;
    IQuoterV2 public quoterV2;

    IVoter public voter;
    IGaugeManager public gaugeManager;
    address public routerV2;
    IAlgebraPoolAPIStorage public algebraPoolAPIStorage;

    address public underlyingToken;

    address public owner;


    event Owner(address oldOwner, address newOwner);
    event Voter(address oldVoter, address newVoter);
    event GaugeManager(address oldGaugeManager, address newGaugeManager);
    event WBF(address oldWBF, address newWBF);
    event swapped(address pairAddress);

    constructor(address _voter, address _router, address _gaugeManager, address _pairFactory, address _algebraFactory, address _quoterV2, address _algebraPoolAPIStorage) {

        owner = msg.sender;

        voter = IVoter(_voter);
        gaugeManager = IGaugeManager(_gaugeManager);

        routerV2 = _router;

        algebraFactory = IAlgebraCLFactory(_algebraFactory);

        algebraPoolAPIStorage = IAlgebraPoolAPIStorage(_algebraPoolAPIStorage);

        quoterV2 = IQuoterV2(_quoterV2);

        pairFactory = IPairFactory(_pairFactory);
        underlyingToken = IVotingEscrow(voter._ve()).token();
    }

    function getClaimable(address _account, address _pair) internal view returns(uint claimable0, uint claimable1){

        if(address(_account) == address(0)){
            return (0,0);
        }
        
        Pair pair = Pair(_pair);

        uint _supplied = pair.balanceOf(_account); // get LP balance of `_user`
        uint _claim0 = pair.claimable0(_account);
        uint _claim1 = pair.claimable1(_account);
        if (_supplied > 0) {
            uint _supplyIndex0 = pair.supplyIndex0(_account); // get last adjusted index0 for recipient
            uint _supplyIndex1 = pair.supplyIndex1(_account);
            uint _index0 = pair.index0(); // get global index0 for accumulated fees
            uint _index1 = pair.index1();
            uint _delta0 = _index0 - _supplyIndex0; // see if there is any difference that need to be accrued
            uint _delta1 = _index1 - _supplyIndex1;
            if (_delta0 > 0) {
                _claim0 += _supplied * _delta0 / 1e18; // add accrued difference for each supplied token
            }
            if (_delta1 > 0) {
                _claim1 += _supplied * _delta1 / 1e18;
            }
        } 

        return (_claim0, _claim1);
    }


    // valid only for sAMM and vAMM
    function getAllPair(address _user, uint _amounts, uint _offset) external view returns(uint totPairs, bool hasNext, pairInfo[] memory pairs, uint epochDuration){

        
        require(_amounts <= MAX_PAIRS, 'tp');

        pairs = new pairInfo[](_amounts);
        
        uint i = _offset;
        totPairs = pairFactory.allPairsLength();
        hasNext = true;
        address _pair;
        uint claim0;
        uint claim1;
        uint stakedToken0Fees;     
        uint stakedToken1Fees; 
        Bribes[] memory bribes;
        epochDuration = BlackTimeLibrary.WEEK;

        for(i; i < _offset + _amounts; i++){
            // if totalPairs is reached, break.
            if(i >= totPairs) {
                hasNext = false;
                break;
            }
            _pair = pairFactory.allPairs(i);
            pairs[i - _offset] = _pairAddressToInfo(_pair, _user);

            (claim0, claim1) = getClaimable(_user, _pair);
            pairs[i - _offset].claimable0 = claim0;
            pairs[i - _offset].claimable1 = claim1;

            (stakedToken0Fees, stakedToken1Fees) = getClaimable(pairs[i - _offset].gauge, _pair);
            pairs[i - _offset].staked_token0_fees = stakedToken0Fees;
            pairs[i - _offset].staked_token1_fees = stakedToken1Fees;  

            bribes = _getBribes(_pair);
            pairs[i - _offset].external_bribes = bribes[0];
            pairs[i - _offset].internal_bribes = bribes[1];  
        }

    }

    function getPair(address _pair, address _account) external view returns(pairInfo memory _pairInfo){
        pairInfo memory pairInformation =  _pairAddressToInfo(_pair, _account);
        uint claim0;
        uint claim1;
        uint stakedToken0Fees;     
        uint stakedToken1Fees; 

        (claim0, claim1) = getClaimable(_account, _pair);
        pairInformation.claimable0 = claim0;
        pairInformation.claimable1 = claim1;

        (stakedToken0Fees, stakedToken1Fees) = getClaimable(pairInformation.gauge, _pair);
        pairInformation.staked_token0_fees = stakedToken0Fees;
        pairInformation.staked_token1_fees = stakedToken1Fees;  

        Bribes[] memory bribes;
        bribes = _getBribes(_pair);
        pairInformation.external_bribes = bribes[0];
        pairInformation.internal_bribes = bribes[1];
        return pairInformation;
    }

    function _pairAddressToInfo(address _pair, address _account) internal view returns(pairInfo memory _pairInfo) {

        IPair ipair = IPair(_pair); 
        
        address token_0 = ipair.token0();
        address token_1 = ipair.token1();
        uint r0;
        uint r1;

        // checkout is v2 or v3? if v3 then load algebra pool 
        bool _type = IPairFactory(pairFactory).isPair(_pair);
        
        if(_type == false){
            // hypervisor totalAmounts = algebra.pool + gamma.unused
        } else {
            (r0,r1,) = ipair.getReserves();
        }

        IGaugeAPI _gauge = IGaugeAPI(gaugeManager.gauges(_pair));
        uint accountGaugeLPAmount = 0;
        uint earned = 0;
        uint gaugeTotalSupply = 0;
        uint emissions = 0;
        
        {
            if(address(_gauge) != address(0)){
                if(_account != address(0)){
                    accountGaugeLPAmount = _gauge.balanceOf(_account);
                    earned = _gauge.earned(_account);
                } else {
                    accountGaugeLPAmount = 0;
                    earned = 0;
                }
                gaugeTotalSupply = _gauge.totalSupply();
                emissions = _gauge.rewardRate();
                _pairInfo.total_emissions = _gauge.rewardForDuration();
            }
        }
        

        // Pair General Info
        _pairInfo.pair_address = _pair;
        _pairInfo.symbol = ipair.symbol();
        _pairInfo.name = ipair.name();
        _pairInfo.decimals = ipair.decimals();
        _pairInfo.stable = _type == false ? false : ipair.isStable();
        _pairInfo.total_supply = ipair.totalSupply();        
        
        // Token0 Info
        _pairInfo.token0 = token_0;
        _pairInfo.token0_decimals = IERC20(token_0).decimals();
        _pairInfo.token0_symbol = IERC20(token_0).symbol();
        _pairInfo.reserve0 = r0;
        _pairInfo.claimable0 = _type == false || _account == address(0) ? 0 : ipair.claimable0(_account);

        // Token1 Info
        _pairInfo.token1 = token_1;
        _pairInfo.token1_decimals = IERC20(token_1).decimals();
        _pairInfo.token1_symbol = IERC20(token_1).symbol();
        _pairInfo.reserve1 = r1;
        _pairInfo.claimable1 = _type == false || _account == address(0) ? 0 : ipair.claimable1(_account);

        
        // Pair's gauge Info
        _pairInfo.gauge = address(_gauge);
        _pairInfo.gauge_total_supply = gaugeTotalSupply;
        _pairInfo.emissions = emissions;
        _pairInfo.emissions_token = underlyingToken;
        _pairInfo.emissions_token_decimals = IERC20(underlyingToken).decimals();			    

        // Account Info
        _pairInfo.account_lp_balance = _account == address(0) ? 0 : IERC20(_pair).balanceOf(_account);
        _pairInfo.account_token0_balance = _account == address(0) ? 0 : IERC20(token_0).balanceOf(_account);
        _pairInfo.account_token1_balance = _account == address(0) ? 0 : IERC20(token_1).balanceOf(_account);
        _pairInfo.account_gauge_balance = accountGaugeLPAmount;
        _pairInfo.account_gauge_earned = earned;
        _pairInfo.account_staked_unlock = _account != address(0) && address(_gauge) != address(0) ? _gauge.maturityTime(_account) : 0;

        // votes
        _pairInfo.votes = voter.weights(_pair);   

    }

    // read all the bribe available for a pair
    function _getBribes(address pair) internal view returns(Bribes[] memory){

        address _gaugeAddress;
        address _bribeAddress;

        Bribes[] memory _tempReward = new Bribes[](2);

        // get external
        _gaugeAddress = gaugeManager.gauges(pair);

        {
            if(address(_gaugeAddress) != address(0)){
                
                _bribeAddress = gaugeManager.external_bribes(_gaugeAddress);
                _tempReward[0] = _getNextEpochRewards(_bribeAddress);
                
                // get internal
                _bribeAddress = gaugeManager.internal_bribes(_gaugeAddress);
                _tempReward[1] = _getNextEpochRewards(_bribeAddress);
            }
        }

        return _tempReward;
            
    }

    function _getNextEpochRewards(address _bribeAddress) internal view returns(Bribes memory _rewards){
        uint totTokens = IBribeAPI(_bribeAddress).rewardsListLength();
        uint[] memory _amounts = new uint[](totTokens);
        address[] memory _tokens = new address[](totTokens);
        string[] memory _symbol = new string[](totTokens);
        uint[] memory _decimals = new uint[](totTokens);
        uint ts = BlackTimeLibrary.epochStart(block.timestamp);
        uint i = 0;
        address _token;

        for(i; i < totTokens; i++){
            _token = IBribeAPI(_bribeAddress).bribeTokens(i);
            _tokens[i] = _token;
            _symbol[i] = IERC20(_token).symbol();
            _decimals[i] = IERC20(_token).decimals();
            _amounts[i] = IBribeAPI(_bribeAddress).tokenRewardsPerEpoch(_token, ts);
        }

        _rewards.bribeAddress = _bribeAddress;
        _rewards.tokens = _tokens;
        _rewards.amounts = _amounts;
        _rewards.symbols = _symbol;
        _rewards.decimals = _decimals;
    }

    function getCurrentFees(address _pair, address token_0, address token_1)  internal view returns(uint _tokenFees0, uint _tokenFees1, address _feesAddress) {
        Pair pair = Pair(_pair);  

        address feesAddress = pair.fees();
        uint tokenFees0 = IERC20(token_0).balanceOf(feesAddress);
        uint tokenFees1 = IERC20(token_1).balanceOf(feesAddress);

        return (tokenFees0, tokenFees1, feesAddress);
    }


    function setOwner(address _owner) external {
        require(msg.sender == owner);
        require(_owner != address(0));
        owner = _owner;
        emit Owner(msg.sender, _owner);
    }


    function setVoter(address _voter) external {
        require(msg.sender == owner);
        require(_voter != address(0));
        address _oldVoter = address(voter);
        voter = IVoter(_voter);
        
        // update variable depending on voter
        pairFactory = IPairFactory(voter.factories()[0]);
        underlyingToken = IVotingEscrow(voter._ve()).token();

        emit Voter(_oldVoter, _voter);
    }


    function setGaugeManager(address _gaugeManager) external {
        require(msg.sender == owner, 'no');
        require(_gaugeManager != address(0), 'zo');
        address _oldGaugeManager = address(gaugeManager);
        gaugeManager = IGaugeManager(_gaugeManager);
        emit GaugeManager(_oldGaugeManager, _gaugeManager);
    }

    function setAlgebraFactory(address _algebraFactory) external {
        require(msg.sender == owner);
        algebraFactory = IAlgebraCLFactory(_algebraFactory);
    }

    function setQuoterV2(address _quoterV2) external {
        require(msg.sender == owner);
        quoterV2 = IQuoterV2(_quoterV2);
    }

    function setAlgebraPoolAPI(address _algebraPoolAPIStorage) external {
        require(msg.sender == owner);
        algebraPoolAPIStorage = IAlgebraPoolAPIStorage(_algebraPoolAPIStorage);
    }

    function setPairFactory(address _pairFactory) external {
        require(msg.sender == owner);
        pairFactory = IPairFactory(_pairFactory);
    }

    /// @notice get next epoch (where bribes are saved)
    function getNextEpochStart() public view returns(uint256){
        return BlackTimeLibrary.epochNext(block.timestamp);
    }
}
