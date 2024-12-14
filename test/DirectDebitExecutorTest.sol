// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { Test } from "forge-std/Test.sol";
import { RhinestoneModuleKit, ModuleKitHelpers, AccountInstance } from "modulekit/ModuleKit.sol";
import { MODULE_TYPE_EXECUTOR } from "modulekit/accounts/common/interfaces/IERC7579Module.sol";
// import { ExecutionLib } from "modulekit/accounts/erc7579/lib/ExecutionLib.sol";
import { DirectDebitExecutor, DirectDebit } from "src/DirectDebitExecutor.sol";
import { MockERC20 } from "src/MockERC20.sol";

contract DirectDebitExecutorTest is RhinestoneModuleKit, Test {
    using ModuleKitHelpers for *;

    // account and modules
    AccountInstance internal instance;
    DirectDebitExecutor internal executor;

    MockERC20 erc20Token;

    address target;
    address badTarget;
    uint128 value;

    function setUp() public {
        init();

        target = makeAddr("target");
        badTarget = makeAddr("badTarget");
        value = 1 ether;

        erc20Token = new MockERC20("TestToken", "TEST");

        // Set the block timestamp to 200 days in the future because starting at 0 will cause
        // problems with DirectDebitError.NotDue
        vm.warp(200 days);

        // Create the executor
        executor = new DirectDebitExecutor();
        vm.label(address(executor), "DirectDebitExecutor");

        // Create the account and install the executor
        instance = makeAccountInstance("ExecutorInstance");
        vm.deal(address(instance.account), 10 ether);
        instance.installModule({
            moduleTypeId: MODULE_TYPE_EXECUTOR,
            module: address(executor),
            data: ""
        });

        erc20Token.mint(address(instance.account), value);
    }

    function testERC20DirectDebit() public {
        // create a direct debit
        DirectDebit memory debit = DirectDebit(
            address(erc20Token), 0, uint48(block.timestamp + 10 days), target, 1 days, value
        );
        instance.exec({
            target: address(executor),
            value: 0,
            callData: abi.encodeWithSelector(DirectDebitExecutor.createDirectDebit.selector, debit)
        });

        // check if the direct debit is valid
        assertEq(executor.canExecute(address(instance.account), 0, value), true);

        // check if the direct debit is not valid
        assertEq(executor.canExecute(address(instance.account), 0, value * 2), false);

        vm.prank(target);
        executor.execute(address(instance.account), 0, value);

        // check if the balance of the target has increased
        assertEq(erc20Token.balanceOf(target), value);

        // check if the last payment timestamp is set correctly
        assertEq(executor.lastPayment(address(instance.account), 0), block.timestamp);

        // wait for the interval to pass
        skip(debit.interval + 1);
        assertLt(
            executor.lastPayment(address(instance.account), 0) + debit.interval, block.timestamp
        );
        vm.prank(target);
        vm.expectRevert(DirectDebitExecutor.DirectDebitNotEnoughFunds.selector);
        executor.execute(address(instance.account), 0, value);

        erc20Token.mint(address(instance.account), value);
        vm.prank(target);
        executor.execute(address(instance.account), 0, value);

        // check if the balance of the target has increased
        assertEq(erc20Token.balanceOf(target), value * 2);
    }

    function testEtherDirectDebit() public {
        // Create a target address and send some ether to it

        // Get the current balance of the target
        uint256 prevBalance = target.balance;

        // Encode the execution data sent to the account
        DirectDebit memory debit = DirectDebit(
            address(0), // token
            0, // first payment
            uint48(block.timestamp + 10 days), // expires at
            target, // receiver
            1 days, // interval
            value // max amount
        );

        instance.exec({
            target: address(executor),
            value: 0,
            callData: abi.encodeWithSelector(DirectDebitExecutor.createDirectDebit.selector, debit)
        });

        // First payment should be made immediately
        assertEq(executor.canExecute(address(instance.account), 0, value), true);

        //can't execute if not the receiver
        vm.prank(badTarget);
        vm.expectRevert(DirectDebitExecutor.DirectDebitNotReceiver.selector);
        executor.execute(address(instance.account), 0, value);

        //can't execute if the max amount is exceeded
        vm.prank(target);
        vm.expectRevert(DirectDebitExecutor.DirectDebitExceeded.selector);
        executor.execute(address(instance.account), 0, value * 2);

        // can execute
        vm.prank(target);
        executor.execute(address(instance.account), 0, value);

        // Check if the balance of the target has increased
        assertEq(target.balance, prevBalance + value);

        assertEq(executor.currentPeriod(address(instance.account), 0), block.timestamp);

        uint256 currentPeriod = executor.currentPeriod(address(instance.account), 0);
        vm.prank(target);
        vm.expectRevert(DirectDebitExecutor.DirectDebitNotDue.selector);
        executor.execute(address(instance.account), 0, value);

        // Check if the last payment timestamp is set correctly
        assertEq(executor.lastPayment(address(instance.account), 0), block.timestamp);

        // Wait for the interval to pass
        skip(debit.interval + 1);
        assertEq(
            executor.currentPeriod(address(instance.account), 0), currentPeriod + debit.interval
        );
        assertLt(
            executor.lastPayment(address(instance.account), 0) + debit.interval, block.timestamp
        );
        vm.prank(target);
        executor.execute(address(instance.account), 0, value);

        // Check if the balance of the target has increased
        assertEq(target.balance, prevBalance + value * 2);
    }

    function testMissingDirectDebit() public {
        // Encode the execution data sent to the account
        DirectDebit memory debit = DirectDebit(
            address(0), // token
            0, // first payment
            uint48(block.timestamp + 10 days), // expires at
            target, // receiver
            1 days, // interval
            value // max amount
        );

        // start the direct debit in the middle of the interval
        skip(debit.interval / 2);

        instance.exec({
            target: address(executor),
            value: 0,
            callData: abi.encodeWithSelector(DirectDebitExecutor.createDirectDebit.selector, debit)
        });

        skip(debit.interval + 1);

        vm.prank(target);
        executor.execute(address(instance.account), 0, value);

        //make sure we can't execute the direct debit again
        vm.prank(target);
        vm.expectRevert(DirectDebitExecutor.DirectDebitNotDue.selector);
        executor.execute(address(instance.account), 0, value);
    }
}
