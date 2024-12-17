# AutoYieldDistributor ERC-7579 Executor

The AutoYieldDistributor is a smart contract module that automatically optimizes yield across different ERC4626 vaults for ERC-7579 compliant smart wallets. It monitors vault performance and moves funds to higher-yielding vaults when meaningful improvements in APR are detected.

## Features

- **Automated Yield Optimization**: Automatically moves funds between vaults when better yields are available
- **ERC4626 Vault Integration**: Works with any ERC4626-compliant yield vaults
- **Performance Monitoring**: Takes regular snapshots of vault performance to calculate APRs
- **Configurable Parameters**:
  - Minimum APR improvement threshold (in basis points)
  - Snapshot intervals (minimum 6 hours between snapshots)
  - Multiple vault support per asset

## How It Works

1. **Vault Registration**: Vaults are registered for specific assets using `registerVault()`
2. **Performance Tracking**: Regular snapshots are taken using `snapshotVaults()` to track vault performance
3. **Yield Optimization**: The module automatically moves funds when better yields are detected via `execute()`

## Key Components

### Snapshots
- Price-per-share snapshots are taken every 6+ hours
- APR is calculated using time-weighted performance data
- Minimum of 2 snapshots required before optimization decisions

### Validation
Each investment change is validated to ensure:
- Both vaults are properly registered
- Vaults handle the same underlying asset
- Sufficient performance data exists
- APR improvement exceeds minimum threshold

## Usage

### Register a New Vault
```solidity
function registerVault(address asset, address vault) external
```

### Take Snapshots
```solidity
function snapshotVaults(address[] calldata vaults) external
```

### Execute Yield Optimization
```solidity
function execute(
    address smartWallet,
    address fromVault,
    address toVault,
    uint256 amount
) external
```

## Testing the Module

### Install dependencies
```shell
pnpm install
```

### Build
```shell
forge build
```

### Test
```shell
forge test
```