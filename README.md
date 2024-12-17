# AutoYieldDistributor ERC-7579 Executor

The AutoYieldDistributor is a smart contract module that automatically optimizes yield across different ERC4626 vaults for ERC-7579 compliant smart wallets. It monitors vault performance and moves funds to higher-yielding vaults when meaningful improvements in APR are detected. Once set up anyone can move the funds between vaults provided that the wallet owners configuration is followed.

## Overview

- **Automated Yield Management**: Automatically moves funds between vaults when better yields are available
- **ERC4626 Compatible**: Works with any ERC4626-compliant yield vaults
- **Smart Wallet Integration**: Built for ERC-7579 compliant smart wallets
- **APR Monitoring**: Takes regular snapshots of vault performance to calculate APRs. Up to the wallet owner to decide their apr configurations

## How It Works

1. **Vault Registration**: Vaults are registered by smart wallet for specific assets using `registerVault()`
2. **Snapshots Taken**: Regular snapshots are taken using `snapshotVaults()` to track vault performance. Any user can take snapshots provided that the vaults are registered
3. **Yield Optimization**: The module automatically moves funds when better yields are detected via `execute()`. Anyone can call this function provided that the move passes the wallet owners configuration checks.

### Configuration Options

Each smart wallet can configure the following parameters for yield optimization:

- **approvedVaults**: Array of ERC4626 vault addresses that are approved for use
- **minImprovement**: Minimum APR improvement required (in basis points) before moving funds
- **snapshotsRequired**: Minimum number of snapshots needed before calculating APR (must be ≥2)
- **maxTimeBetweenSnapshots**: Maximum allowed time between snapshots (must be >6 hours which is min time between snapshots). Suggested to be set to > 1 day
- **maxInvestment**: Maximum amount that can be invested in any single vault
- **aprCalculationMethod**: Method for calculating APR:
  - `AVERAGE`: Uses average of APRs between consecutive snapshots
  - `TOTAL`: Calculates APR using first and last snapshot only

### Snapshots
- Price-per-share snapshots are taken a maximun of 6+ hours apart

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