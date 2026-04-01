// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./PhiMath.sol";

/// @title NashFee — Golden Nash Equilibrium Fee Discovery
/// @notice Dynamic fee that converges to 0.618% via game theory
contract NashFee is Ownable {
    uint256 public currentFee; // in WAD (e.g., 6180339887498948 = 0.618%)
    uint256 public constant MIN_FEE = 2360679774997896; // 0.236% ~ 0.618/phi^2
    uint256 public constant MAX_FEE = 10000000000000000; // 1.0%
    uint256 public constant EQUILIBRIUM_FEE = 6180339887498948; // 0.618%
    uint256 public constant ADJUSTMENT_RATE = 100000000000000; // 0.01% per update

    // Signals from on-chain behavior
    uint256 public holderSignal; // avg holding duration (higher = want more burn)
    uint256 public traderSignal; // trading volume (higher = want less fee)
    uint256 public lpSignal; // LP depth (higher = want stable fee)

    uint256 public lastUpdateTimestamp;
    uint256 public constant UPDATE_INTERVAL = 1 hours;

    event FeeUpdated(uint256 oldFee, uint256 newFee, uint256 holderSig, uint256 traderSig, uint256 lpSig);

    constructor() Ownable(msg.sender) {
        currentFee = EQUILIBRIUM_FEE;
        lastUpdateTimestamp = block.timestamp;
    }

    /// @notice Update signals (called by authorized contracts)
    function updateSignals(uint256 _holder, uint256 _trader, uint256 _lp) external onlyOwner {
        holderSignal = _holder;
        traderSignal = _trader;
        lpSignal = _lp;
    }

    /// @notice Recalculate fee based on current signals
    function rebalanceFee() external {
        require(block.timestamp >= lastUpdateTimestamp + UPDATE_INTERVAL, "Too soon");

        uint256 oldFee = currentFee;

        // If holder signal > trader signal, fee should increase (more burn)
        // If trader signal > holder signal, fee should decrease (more volume)
        // LP signal acts as damper
        if (holderSignal > traderSignal) {
            uint256 pressure = ADJUSTMENT_RATE;
            if (lpSignal > 0) {
                // Dampen: pressure = pressure * WAD / (WAD + lpSignal)
                pressure = PhiMath.wadMul(pressure, PhiMath.wadDiv(PhiMath.WAD, PhiMath.WAD + lpSignal));
            }
            currentFee += pressure;
        } else if (traderSignal > holderSignal) {
            uint256 pressure = ADJUSTMENT_RATE;
            if (lpSignal > 0) {
                pressure = PhiMath.wadMul(pressure, PhiMath.wadDiv(PhiMath.WAD, PhiMath.WAD + lpSignal));
            }
            if (currentFee > pressure) {
                currentFee -= pressure;
            }
        }
        // else: signals balanced, fee stays (Nash equilibrium)

        // Clamp to [MIN_FEE, MAX_FEE]
        if (currentFee < MIN_FEE) currentFee = MIN_FEE;
        if (currentFee > MAX_FEE) currentFee = MAX_FEE;

        // Mean reversion toward equilibrium (phi-weighted)
        // Pull strength = 1 - 1/phi = 1/phi^2 ~ 0.382
        uint256 pullStrength = PhiMath.WAD - PhiMath.PHI_INV; // ~0.382 WAD
        if (currentFee > EQUILIBRIUM_FEE) {
            uint256 deviation = currentFee - EQUILIBRIUM_FEE;
            uint256 pull = PhiMath.wadMul(deviation, pullStrength);
            currentFee -= pull > deviation ? deviation : pull;
        } else if (currentFee < EQUILIBRIUM_FEE) {
            uint256 deviation = EQUILIBRIUM_FEE - currentFee;
            uint256 pull = PhiMath.wadMul(deviation, pullStrength);
            currentFee += pull > deviation ? deviation : pull;
        }

        lastUpdateTimestamp = block.timestamp;
        emit FeeUpdated(oldFee, currentFee, holderSignal, traderSignal, lpSignal);
    }

    /// @notice Get current fee in WAD
    function getFee() external view returns (uint256) {
        return currentFee;
    }

    /// @notice Calculate fee amount for a given transfer
    function calculateFee(uint256 amount) external view returns (uint256) {
        return PhiMath.wadMul(amount, currentFee);
    }
}
