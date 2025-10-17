// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity ^0.8.11;

import "../Bribes.sol";

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import '../interfaces/IPermissionsRegistry.sol';

interface IBribe {
    function setVoter(address _Voter) external;
    function setMinter(address _Voter) external;
    function setOwner(address _Voter) external;
    function emergencyRecoverERC20(address tokenAddress, uint256 tokenAmount) external;
    function recoverERC20AndUpdateData(address tokenAddress, uint256 tokenAmount) external;
    function setAVM(address _avm) external;
}

contract BribeFactoryV3 is OwnableUpgradeable {
    address public last_bribe;
    address[] internal _bribes;
    address public voter;
    address public gaugeManager;

    IPermissionsRegistry public permissionsRegistry;
    address public tokenHandler;

    modifier onlyAllowed() {
        require(owner() == msg.sender || permissionsRegistry.hasRole("BRIBE_ADMIN",msg.sender), 'BRIBE_ADMIN');
        _;
    }

    constructor() {}

    function initialize(address _voter, address _gaugeManager, address _permissionsRegistry, address _tokenHandler) initializer  public {
        __Ownable_init();   //after deploy ownership to multisig
        voter = _voter;
        gaugeManager = _gaugeManager;
        // registry to check accesses
        permissionsRegistry = IPermissionsRegistry(_permissionsRegistry);
        tokenHandler = _tokenHandler;

    }


    /// @notice create a bribe contract
    /// @dev    _owner must be blackTeamMultisig
    function createBribe(address _owner,address _token0,address _token1, string memory _type) external returns (address) {
        require(msg.sender == gaugeManager || msg.sender == owner(), 'NA');

        Bribe lastBribe = new Bribe(_owner,voter, gaugeManager,address(this), tokenHandler, _token0, _token1, _type);

        last_bribe = address(lastBribe);
        _bribes.push(last_bribe);
        return last_bribe;
    }


    /* -----------------------------------------------------------------------------
    --------------------------------------------------------------------------------
    --------------------------------------------------------------------------------
                                    ONLY OWNER
    --------------------------------------------------------------------------------
    --------------------------------------------------------------------------------
    ----------------------------------------------------------------------------- */


    /// @notice set the bribe factory voter
    function setVoter(address _Voter) external {
        require(owner() == msg.sender, 'NA');
        require(_Voter != address(0), 'ZA');
        voter = _Voter;
    }


    /// @notice set the bribe factory permission registry
    function setPermissionsRegistry(address _permReg) external {
        require(owner() == msg.sender, 'NA');
        require(_permReg != address(0), 'ZA');
        permissionsRegistry = IPermissionsRegistry(_permReg);
    }

    function setTokenHandler(address _tokenHandler) external {
        require(owner() == msg.sender, 'NA');
        require(_tokenHandler != address(0), 'ZA');
        tokenHandler = _tokenHandler;
    }

    /* -----------------------------------------------------------------------------
    --------------------------------------------------------------------------------
    --------------------------------------------------------------------------------
                                    ONLY OWNER or BRIBE ADMIN
    --------------------------------------------------------------------------------
    --------------------------------------------------------------------------------
    ----------------------------------------------------------------------------- */

    /// @notice set a new voter in given bribes
    function setBribeVoter(address[] memory _bribe, address _voter) external onlyOwner {
        uint i = 0;
        for(i; i< _bribe.length; i++){
            IBribe(_bribe[i]).setVoter(_voter);
        }
    }

    /// @notice set a new avm in given bribes
    function setBribeAVM(address[] memory _bribe, address _avm) external onlyOwner {
        uint i=0;
        for(i; i<_bribe.length; i++){
            IBribe(_bribe[i]).setAVM(_avm);
        }
    }

    /// @notice set a new minter in given bribes
    function setBribeMinter(address[] memory _bribe, address _minter) external onlyOwner {
        uint i = 0;
        for(i; i< _bribe.length; i++){
            IBribe(_bribe[i]).setMinter(_minter);
        }
    }

    /// @notice set a new owner in given bribes
    function setBribeOwner(address[] memory _bribe, address _owner) external onlyOwner {
        uint i = 0;
        for(i; i< _bribe.length; i++){
            IBribe(_bribe[i]).setOwner(_owner);
        }
    }

    /// @notice recover an ERC20 from bribe contracts.
    function recoverERC20From(address[] memory _bribe, address[] memory _tokens, uint[] memory _amounts) external onlyOwner {
        uint i = 0;
        require(_bribe.length == _tokens.length, 'MISMATCH_LEN');
        require(_tokens.length == _amounts.length, 'MISMATCH_LEN');

        for(i; i< _bribe.length; i++){
            if(_amounts[i] > 0) IBribe(_bribe[i]).emergencyRecoverERC20(_tokens[i], _amounts[i]);
        }
    }

    /// @notice recover an ERC20 from bribe contracts and update.
    function recoverERC20AndUpdateData(address[] memory _bribe, address[] memory _tokens, uint[] memory _amounts) external onlyOwner {
        uint i = 0;
        require(_bribe.length == _tokens.length, 'MISMATCH_LEN');
        require(_tokens.length == _amounts.length, 'MISMATCH_LEN');

        for(i; i< _bribe.length; i++){
            if(_amounts[i] > 0) IBribe(_bribe[i]).recoverERC20AndUpdateData(_tokens[i], _amounts[i]);
        }
    }

    function version() external pure returns (string memory) {
        return "BribeFactoryV3 v1.1.4";
    }

}