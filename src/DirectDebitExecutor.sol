// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import { ERC7579ExecutorBase } from "modulekit/Modules.sol";
import {
    IERC7579Account, Execution
} from "modulekit/accounts/common/interfaces/IERC7579Account.sol";
import { ModeLib } from "modulekit/accounts/common/lib/ModeLib.sol";
import { ERC20Integration } from "modulekit/integrations/ERC20.sol";
import { IERC20 } from "forge-std/interfaces/IERC20.sol";
import { ExecutionLib } from "modulekit/accounts/erc7579/lib/ExecutionLib.sol";

/// @title DirectDebitExecutor
/// @notice A module that enables automated recurring payments (direct debits) from
/// ERC7579-compatible smart accounts
/// @dev Implements ERC7579ExecutorBase for smart account integration

/// @notice Represents a recurring payment configuration
/// @dev Packed into three storage slots for gas optimization
/// @param token The token address (0x0 for native token)
/// @param firstPayment Timestamp when the first payment can be executed
/// @param expiresAt Timestamp when the direct debit becomes invalid
/// @param receiver Address that will receive the payments
/// @param interval Time period between allowed payments (in seconds)
/// @param maxAmount Maximum amount that can be debited per interval
struct DirectDebit {
    address token;
    uint48 firstPayment;
    uint48 expiresAt;
    address receiver;
    uint96 interval;
    uint256 maxAmount;
}

