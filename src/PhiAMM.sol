// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./PhiMath.sol";

/// @title PhiAMM — Golden Ratio Automated Market Maker
/// @notice Asymmetric AMM where buying ARTS has less slippage than selling
/// @dev Uses weighted constant product: reserveARTS^phi * reserveETH^(1/phi) = k
///      Approximated via weighted geometric mean for gas efficiency
contract PhiAMM is ReentrancyGuard {
    using SafeERC20 for IERC20;

    IERC20 public immutable artsToken;
    IERC20 public immutable pairedToken; // WETH or USDC

    uint256 public reserveARTS;
    uint256 public reservePaired;

    // phi-weights: ARTS side weighted by phi/(phi+1) ~ 0.618, paired by 1/(phi+1) ~ 0.382
    uint256 public constant WEIGHT_ARTS = 618033988749894848; // phi/(phi+1) in WAD
    uint256 public constant WEIGHT_PAIRED = 381966011250105152; // 1/(phi+1) in WAD

    // Fee: golden fee 0.618%
    uint256 public constant FEE_WAD = 6180339887498948; // 0.00618 in WAD

    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    uint256 public totalLP;
    mapping(address => uint256) public lpBalance;

    error SlippageExceeded(uint256 amountOut, uint256 minAmountOut);
    error DeadlineExpired(uint256 deadline, uint256 timestamp);

    event Swap(address indexed user, bool buyARTS, uint256 amountIn, uint256 amountOut, uint256 fee);
    event LiquidityAdded(address indexed user, uint256 artsAmount, uint256 pairedAmount, uint256 lpMinted);
    event LiquidityRemoved(address indexed user, uint256 artsAmount, uint256 pairedAmount, uint256 lpBurned);

    constructor(address _arts, address _paired) {
        artsToken = IERC20(_arts);
        pairedToken = IERC20(_paired);
    }

    /// @notice Add initial liquidity
    function addLiquidity(uint256 artsAmount, uint256 pairedAmount) external nonReentrant returns (uint256 lpMinted) {
        require(artsAmount > 0 && pairedAmount > 0, "Zero amounts");

        artsToken.safeTransferFrom(msg.sender, address(this), artsAmount);
        pairedToken.safeTransferFrom(msg.sender, address(this), pairedAmount);

        if (totalLP == 0) {
            // Initial liquidity — LP tokens = geometric mean of deposits
            lpMinted = sqrt(artsAmount * pairedAmount);
            require(lpMinted > MINIMUM_LIQUIDITY, "Insufficient initial liquidity");
            // Burn MINIMUM_LIQUIDITY to address(0) to prevent LP share inflation attack
            lpMinted -= MINIMUM_LIQUIDITY;
            totalLP += MINIMUM_LIQUIDITY;
            lpBalance[address(0)] += MINIMUM_LIQUIDITY;
        } else {
            // Proportional deposit
            uint256 lpFromArts = (artsAmount * totalLP) / reserveARTS;
            uint256 lpFromPaired = (pairedAmount * totalLP) / reservePaired;
            lpMinted = lpFromArts < lpFromPaired ? lpFromArts : lpFromPaired;
        }

        reserveARTS += artsAmount;
        reservePaired += pairedAmount;
        totalLP += lpMinted;
        lpBalance[msg.sender] += lpMinted;

        emit LiquidityAdded(msg.sender, artsAmount, pairedAmount, lpMinted);
    }

    /// @notice Remove liquidity proportionally
    function removeLiquidity(uint256 lpAmount) external nonReentrant returns (uint256 artsOut, uint256 pairedOut) {
        require(lpAmount > 0 && lpBalance[msg.sender] >= lpAmount, "Insufficient LP");

        artsOut = (lpAmount * reserveARTS) / totalLP;
        pairedOut = (lpAmount * reservePaired) / totalLP;

        lpBalance[msg.sender] -= lpAmount;
        totalLP -= lpAmount;
        reserveARTS -= artsOut;
        reservePaired -= pairedOut;

        artsToken.safeTransfer(msg.sender, artsOut);
        pairedToken.safeTransfer(msg.sender, pairedOut);

        emit LiquidityRemoved(msg.sender, artsOut, pairedOut, lpAmount);
    }

    /// @notice Swap tokens using phi-weighted constant product
    /// @param buyARTS true = buy ARTS with paired token, false = sell ARTS for paired token
    /// @param amountIn amount of input token
    function swap(bool buyARTS, uint256 amountIn, uint256 minAmountOut, uint256 deadline) external nonReentrant returns (uint256 amountOut) {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline, block.timestamp);
        require(amountIn > 0, "Zero input");
        require(reserveARTS > 0 && reservePaired > 0, "No liquidity");

        // Apply fee: fee = amountIn * FEE_WAD / WAD
        uint256 fee = PhiMath.wadMul(amountIn, FEE_WAD);
        uint256 amountInAfterFee = amountIn - fee;
        require(amountInAfterFee > 0, "Amount too small for fee");

        if (buyARTS) {
            // Buying ARTS: input paired token, output ARTS
            // With phi-weighting, buying has LESS slippage (weightRatio < 1)
            uint256 weightRatio = PhiMath.wadDiv(WEIGHT_PAIRED, WEIGHT_ARTS); // ~0.618 WAD
            amountOut = _weightedSwap(reserveARTS, reservePaired, amountInAfterFee, weightRatio);

            require(amountOut > 0 && amountOut < reserveARTS, "Insufficient output");

            pairedToken.safeTransferFrom(msg.sender, address(this), amountIn);
            artsToken.safeTransfer(msg.sender, amountOut);

            reservePaired += amountIn;
            reserveARTS -= amountOut;
        } else {
            // Selling ARTS: input ARTS, output paired token
            // With phi-weighting, selling has MORE slippage (weightRatio > 1)
            uint256 weightRatio = PhiMath.wadDiv(WEIGHT_ARTS, WEIGHT_PAIRED); // ~1.618 WAD
            amountOut = _weightedSwap(reservePaired, reserveARTS, amountInAfterFee, weightRatio);

            require(amountOut > 0 && amountOut < reservePaired, "Insufficient output");

            artsToken.safeTransferFrom(msg.sender, address(this), amountIn);
            pairedToken.safeTransfer(msg.sender, amountOut);

            reserveARTS += amountIn;
            reservePaired -= amountOut;
        }

        if (amountOut < minAmountOut) revert SlippageExceeded(amountOut, minAmountOut);

        emit Swap(msg.sender, buyARTS, amountIn, amountOut, fee);
    }

    /// @notice Weighted swap calculation
    /// @dev amountOut = reserveOut * amountIn / (reserveIn + amountIn * weightRatio)
    ///      weightRatio is WAD-scaled. wadMul(amountIn, weightRatio) returns token-scale result.
    function _weightedSwap(
        uint256 reserveOut,
        uint256 reserveIn,
        uint256 amountIn,
        uint256 weightRatio
    ) internal pure returns (uint256) {
        uint256 weightedInput = PhiMath.wadMul(amountIn, weightRatio);
        uint256 denominator = reserveIn + weightedInput;
        if (denominator == 0) return 0;
        return (reserveOut * amountIn) / denominator;
    }

    /// @notice Get expected output for a swap (view)
    function getAmountOut(bool buyARTS, uint256 amountIn) external view returns (uint256) {
        if (reserveARTS == 0 || reservePaired == 0) return 0;
        uint256 fee = PhiMath.wadMul(amountIn, FEE_WAD);
        uint256 amountInAfterFee = amountIn > fee ? amountIn - fee : 0;
        if (amountInAfterFee == 0) return 0;

        if (buyARTS) {
            uint256 weightRatio = PhiMath.wadDiv(WEIGHT_PAIRED, WEIGHT_ARTS);
            return _weightedSwap(reserveARTS, reservePaired, amountInAfterFee, weightRatio);
        } else {
            uint256 weightRatio = PhiMath.wadDiv(WEIGHT_ARTS, WEIGHT_PAIRED);
            return _weightedSwap(reservePaired, reserveARTS, amountInAfterFee, weightRatio);
        }
    }

    function sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}
