# Artosphere (ARTS)

**The first DeFi protocol where every parameter derives from proven physics.**

Two inputs: the Planck mass M_Pl and the golden ratio φ = (1+√5)/2.
36 outputs: all Standard Model parameters, dark matter, dark energy, and cosmology.
Zero free parameters.

🌐 **Website:** [artosphere.org](https://artosphere.org)
📄 **Journal:** [scholar.artosphere.org](https://scholar.artosphere.org)
🔒 **Verify:** [scholar.artosphere.org/verify](https://scholar.artosphere.org/verify)
📊 **DeFi:** [defi.artosphere.org](https://defi.artosphere.org)
📑 **Whitepaper:** [Artosphere Whitepaper v2.1](docs/Artosphere_Whitepaper_v2.md)
🔬 **Master Action:** [DOI: 10.5281/zenodo.19482719](https://doi.org/10.5281/zenodo.19482719)

## Token

| Parameter | Value | Source |
|-----------|-------|--------|
| **Name** | Artosphere | — |
| **Symbol** | ARTS | — |
| **Chain** | Base Mainnet (Chain 8453) | Coinbase L2 |
| **Max Supply** | 987,000,000 | F(16) × 10⁶ |
| **Emission** | Fibonacci schedule | φ-decay envelope |
| **Burn** | Spiral Burn → floor F(34) | Asymptotic deflation |
| **Base Fee** | 0.618% | 1/φ (Nash equilibrium) |
| **Governance** | 61.8% supermajority | 1/φ |
| **Quorum** | 30.9% | sin²θ₁₂ (JUNO confirmed, 0.02σ) |

## Deployed Contracts (Base Mainnet)

| Contract | Address | Type |
|----------|---------|------|
| **Artosphere (ARTS)** | [`0x1C11133D...Ed0bf`](https://basescan.org/address/0x1C11133D4dDa9D85a6696B020b0c48e2c24Ed0bf) | ERC-20 (UUPS) |
| **ArtosphereDiscovery** | [`0xA345C41e...1D49`](https://basescan.org/address/0xA345C41e74Afc16f9071C0EAa5Ac71b0BDfe1D49) | ERC-721 Soulbound (15 NFTs) |
| **DiscoveryStaking** | [`0x3Fc4d346...19e2`](https://basescan.org/address/0x3Fc4d3466743e0c068797D64A91EF7A8826a19e2) | Prediction Market (UUPS) |
| **DiscoveryOracle** | [`0xd0f23765...cBE0`](https://basescan.org/address/0xd0f23765Fe50b59f539fF695B17aF5b23D4AcBE0) | Multisig Oracle |
| **ResearcherRegistry** | [`0x295410735...1cc9`](https://basescan.org/address/0x295410735a0d9f68850a94b97a43fff7a5961cc9) | ORCID On-Chain |
| **PhiStaking** | [`0x37ab9c36...6a4`](https://basescan.org/address/0x37ab9c369d3bdf428d3081f54e570a63f4bcd6a4) | Fibonacci APY (UUPS) |
| **PhiGovernor** | [`0xae286dcA...680`](https://basescan.org/address/0xae286dca8e8bb431dbea0049f9ee7dad5f642680) | φ-Supermajority |
| **ZeckendorfTreasury** | [`0x250161bF...b55`](https://basescan.org/address/0x250161bF42227171172e847B43623e9a83513b55) | 6 Fibonacci Compartments |
| **PhiVesting** | [`0xc728062A...8Bf`](https://basescan.org/address/0xc728062a36b2764d8022b9afddf498aed44538bf) | Fibonacci Schedule |
| **GoldenMirror** | [`0xdB212d65...9ca`](https://basescan.org/address/0xdb212d6500d2a243c6636f73cea982a961b9b9ca) | Liquid Staking (gARTS) |
| **MatryoshkaStaking** | [`0x25DdA634...C22`](https://basescan.org/address/0x25dda63461dfbd35228fcfbe89f1e8092332bc22) | 5-Layer Nested |
| **PhiAMM** | [`0xF32c9784...575`](https://basescan.org/address/0xf32c97846963c335eb78969c8c732945edc4e575) | Asymmetric AMM |
| **NashFee** | [`0xb11e8116...E52`](https://basescan.org/address/0xb11e81168f97b6241cb037d9d02b282879ec3e52) | Game-Theoretic Fee |
| **TimelockController** | [`0x9ab3A97a...bFe`](https://basescan.org/address/0x9ab3A97a2F1bf026C55cEF439D92C5C8D5C30bFe) | Governance Timelock |

**Total: 20 contracts on Base Mainnet. All verified on Sourcify.**

## Discovery Staking — Prediction Market for Physics

Users stake ARTS tokens on whether scientific discoveries will be experimentally confirmed or refuted. Resolution distributes the losing pool via φ-Cascade v2:

- **61.80%** (φ⁻¹) → Winners
- **23.60%** (φ⁻³) → Burned (deflationary)
- **9.02%** (φ⁻⁵) → Scientist (discovery creator)
- **5.57%** (φ⁻⁶) → Treasury

**Math proof:** φ⁻¹ + φ⁻³ + φ⁻⁵ + φ⁻⁶ = 1 (exact, by φ² = φ + 1)

## 15 Soulbound Discovery NFTs

On-chain proof of scientific priority for 14 unique Zenodo concept records:

| ID | Paper | DOI | Accuracy |
|----|-------|-----|----------|
| 0 | 28 SM Parameters from φ | [19481854](https://doi.org/10.5281/zenodo.19481854) | 0.61% mean |
| 5 | Solar Neutrino Mixing (JUNO) | [19472827](https://doi.org/10.5281/zenodo.19472827) | 0.02σ |
| 11 | Higgs-Flavor Identity | [19480973](https://doi.org/10.5281/zenodo.19480973) | 0.0007% |
| 13 | Paper VIII: Cosmology | [19482718](https://doi.org/10.5281/zenodo.19482718) | exact |
| 14 | Master Action v2.0 (36 params) | [19482719](https://doi.org/10.5281/zenodo.19482719) | 0.61% |

## Build & Test

```bash
# Install
forge install

# Build
forge build

# Test (45 Discovery + Registry tests, 205+ total)
forge test

# Deploy (requires .env with PRIVATE_KEY)
forge script script/Deploy.s.sol --broadcast --rpc-url https://mainnet.base.org
```

## Architecture

```
src/
├── PhiMath.sol              — Golden ratio WAD arithmetic library
├── PhiCoin.sol              — ERC-20 with Fibonacci emission + Spiral Burn
├── PhiStaking.sol           — 3-tier Fibonacci staking (UUPS)
├── PhiGovernor.sol          — φ-supermajority governance
├── PhiVesting.sol           — Fibonacci unlock schedule
├── ArtosphereDiscovery.sol  — Soulbound scientific priority NFTs
├── ArtosphereConstants.sol  — Physics-derived protocol constants
├── DiscoveryStaking.sol     — Prediction market with φ-Cascade v2
├── DiscoveryOracle.sol      — Multisig resolution with DOI evidence
├── ResearcherRegistry.sol   — ORCID on-chain + Fibonacci reputation
├── FibonacciFusion.sol      — τ⊗τ=1⊕τ deflationary mechanism
├── MatryoshkaStaking.sol    — 5-layer nested staking
├── GoldenMirror.sol         — Liquid staking (gARTS)
├── PhiAMM.sol               — Asymmetric golden-ratio AMM
├── NashFee.sol              — Game-theoretic dynamic fee
├── ZeckendorfTreasury.sol   — 6 Fibonacci compartments
├── ArtosphereQuests.sol     — Learn-to-earn quests
└── PhiCertificate.sol       — Soulbound achievement NFTs
```

## Author

**F.B. Sapronov** | [ORCID: 0009-0008-1747-1200](https://orcid.org/0009-0008-1747-1200) | 17 Zenodo DOIs | [artosphere.org](https://artosphere.org)

## License

MIT