contract DirectDebitExecutor is ERC7579ExecutorBase {
    /*//////////////////////////////////////////////////////////////////////////
                            LOGS & ERRORS
    //////////////////////////////////////////////////////////////////////////*/

    enum DirectDebitError {
        None,
        NotActive,
        NotDue,
        Exceeded,
        NotEnoughFunds
    }

    error DirectDebitNotActive();
    error DirectDebitNotDue();
    error DirectDebitExceeded();
    error DirectDebitNotEnoughFunds();
    error DirectDebitNotReceiver();

    event DirectDebitCreated(
        address indexed smartWallet,
        uint256 indexed id,
        address indexed receiver,
        address token,
        uint256 maxAmount,
        uint256 interval,
        uint256 firstPayment,
        uint256 expiresAt
    );
    event DirectDebitExecuted(
        address indexed smartWallet,
        uint256 indexed id,
        address indexed receiver,
        address token,
        uint256 amount
    );
    event DirectDebitAmended(
        address indexed smartWallet,
        uint256 indexed id,
        address indexed receiver,
        address token,
        uint256 maxAmount,
        uint256 interval,
        uint256 firstPayment,
        uint256 expiresAt
    );

    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANTS & STORAGE
    //////////////////////////////////////////////////////////////////////////*/

    mapping(address smartWallet => mapping(uint256 id => DirectDebit directDebit)) public
        directDebits;
    mapping(address smartWallet => mapping(uint256 id => uint256 lastPayment)) public lastPayment;
    mapping(address smartWallet => uint256 currentId) public currentIds;
    mapping(address smartWallet => bool isInstalled) public isInstalled;

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
        delete currentIds[msg.sender];
        isInstalled[msg.sender] = false;
    }

    /**
     * Check if the module is initialized
     * @param smartAccount The smart account to check
     *
     * @return true if the module is initialized, false otherwise
     */
    function isInitialized(address smartAccount) external view returns (bool) {
        return isInstalled[smartAccount];
    }

    /**
     * @notice Creates a new direct debit configuration
     * @param directDebit The direct debit configuration to create
     */
    function createDirectDebit(DirectDebit memory directDebit) external {
        directDebits[msg.sender][currentIds[msg.sender]] = directDebit;
        currentIds[msg.sender]++;
        emit DirectDebitCreated(
            msg.sender,
            currentIds[msg.sender] - 1,
            directDebit.receiver,
            directDebit.token,
            directDebit.maxAmount,
            directDebit.interval,
            directDebit.firstPayment,
            directDebit.expiresAt
        );
    }

    /**
     * @notice Cancels an existing direct debit by setting its expiration to current timestamp
     * @param id The identifier of the direct debit to cancel
     */
    function cancelDirectDebit(uint128 id) external {
        directDebits[msg.sender][id].expiresAt = uint48(block.timestamp);
        emit DirectDebitAmended(
            msg.sender,
            id,
            directDebits[msg.sender][id].receiver,
            directDebits[msg.sender][id].token,
            directDebits[msg.sender][id].maxAmount,
            directDebits[msg.sender][id].interval,
            directDebits[msg.sender][id].firstPayment,
            directDebits[msg.sender][id].expiresAt
        );
    }

    /**
     * @notice Modifies an existing direct debit configuration
     * @param id The identifier of the direct debit to modify
     * @param directDebit The new direct debit configuration
     */
    function amendDirectDebit(uint128 id, DirectDebit memory directDebit) external {
        directDebits[msg.sender][id] = directDebit;
        emit DirectDebitAmended(
            msg.sender,
            id,
            directDebit.receiver,
            directDebit.token,
            directDebit.maxAmount,
            directDebit.interval,
            directDebit.firstPayment,
            directDebit.expiresAt
        );
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     MODULE LOGIC
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Validates if a direct debit can be executed
     * @param smartWallet The address of the smart wallet
     * @param id The identifier of the direct debit
     * @param amount The amount to be debited
     * @return valid Whether the direct debit can be executed
     * @return error The specific error if validation fails
     */
    function validateDirectDebit(
        address smartWallet,
        uint128 id,
        uint256 amount
    )
        public
        view
        returns (bool valid, DirectDebitError error)
    {
        DirectDebit memory directDebit = directDebits[smartWallet][id];

        // Check if the direct debit exists
        if (id >= currentIds[smartWallet]) {
            return (false, DirectDebitError.NotActive);
        }
        // Check if the direct debit is active. Has started and not expired
        if (block.timestamp < directDebit.firstPayment || block.timestamp >= directDebit.expiresAt)
        {
            return (false, DirectDebitError.NotActive);
        }
        // Check if the direct debit is due
        if (block.timestamp < lastPayment[smartWallet][id] + directDebit.interval) {
            return (false, DirectDebitError.NotDue);
        }
        // Check if the amount is within the max amount
        if (amount > directDebit.maxAmount) {
            return (false, DirectDebitError.Exceeded);
        }
        // Check if the token is an ERC20 and if the amount is within the balance of the smart
        // wallet
        if (directDebit.token != address(0)) {
            if (amount > IERC20(directDebit.token).balanceOf(smartWallet)) {
                return (false, DirectDebitError.NotEnoughFunds);
            }
        } else {
            if (amount > address(smartWallet).balance) {
                return (false, DirectDebitError.NotEnoughFunds);
            }
        }

        return (true, DirectDebitError.None);
    }

    /**
     * @notice Checks if a direct debit can be executed
     * @param smartWallet The address of the smart wallet
     * @param id The identifier of the direct debit
     * @param amount The amount to be debited
     * @return bool Whether the direct debit can be executed
     */
    function canExecute(
        address smartWallet,
        uint128 id,
        uint256 amount
    )
        external
        view
        returns (bool)
    {
        (bool valid,) = validateDirectDebit(smartWallet, id, amount);
        return valid;
    }

    /**
     * @notice Executes a direct debit payment
     * @dev Only the receiver of the direct debit can execute it
     * @param smartWallet The address of the smart wallet
     * @param id The identifier of the direct debit
     * @param amount The amount to be debited
     */
    function execute(address smartWallet, uint128 id, uint256 amount) external {
        DirectDebit memory directDebit = directDebits[smartWallet][id];

        (bool valid, DirectDebitError error) = validateDirectDebit(smartWallet, id, amount);
        if (!valid) {
            if (error == DirectDebitError.NotActive) {
                revert DirectDebitNotActive();
            } else if (error == DirectDebitError.NotDue) {
                revert DirectDebitNotDue();
            } else if (error == DirectDebitError.Exceeded) {
                revert DirectDebitExceeded();
            } else if (error == DirectDebitError.NotEnoughFunds) {
                revert DirectDebitNotEnoughFunds();
            }
        }
        if (msg.sender != directDebit.receiver) {
            revert DirectDebitNotReceiver();
        }
        // Update last payment timestamp before execution to avoid reentrancy
        lastPayment[smartWallet][id] = block.timestamp;

        // Create execution data based on token type
        Execution memory execution;
        if (directDebit.token == address(0)) {
            // Native token transfer
            execution = Execution({ target: directDebit.receiver, value: amount, callData: "" });
        } else {
            // ERC20 token transfer
            execution =
                ERC20Integration.transfer(IERC20(directDebit.token), directDebit.receiver, amount);
        }

        IERC7579Account(smartWallet).executeFromExecutor(
            ModeLib.encodeSimpleSingle(),
            ExecutionLib.encodeSingle(execution.target, execution.value, execution.callData)
        );
        emit DirectDebitExecuted(msg.sender, id, directDebit.receiver, directDebit.token, amount);
    }

    /*//////////////////////////////////////////////////////////////////////////
                                     METADATA
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * @notice Returns the name of the module
     * @return string The module name
     */
    function name() external pure returns (string memory) {
        return "DirectDebitExecutor";
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
