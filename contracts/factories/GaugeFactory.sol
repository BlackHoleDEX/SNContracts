// SPDX-License-Identifier: MIT OR GPL-3.0-or-later
pragma solidity 0.8.13;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import '../interfaces/IPermissionsRegistry.sol';
import '../interfaces/IGaugeFactory.sol';
import '../GaugeV2.sol';
import '../interfaces/IGauge.sol';

contract GaugeFactory is IGaugeFactory, OwnableUpgradeable {
    address public last_gauge;
    address public permissionsRegistry;

    address[] internal __gauges;
    address public gaugeManager;

    event SetRegistry(address indexed old, address indexed latest);
    event SetGaugeManager(address indexed old, address indexed latest);
    event GaugeCreated(address indexed gauge, address internal_bribe, address external_bribe, address indexed pool, bool indexed isPair);
    event SetDistribution(address indexed gauge, address indexed distro);
    event EmergencyActivated(address indexed gauge);
    event EmergencyDeactivated(address indexed gauge);

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(address _permissionRegistry) initializer  public {
        __Ownable_init();   //after deploy ownership to multisig
        permissionsRegistry = _permissionRegistry;
    }

    function setRegistry(address _registry) external onlyOwner {
        emit SetRegistry(permissionsRegistry, _registry);
        permissionsRegistry = _registry;
    }

    function gauges(uint256 i) external view returns(address) {
        return __gauges[i];
    }

    function length() external view returns(uint) {
        return __gauges.length;
    }

    function createGauge(address _rewardToken,address _ve,address _token,address _distribution, address _internal_bribe, address _external_bribe, bool _isPair) external onlyGaugeManager returns (address) {
        last_gauge = address(new GaugeV2(_rewardToken,_ve,_token,_distribution,_internal_bribe,_external_bribe,_isPair) );
        emit GaugeCreated(last_gauge, _internal_bribe, _external_bribe, _token, _isPair);
        __gauges.push(last_gauge);
        return last_gauge;
    }

    modifier onlyAllowed() {
        require(owner() == msg.sender || IPermissionsRegistry(permissionsRegistry).hasRole("GAUGE_ADMIN",msg.sender), 'GAUGE_ADMIN');
        _;
    }

    modifier EmergencyCouncil() {
        require( msg.sender == IPermissionsRegistry(permissionsRegistry).emergencyCouncil(), "NA");
        _;
    }

    function activateEmergencyMode( address[] memory _gauges) external EmergencyCouncil {
        uint i = 0;
        for ( i ; i < _gauges.length; i++){
            IGauge(_gauges[i]).activateEmergencyMode();
            emit EmergencyActivated(_gauges[i]);
        }
    }

    function stopEmergencyMode( address[] memory _gauges) external EmergencyCouncil {
        uint i = 0;
        for ( i ; i < _gauges.length; i++){
            IGauge(_gauges[i]).stopEmergencyMode();
            emit EmergencyDeactivated(_gauges[i]);
        }
    }

    function setDistribution(address[] memory _gauges,  address distro) external onlyAllowed {
        uint i = 0;
        for ( i ; i < _gauges.length; i++){
            IGauge(_gauges[i]).setDistribution(distro);
            emit SetDistribution(_gauges[i], distro);
        }
    }

    modifier onlyGaugeManager() {
        require(msg.sender == gaugeManager, "N_G_M");
        _;
    }

    function setGaugeManager(address _gaugeManager) external onlyAllowed {
        require(_gaugeManager != address(0), "ZA");
        emit SetGaugeManager(gaugeManager, _gaugeManager);
        gaugeManager = _gaugeManager;
    }
}
