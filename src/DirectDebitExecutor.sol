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

struct DirectDebit {
    address token; // 0x0 for native token
    address receiver; // address to receive the direct debit
    uint128 maxAmount; // maximum amount to be spent per interval
    uint128 interval; // interval between direct debits
    uint128 firstPayment; // timestamp of first direct debit
    uint128 expiresAt; // timestamp when the direct debit expires
}

contract DirectDebitExecutor is ERC7579ExecutorBase {
    /*//////////////////////////////////////////////////////////////////////////
                            CONSTANTS & STORAGE
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
        uint128 indexed id,
        address indexed receiver,
        address token,
        uint256 maxAmount,
        uint128 interval,
        uint128 firstPayment,
        uint128 expiresAt
    );
    event DirectDebitExecuted(
        address indexed smartWallet,
        uint128 indexed id,
        address indexed receiver,
        address token,
        uint256 amount
    );
    event DirectDebitAmended(
        address indexed smartWallet,
        uint128 indexed id,
        address indexed receiver,
        address token,
        uint256 maxAmount,
        uint128 interval,
        uint128 firstPayment,
        uint128 expiresAt
    );

    mapping(address smartWallet => mapping(uint128 id => DirectDebit directDebit)) public
        directDebits;
    mapping(address smartWallet => mapping(uint128 id => uint128 lastPayment)) public lastPayment;
    mapping(address smartWallet => uint128 currentId) public currentIds;
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

    function cancelDirectDebit(uint128 id) external {
        directDebits[msg.sender][id].expiresAt = uint128(block.timestamp);
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

        if (id >= currentIds[smartWallet]) {
            return (false, DirectDebitError.NotActive);
        }
        if (block.timestamp < directDebit.firstPayment || block.timestamp > directDebit.expiresAt) {
            return (false, DirectDebitError.NotActive);
        }
        if (block.timestamp < lastPayment[smartWallet][id] + directDebit.interval) {
            return (false, DirectDebitError.NotDue);
        }
        if (amount > directDebit.maxAmount) {
            return (false, DirectDebitError.Exceeded);
        }
        if (directDebit.token != address(0)) {
            // TODO: add ERC20 integration
            // if (amount > IERC20(smartWallet).balanceOf(directDebit.token)) {
            //     return (false, DirectDebitError.NotEnoughFunds);
            // }
        } else {
            if (amount > address(smartWallet).balance) {
                return (false, DirectDebitError.NotEnoughFunds);
            }
        }

        return (true, DirectDebitError.None);
    }

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
        lastPayment[smartWallet][id] = uint128(block.timestamp);

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
                                     INTERNAL
    //////////////////////////////////////////////////////////////////////////*/

    /*//////////////////////////////////////////////////////////////////////////
                                     METADATA
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * The name of the module
     *
     * @return name The name of the module
     */
    function name() external pure returns (string memory) {
        return "DirectDebitExecutor";
    }

    /**
     * The version of the module
     *
     * @return version The version of the module
     */
    function version() external pure returns (string memory) {
        return "0.0.1";
    }

    /**
     * Check if the module is of a certain type
     *
     * @param typeID The type ID to check
     *
     * @return true if the module is of the given type, false otherwise
     */
    function isModuleType(uint256 typeID) external pure override returns (bool) {
        return typeID == TYPE_EXECUTOR;
    }
}
