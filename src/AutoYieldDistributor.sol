// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { ERC7579ExecutorBase } from "modulekit/Modules.sol";
import {
    IERC7579Account,
    Execution
} from "modulekit/accounts/common/interfaces/IERC7579Account.sol";
import { ModeLib } from "modulekit/accounts/common/lib/ModeLib.sol";
import { ERC20Integration } from "modulekit/integrations/ERC20.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { ExecutionLib } from
    "modulekit/accounts/erc7579/lib/ExecutionLib.sol";
import { IERC4626 } from "modulekit/integrations/ERC4626.sol";

enum APRCalculationMethod {
    AVERAGE,
    TOTAL
}

struct Config {
    address[] approvedVaults;
    uint256 minImprovement; // Minimum APR improvement required (in basis points)
    uint256 snapshotsRequired;
    uint256 maxTimeBetweenSnapshots;
    uint256 maxInvestment;
    APRCalculationMethod aprCalculationMethod;
}

struct Snapshot {
    uint256 pricePerShare;
    uint256 timestamp;
}

contract AutoYieldDistributor is ERC7579ExecutorBase {
    /*//////////////////////////////////////////////////////////////////////////
                            LOGS & ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    event VaultRegistered(address indexed asset, address indexed vault);
    event FundsMoved(address indexed fromVault, address indexed toVault, uint256 amount);
    event SnapshotTaken(address indexed vault, uint256 pricePerShare, uint256 timestamp);
    error InvalidVault(address vault);
    error InsufficientImprovement();
    error NoSnapshots();
    error SnapshotTooSoon(address vault);
    error NotInstalled();
    error InvalidSmartWallet();
    error SnapshotsStale(address vault);
    error InvalidInvestmentChange();
    error InsufficientBalance(address vault);
    error MaxInvestmentReached(address vault);
    error InvalidSnapshotsRequired();
    error InvalidMinImprovement();
    error InvalidMaxTimeBetweenSnapshots();
    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANTS & STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    mapping(address asset => address vault) public vaultsByAsset;
    mapping(address vault => bool enabled) public vaultEnabled;
    mapping(address vault => Snapshot[] snapshots) public snapshots;

    mapping(address smartWallet => mapping(address asset => Config config)) public configs;

    mapping(address vault => address asset) public assetByVault;
    mapping(address smartWallet => bool enabled) public smartWalletInstalled;

    /*//////////////////////////////////////////////////////////////////////////
                                     CONFIG
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Initialize the module with the given data
     *
     * @param data The data to initialize the module with
     */
    function onInstall(bytes calldata data) external override {
        if(!IERC7579Account(msg.sender).supportsModule(TYPE_EXECUTOR)) revert InvalidSmartWallet();
        smartWalletInstalled[msg.sender] = true;
    }

    function configure(address asset, Config calldata config) external {

        if(!smartWalletInstalled[msg.sender]) revert NotInstalled();
        if(config.snapshotsRequired < 2) revert InvalidSnapshotsRequired();
        if(config.minImprovement == 0) revert InvalidMinImprovement();
        if(config.maxTimeBetweenSnapshots <= 6 hours) revert InvalidMaxTimeBetweenSnapshots();
        configs[msg.sender][asset] = config;

        // Check that all vaults are for the correct asset
        for (uint256 i = 0; i < config.approvedVaults.length; i++) {
            address vault = config.approvedVaults[i];

            if (IERC4626(vault).asset() != asset) {
                revert InvalidVault(vault);
            }

            //register vault if not already registered
            if(!vaultEnabled[vault]) {
                vaultEnabled[vault] = true;
                assetByVault[vault] = asset;
                emit VaultRegistered(asset, vault);
            }
        }
        snapshotVaults(config.approvedVaults);
    }

    /**
     * De-initialize the module with the given data
     *
     * @param data The data to de-initialize the module with
     */
    function onUninstall(bytes calldata data) external override {
        smartWalletInstalled[msg.sender] = false;
    }

    /**
     * Check if the module is initialized
     * @param smartAccount The smart account to check
     *
     * @return true if the module is initialized, false otherwise
     */
    function isInitialized(address smartAccount) external view returns (bool) {
       if(!smartWalletInstalled[smartAccount]) return false;
       return true;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     MODULE LOGIC
    //////////////////////////////////////////////////////////////////////////*/

    function snapshotVaults(address[] calldata vaults) public {
        for (uint256 i = 0; i < vaults.length; i++) {
            address vault = vaults[i];
            //vault must be registered to be snapshotted
            if (!vaultEnabled[vault]) continue;

            // Check if enough time has passed since last snapshot (6 hours = 21600 seconds)
            if (snapshots[vault].length > 0) {
                Snapshot storage lastSnapshot = snapshots[vault][snapshots[vault].length - 1];
                if (block.timestamp - lastSnapshot.timestamp < 6 hours) {
                    revert SnapshotTooSoon(vault);
                }
            }

            uint256 assets = IERC4626(vault).convertToAssets(1e4);
            snapshots[vault].push(Snapshot({ pricePerShare: assets, timestamp: block.timestamp }));

            emit SnapshotTaken(vault, assets, block.timestamp);
        }
    }

    function calculateVaultAPR(address vault, uint256 numberOfSnapshots, uint256 maxTimeBetweenSnapshots, APRCalculationMethod aprCalculationMethod) internal view returns (uint256) {
        Snapshot[] storage vaultSnapshots = snapshots[vault];
        if (vaultSnapshots.length < numberOfSnapshots) revert NoSnapshots();

        uint256 totalAPR = 0;

        for(uint256 i = 1; i < numberOfSnapshots; i++) {
            
            uint256 timeElapsed = vaultSnapshots[vaultSnapshots.length  - i].timestamp 
                - vaultSnapshots[vaultSnapshots.length - 1-i].timestamp;

            if(timeElapsed > maxTimeBetweenSnapshots) revert SnapshotsStale(vault);

            uint256 oldPrice = vaultSnapshots[vaultSnapshots.length - 1-i].pricePerShare;
            uint256 newPrice = vaultSnapshots[vaultSnapshots.length -i].pricePerShare;

            if(aprCalculationMethod == APRCalculationMethod.AVERAGE) {
                totalAPR += calculateAPR(oldPrice, newPrice, timeElapsed);
            } 
        }

        if(aprCalculationMethod == APRCalculationMethod.TOTAL) {
            return calculateAPR(vaultSnapshots[vaultSnapshots.length -numberOfSnapshots].pricePerShare, vaultSnapshots[vaultSnapshots.length - 1].pricePerShare, vaultSnapshots[vaultSnapshots.length - 1].timestamp - vaultSnapshots[vaultSnapshots.length -numberOfSnapshots].timestamp);
        }
            
        return totalAPR / numberOfSnapshots;
    }

    function validateInvestmentChange(
        address smartWallet,
        address fromVault,
        address toVault
    )
        public
        view
        returns (bool valid)
    {
        address asset = assetByVault[fromVault];
        if (!vaultEnabled[fromVault] || !vaultEnabled[toVault]) revert InvalidVault(fromVault);
        if (asset != assetByVault[toVault]) revert InvalidVault(toVault);  //todo fix error message

        Config storage config = configs[smartWallet][asset];

        uint256 fromAPR = calculateVaultAPR(fromVault, config.snapshotsRequired, config.maxTimeBetweenSnapshots, config.aprCalculationMethod);
        uint256 toAPR = calculateVaultAPR(toVault, config.snapshotsRequired, config.maxTimeBetweenSnapshots, config.aprCalculationMethod);

        // Check if improvement exceeds minimum threshold
        uint256 improvement = toAPR > fromAPR ? toAPR - fromAPR : 0;

        if (improvement < configs[smartWallet][assetByVault[fromVault]].minImprovement) revert InsufficientImprovement();

        return true;
    }

    /// @notice Calculates the annualized APR based on two price points
    /// @param oldPrice The price per share from previous snapshot
    /// @param newPrice The price per share from current snapshot
    /// @param timeElapsed Time between snapshots in seconds
    /// @return apr The annualized APR in basis points (1% = 100)
    function calculateAPR(
        uint256 oldPrice,
        uint256 newPrice,
        uint256 timeElapsed
    )
        internal
        pure
        returns (uint256 apr)
    {
        if (oldPrice == 0 || timeElapsed == 0) return 0;

        // Calculate period return
        uint256 periodReturn = ((newPrice - oldPrice) * 10_000) / oldPrice;

        // Annualize the return
        // Formula: (1 + r)^(365*24*3600/timeElapsed) - 1
        // For small returns, we can approximate this as: r * (365*24*3600/timeElapsed)
        uint256 periodsPerYear = 31_536_000 / timeElapsed; // 31536000 = seconds in a year

        return periodReturn * periodsPerYear;
    }



    function execute(
        address smartWallet,
        address fromVault,
        address toVault,
        uint256 amount
    )
        external
    {
        if (!validateInvestmentChange(smartWallet, fromVault, toVault)) revert InvalidInvestmentChange();

        //now check the balances make sense
        uint256 fromVaultBalance = IERC4626(fromVault).convertToAssets(IERC4626(fromVault).balanceOf(smartWallet));

        if(fromVaultBalance < amount) revert InsufficientBalance(fromVault);

        uint256 toVaultBalance = IERC4626(toVault).convertToAssets(IERC4626(toVault).balanceOf(smartWallet));

        if(toVaultBalance + amount > configs[smartWallet][assetByVault[fromVault]].maxInvestment) revert MaxInvestmentReached(toVault);

        // Withdraw from source vault
        bytes memory withdrawData = abi.encodeWithSelector(
            IERC4626.withdraw.selector, amount, address(smartWallet), address(smartWallet)
        );

        //approve the asset for the destination vault
        bytes memory approveData = abi.encodeWithSelector(
            IERC20.approve.selector, toVault, amount
        );

        // Deposit to destination vault
        bytes memory depositData =
            abi.encodeWithSelector(IERC4626.deposit.selector, amount, address(smartWallet));

        Execution[] memory executions = new Execution[](3);
        executions[0] = Execution(fromVault, 0, withdrawData);
        executions[1] = Execution(toVault, 0, approveData);
        executions[2] = Execution(toVault, 0, depositData);

        IERC7579Account(smartWallet).executeFromExecutor(
            ModeLib.encodeSimpleBatch(), ExecutionLib.encodeBatch(executions)
        );

        emit FundsMoved(fromVault, toVault, amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     METADATA
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the name of the module
     * @return string The module name
     */
    function name() external pure returns (string memory) {
        return "AutoYieldDistributor";
    }

    /**
     * @notice Returns the version of the module
     * @return string The module version
     */
    function version() external pure returns (string memory) {
        return "0.0.1";
    }

    /**
     * @notice Checks if the module supports a specific type
     * @param typeID The type identifier to check
     * @return bool Whether the module supports the type
     */
    function isModuleType(uint256 typeID) external pure override returns (bool) {
        return typeID == TYPE_EXECUTOR;
    }
}
