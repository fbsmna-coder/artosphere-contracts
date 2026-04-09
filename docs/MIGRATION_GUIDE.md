# Artosphere Multisig Migration Guide

## Overview

This guide covers migrating all Artosphere contract admin roles from a single deployer EOA (`0xED7E49Cd347aAeF4879AF0c42C3B74780299a6A6`) to a Gnosis Safe multisig.

## Step 1: Create the Gnosis Safe

1. Go to [https://app.safe.global](https://app.safe.global)
2. Connect your wallet and select **Base** network
3. Click **Create New Safe**
4. Add 5 signers (trusted team members / hardware wallets)
5. Set threshold to **3-of-5** (recommended)
6. Deploy the Safe and note the address

### Signer recommendations
- Use hardware wallets (Ledger/Trezor) for at least 3 of 5 signers
- Distribute signers geographically
- Never put all 5 keys on the same device or in the same location

## Step 2: Configure Environment

Add these variables to your `.env` file:

```bash
SAFE_ADDRESS=0x<your-gnosis-safe-address>

# Contract addresses (already in .env if previously deployed)
PHICOIN_PROXY=0x1C11133D4dDa9D85a6696B020b0c48e2c24Ed0bf
PHISTAKING_PROXY=0x5ba76643E3ef93Ab76Efc8e162594405A3c79f7B
DISCOVERY_STAKING_PROXY=0x3Fc4d3466743e0c068797D64A91EF7A8826a19e2
DISCOVERY_NFT=0x5a6513f70f29BCc3Bd82f7AeC66bF99671D1DBdD
CONVICTION_NFT=<address>
FIBONACCI_FUSION=0x01A042e101eCE5872bCAe66B8E4B115044616277
```

## Step 3: Dry Run (CRITICAL)

**Always dry-run first** (without `--broadcast`):

```bash
source .env
forge script script/MigrateToMultisig.s.sol \
  --rpc-url $BASE_MAINNET_RPC \
  -vvvv
```

Verify in the output:
- All `grantRole` calls succeed
- All `renounceRole` calls succeed
- No reverts

## Step 4: Verify Safe Works Before Renouncing

Before broadcasting the full script, you can manually test the Safe by:

1. Granting a role to the Safe (without renouncing from EOA)
2. Proposing a test transaction from the Safe (e.g., `setMedianBalance` on PhiCoin)
3. Collecting 3-of-5 signatures and executing
4. If the Safe works correctly, proceed to full migration

## Step 5: Execute Migration

```bash
source .env
forge script script/MigrateToMultisig.s.sol \
  --rpc-url $BASE_MAINNET_RPC \
  --broadcast \
  -vvvv
```

## Step 6: Verify Roles After Migration

Check that the Safe has all roles and the deployer has none:

```bash
# Check Safe has DEFAULT_ADMIN_ROLE on PhiCoin
cast call $PHICOIN_PROXY \
  "hasRole(bytes32,address)(bool)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  $SAFE_ADDRESS --rpc-url $BASE_MAINNET_RPC

# Check deployer lost DEFAULT_ADMIN_ROLE on PhiCoin
cast call $PHICOIN_PROXY \
  "hasRole(bytes32,address)(bool)" \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  $DEPLOYER_ADDRESS --rpc-url $BASE_MAINNET_RPC

# Check UPGRADER_ROLE (keccak256("UPGRADER_ROLE"))
UPGRADER_ROLE=$(cast keccak "UPGRADER_ROLE")
cast call $PHICOIN_PROXY \
  "hasRole(bytes32,address)(bool)" \
  $UPGRADER_ROLE $SAFE_ADDRESS --rpc-url $BASE_MAINNET_RPC

# Repeat for PhiStaking, DiscoveryStaking, etc.
```

## What the Script Does

For each contract, in this exact order:

| # | Contract | Roles Transferred |
|---|----------|-------------------|
| 1 | PhiCoin (UUPS proxy) | `DEFAULT_ADMIN_ROLE`, `UPGRADER_ROLE` |
| 2 | PhiStaking (UUPS proxy) | `DEFAULT_ADMIN_ROLE`, `UPGRADER_ROLE` |
| 3 | DiscoveryStaking (UUPS proxy) | `DEFAULT_ADMIN_ROLE`, `UPGRADER_ROLE` |
| 4 | ArtosphereDiscovery | `DEFAULT_ADMIN_ROLE`, `ADMIN_ROLE` |
| 5 | ConvictionNFT | `DEFAULT_ADMIN_ROLE` |
| 6 | FibonacciFusion | `DEFAULT_ADMIN_ROLE` |

The order within each contract is always: **grant to Safe first, then renounce from deployer**. This ensures the deployer never loses access before the Safe has it.

## Rollback Plan

**Before renouncing (dry run stage):** Full rollback is trivial -- simply don't broadcast.

**After renouncing:** There is no rollback. The deployer EOA permanently loses admin access. This is by design -- the whole point is to eliminate single-key risk.

If you need a safety net:
1. Run the script in two phases (manually):
   - Phase A: Grant roles to Safe only (comment out renounce calls)
   - Test the Safe thoroughly
   - Phase B: Renounce roles from deployer (uncomment renounce calls)

## Security Checklist

- [ ] Safe deployed on Base mainnet with 3-of-5 threshold
- [ ] All 5 signers confirmed they can sign transactions
- [ ] Dry run completed without reverts
- [ ] Safe tested with a non-critical transaction
- [ ] All contract addresses in `.env` verified on Basescan
- [ ] Migration broadcast executed
- [ ] All roles verified with `cast call` after migration
- [ ] Deployer EOA confirmed to have zero admin roles
