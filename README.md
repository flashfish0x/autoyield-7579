# Direct Debit ERC-7579 Executor

The DirectDebitExecutor is a module that enables recurring payments (direct debits) for ERC-7579 compliant smart wallets. It allows account owners to authorize recurring payments to specific receivers up to a maximum amount at defined intervals. Similar to traditional bank direct debits. 

Once authorized, the receiver can execute payments when they are due. The receiver specifies the amount to be paid up to the maximum amount authorized by the account owner.

## Features

- **Native Token & ERC20 Support**: Supports both native token (ETH) and ERC20 token payments
- **Configurable Parameters**: Each direct debit can be configured with:
  - Maximum payment amount per interval
  - Payment interval duration
  - Start time for first payment
  - Expiration timestamp
  - Token type and receiver address
- **Payment Controls**: 
  - Payments can only be initiated by the authorized receiver
  - Amount cannot exceed the configured maximum
  - Payments must respect the configured interval
  - Direct debits automatically expire at the set timestamp
  - Insufficient funds are rejected

## How It Works

1. **Setup**: Account owner creates a direct debit by calling `createDirectDebit()` with the desired parameters
2. **Execution**: The authorized receiver can call `execute()` to collect payments when they are due
3. **Management**: Account owner can:
   - Cancel existing direct debits using `cancelDirectDebit()`
   - Modify direct debit parameters using `amendDirectDebit()`

## Validation

Each payment attempt is validated to ensure:
- The direct debit exists and is active
- The payment interval has elapsed since last payment
- The requested amount is within limits
- The account has sufficient funds
- The caller is the authorized receiver

## Testing the Module

### Install dependencies

```shell
pnpm install
```

### Building modules

```shell
forge build
```

### Testing modules

```shell
forge test
```