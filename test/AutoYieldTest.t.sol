// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { RhinestoneModuleKit, ModuleKitHelpers, AccountInstance } from "modulekit/ModuleKit.sol";
import { MODULE_TYPE_EXECUTOR } from "modulekit/accounts/common/interfaces/IERC7579Module.sol";
// import { ExecutionLib } from "modulekit/accounts/erc7579/lib/ExecutionLib.sol";
import { AutoYieldDistributor, Config, APRCalculationMethod } from "src/AutoYieldDistributor.sol";
import { MockERC20 } from "src/MockERC20.sol";
import { MockERC4626 } from "src/MockERC4626.sol";

contract AutoYieldDistributorTest is RhinestoneModuleKit, Test {
    using ModuleKitHelpers for *;

    // account and modules
    AccountInstance internal instance;
    AutoYieldDistributor internal executor;

    MockERC20 erc20Token;

    address vaultuser;
    MockERC4626 erc4626Vault;
    MockERC4626 erc4626Vault2;

    function setUp() public {
        init();

        vaultuser = makeAddr("vaultuser");

        erc20Token = new MockERC20("TestToken1", "TEST");
        erc4626Vault = new MockERC4626(erc20Token, "TESTVAULT", "TESTVAULT");
        erc4626Vault2 = new MockERC4626(erc20Token, "TESTVAULT2", "TESTVAULT2");

        erc20Token.mint(vaultuser, 20e18);

        vm.startPrank(vaultuser);
        erc20Token.approve(address(erc4626Vault), 10e18);
        erc4626Vault.mint(10e18, vaultuser);
        erc20Token.approve(address(erc4626Vault2), 10e18);
        erc4626Vault2.mint(10e18, vaultuser);
        vm.stopPrank();


        // Create the executor
        executor = new AutoYieldDistributor();
        vm.label(address(executor), "AutoYieldDistributor");

        // Create the account and install the executor
        instance = makeAccountInstance("ExecutorInstance");

        erc20Token.mint(instance.account, 10e18);
        vm.startPrank(instance.account);
        erc20Token.approve(address(erc4626Vault), 10e18);
        erc4626Vault.mint(10e18, instance.account);
        vm.stopPrank();

        instance.installModule({
            moduleTypeId: MODULE_TYPE_EXECUTOR,
            module: address(executor),
            data: ""
        });

    }

    function testAutoYieldDistributor() public {

        //user starts with a bunch of vault 1 but none of vault 2
        vm.startPrank(instance.account);
        address[] memory approvedVaults = new address[](2);
        approvedVaults[0] = address(erc4626Vault);
        approvedVaults[1] = address(erc4626Vault2);
        Config memory config = Config({
            approvedVaults: approvedVaults,
            minImprovement: 1,
            snapshotsRequired: 2,
            maxTimeBetweenSnapshots: 2 days,
            maxInvestment: 1e18,
            aprCalculationMethod: APRCalculationMethod.AVERAGE
        });

        executor.configure(address(erc20Token), config);

        // fast forward 6 hours and 1 second, push vault and snapshot
        vm.warp(block.timestamp + 6 hours + 1 seconds);
        erc20Token.mint(address(erc4626Vault2), 1e18);

        executor.snapshotVaults(approvedVaults);

        assertEq(executor.validateInvestmentChange(instance.account, address(erc4626Vault), address(erc4626Vault2)), true);

        executor.execute(instance.account, address(erc4626Vault), address(erc4626Vault2), 1e18);
    }

}
