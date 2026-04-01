# Artosphere (ARTS) -- Golden Ratio DeFi Protocol

> **DISCLAIMER:** This software is experimental and UNAUDITED. Deployed on Base Sepolia TESTNET only. Do not use with real funds. Not financial advice. Not audited for production use. Use at your own risk.

> The first cryptocurrency where every economic parameter derives from phi = (1+sqrt(5))/2.

## Overview

Artosphere is a DeFi protocol built entirely on the mathematics of the golden ratio. Token emission follows Fibonacci sequences, staking rewards decay by powers of phi, governance requires a phi-supermajority (61.8%), and vesting unlocks at Fibonacci month boundaries. The protocol implements the economic framework described in the [Artosphere Hypothesis](https://github.com/fbsmna-coder/phicoin) (F.B. Sapronov, 2026), which proposes that phi-based systems exhibit natural convergence toward equilibrium.

The golden ratio creates economically self-balancing mechanics: early holders earn more but lock longer, supply deflation follows a spiral curve, whale behavior is mathematically dampened, and fees converge to Nash equilibrium at 0.618%.

## Architecture

The protocol consists of 12 Solidity contracts on Foundry (Solidity 0.8.24, OpenZeppelin 5.x, UUPS upgradeable):

| Contract | Description |
|---|---|
| `PhiMath.sol` | Pure math library: Fibonacci, phi powers, Zeckendorf decomposition, WAD arithmetic |
| `PhiCoin.sol` | ERC-20 token (ARTS): Fibonacci emission, Proof-of-Patience, Spiral Burn, Anti-Whale |
| `PhiStaking.sol` | Stake ARTS with 3 Fibonacci lock tiers (5/21/55 days), golden-ratio-decay APY |
| `PhiGovernor.sol` | Governance with phi-supermajority (61.8%), tier-weighted voting, F(13)=233 block period |
| `PhiVesting.sol` | Team/investor vesting with Fibonacci unlock schedule (1,1,2,3,5,8,13,21 months) |
| `ArtosphereQuests.sol` | 8 educational quests with Fibonacci durations and rewards |
| `GoldenMirror.sol` | gARTS synthetic token: stake ARTS, receive phi x amount in liquid gARTS |
| `MatryoshkaStaking.sol` | 5-layer nested staking where one deposit earns across all tiers simultaneously |
| `ZeckendorfTreasury.sol` | Treasury split into 6 Fibonacci-proportioned compartments |
| `PhiAMM.sol` | Asymmetric AMM where buying ARTS has less slippage than selling (phi-weighted) |
| `PhiCertificate.sol` | Soulbound (non-transferable) NFT achievement certificates |
| `NashFee.sol` | Dynamic fee that converges to 0.618% via game-theoretic signals |

## Key Features

### 1. Proof-of-Patience
Holders accumulate "temporal mass" over time. Transfer weight scales with how long tokens have been held, rewarding patience over speculation.

### 2. Spiral Burn Engine
Each transfer burns a fraction of tokens. The burn rate decays as circulating supply approaches a floor, following a logarithmic spiral curve toward deflation equilibrium.

### 3. Anti-Whale Limiter
Transfers exceeding phi^2 x median balance trigger progressively higher fees, mathematically dampening concentration without hard caps.

### 4. Fibonacci Quests
Eight on-chain quests with Fibonacci-duration lockups (1 to 21 days). Completing quests teaches phi-math concepts and earns ARTS rewards.

### 5. Soulbound Certificates
Non-transferable ERC-721 tokens awarded for protocol milestones (quest completion, staking tenure, governance participation). On-chain phi-inspired hash generates unique certificate IDs.

### 6. Matryoshka Staking
Five nested staking layers. Depositing at tier N automatically enrolls the user in all lower tiers (0..N), with each layer contributing phi^k multiplier to the combined reward.

### 7. Zeckendorf Treasury
Protocol treasury is decomposed into 6 Fibonacci-proportioned compartments using Zeckendorf's theorem (every positive integer has a unique representation as a sum of non-consecutive Fibonacci numbers).

### 8. Phi-AMM
Asymmetric constant-product AMM with phi-weighted reserves. Buying ARTS experiences less slippage than selling, creating natural buy pressure.

### 9. Golden Mirror (gARTS)
Liquid staking derivative. Staking ARTS mints gARTS at a phi x rate, creating a tradeable synthetic that tracks staked value.

### 10. Nash Fee
Transaction fees are not fixed. A game-theoretic mechanism adjusts fees based on network signals (volume, volatility, liquidity), converging to the golden ratio fee of 0.618%.

## Token Details

| Parameter | Value |
|---|---|
| Name | Artosphere |
| Symbol | ARTS |
| Max Supply | 1,618,033,988 ARTS |
| Decimals | 18 |
| Standard | ERC-20 (ERC20Votes + ERC20Permit) |
| Upgradeability | UUPS Proxy |
| Target Chain | Base L2 (EVM compatible) |
| Solidity | 0.8.24 |

## Build and Test

```bash
# Install dependencies
forge install

# Build
forge build

# Run all tests (205 tests)
forge test

# Run tests with verbosity
forge test -vvv

# Gas report
forge test --gas-report

# Format
forge fmt
```

## Deploy

```bash
# Deploy to testnet (Base Sepolia)
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify

# Deploy to mainnet
forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify --etherscan-api-key $ETHERSCAN_KEY
```

## Security

- **Test coverage:** 205 tests across 12 test suites (all passing)
- **Fuzz testing:** Foundry fuzzer with 256 runs per property
- **Dependencies:** OpenZeppelin Contracts 5.6.1 (audited)
- **Patterns:** UUPS upgradeable, AccessControl RBAC, ReentrancyGuardTransient
- **Audit status:** Internal audit complete (13 findings identified and resolved). Independent audit pending.

## Project Structure

```
phicoin-contracts/
  src/               # 12 Solidity contracts
  test/              # 12 test suites (Foundry)
  script/            # Deployment scripts
  lib/               # Dependencies (OpenZeppelin, forge-std)
  foundry.toml       # Foundry configuration
```

## License

MIT

## Links

- [Solidity Contracts](https://github.com/fbsmna-coder/phicoin-contracts) (this repo)
- [Rust Core](https://github.com/fbsmna-coder/phicoin) (cryptographic primitives)
