// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { ERC7579ExecutorBase } from "node_modules/@rhinestone/modulekit/src/Modules.sol";
import {
    IERC7579Account,
    Execution
} from "node_modules/@rhinestone/modulekit/src/accounts/common/interfaces/IERC7579Account.sol";
import { ModeLib } from "node_modules/@rhinestone/modulekit/src/accounts/common/lib/ModeLib.sol";
import { ERC20Integration } from "node_modules/@rhinestone/modulekit/src/integrations/ERC20.sol";
import { IERC20 } from "node_modules/forge-std/src/interfaces/IERC20.sol";
import { ExecutionLib } from
    "node_modules/@rhinestone/modulekit/src/accounts/erc7579/lib/ExecutionLib.sol";
import { IERC4626 } from "./interfaces/IERC4626.sol";

struct Config {
    uint256 vaults;
    uint256 minImprovement; // Minimum APR improvement required (in basis points)
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

    error InvalidVault();
    error InsufficientImprovement();
    error NoSnapshots();
    error SnapshotTooSoon(address vault);

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANTS & STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    mapping(address asset => address vault) public vaultsByAsset;
    mapping(address vault => uint256 id) public vaultIds;
    mapping(address vault => Snapshot[] snapshots) public snapshots;

    mapping(address smartWallet => Config config) public configs;

    mapping(address vault => address asset) public assetByVault;

    /*//////////////////////////////////////////////////////////////////////////
                                     CONFIG
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * Initialize the module with the given data
     *
     * @param data The data to initialize the module with
     */
    function onInstall(bytes calldata data) external override {
        isInstalled[msg.sender] = true;
    }

    /**
     * De-initialize the module with the given data
     *
     * @param data The data to de-initialize the module with
     */
    function onUninstall(bytes calldata data) external override {
        isInstalled[msg.sender] = false;
    }

    /**
     * Check if the module is initialized
     * @param smartAccount The smart account to check
     *
     * @return true if the module is initialized, false otherwise
     */
    function isInitialized(address smartAccount) external view returns (bool) {
        //todo
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     MODULE LOGIC
    //////////////////////////////////////////////////////////////////////////*/

    function snapshotVaults(address[] calldata vaults) external {
        for (uint256 i = 0; i < vaults.length; i++) {
            address vault = vaults[i];
            //vault must be registered to be snapshotted
            if (vaultIds[vault] == 0) continue;

            // Check if enough time has passed since last snapshot (6 hours = 21600 seconds)
            if (snapshots[vault].length > 0) {
                Snapshot storage lastSnapshot = snapshots[vault][snapshots[vault].length - 1];
                if (block.timestamp - lastSnapshot.timestamp < 6 hours) {
                    revert SnapshotTooSoon(vault);
                }
            }

            uint256 assets = IERC4626(vault).convertToAssets(1e4);
            snapshots[vault].push(Snapshot({ pricePerShare: assets, timestamp: block.timestamp }));
        }
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
        if (vaultIds[fromVault] == 0 || vaultIds[toVault] == 0) revert InvalidVault();
        if (assetByVault[fromVault] != assetByVault[toVault]) revert InvalidVault();

        Snapshot[] storage fromSnapshots = snapshots[fromVault];
        Snapshot[] storage toSnapshots = snapshots[toVault];

        if (fromSnapshots.length < 2 || toSnapshots.length < 2) revert NoSnapshots();

        // Calculate APR for fromVault
        uint256 fromOldPrice = fromSnapshots[fromSnapshots.length - 2].pricePerShare;
        uint256 fromNewPrice = fromSnapshots[fromSnapshots.length - 1].pricePerShare;
        uint256 fromAPR = calculateAPR(
            fromOldPrice,
            fromNewPrice,
            fromSnapshots[fromSnapshots.length - 2].timestamp
                - fromSnapshots[fromSnapshots.length - 1].timestamp
        );

        // Calculate APR for toVault
        uint256 toOldPrice = toSnapshots[toSnapshots.length - 2].pricePerShare;
        uint256 toNewPrice = toSnapshots[toSnapshots.length - 1].pricePerShare;
        uint256 toAPR = calculateAPR(
            toOldPrice,
            toNewPrice,
            toSnapshots[toSnapshots.length - 2].timestamp
                - toSnapshots[toSnapshots.length - 1].timestamp
        );

        // Check if improvement exceeds minimum threshold
        uint256 improvement = toAPR > fromAPR ? ((toAPR - fromAPR) * 10_000) / fromAPR : 0;

        if (improvement < configs[smartWallet].minImprovement) revert InsufficientImprovement();

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

    function registerVault(address asset, address vault) external {
        if (vaultsByAsset[asset] != address(0)) revert("Asset already has vault");

        vaultsByAsset[asset] = vault;
        assetByVault[vault] = asset;
        vaultIds[vault] = block.timestamp;

        emit VaultRegistered(asset, vault);
    }

    function execute(
        address smartWallet,
        address fromVault,
        address toVault,
        uint256 amount
    )
        external
    {
        require(
            validateInvestmentChange(smartWallet, fromVault, toVault), "Invalid investment change"
        );

        // Withdraw from source vault
        bytes memory withdrawData = abi.encodeWithSelector(
            IERC4626.withdraw.selector, amount, address(smartWallet), address(smartWallet)
        );

        // Deposit to destination vault
        bytes memory depositData =
            abi.encodeWithSelector(IERC4626.deposit.selector, amount, address(smartWallet));

        Execution[] memory executions = new Execution[](2);
        executions[0] = Execution(fromVault, 0, withdrawData);
        executions[1] = Execution(toVault, 0, depositData);

        IERC7579Account(smartWallet).executeFromExecutor(
            ModeLib.encodeSimpleMulti(), ExecutionLib.encodeMulti(executions)
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
