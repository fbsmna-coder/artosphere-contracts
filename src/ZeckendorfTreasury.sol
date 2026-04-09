// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./PhiMath.sol";

/// @title ZeckendorfTreasury — Treasury with Fibonacci-proportioned compartments
/// @author F.B. Sapronov / Artosphere Phase 2
/// @notice Total supply F(16) = 987,000,000 ARTS is decomposed into 6 pure Fibonacci
///         compartments: 987 = 610+233+89+34+13+8 (Zeckendorf theorem).
///         Each allocation = a Fibonacci number × 10⁶. Community = 61.8% = 1/φ.
contract ZeckendorfTreasury is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable artsToken;

    enum Compartment {
        LiquidityMining, // Largest Fibonacci component
        EcosystemTreasury,
        StakingRewards,
        TeamVesting,
        CommunityGrants,
        InsuranceFund
    }

    /// @dev Total number of compartments (must match enum length)
    uint256 public constant NUM_COMPARTMENTS = 6;

    struct CompartmentInfo {
        string name;
        uint256 allocation; // total allocated in token units (18 decimals)
        uint256 distributed; // already distributed
        address controller; // who can distribute from this compartment
    }

    mapping(Compartment => CompartmentInfo) public compartments;

    event CompartmentFunded(Compartment indexed comp, uint256 amount);
    event CompartmentDistributed(Compartment indexed comp, address indexed to, uint256 amount);
    event ControllerChanged(Compartment indexed comp, address newController);

    constructor(address _token) Ownable(msg.sender) {
        artsToken = IERC20(_token);

        // Pure Fibonacci Zeckendorf decomposition of F(16) = 987 (million ARTS):
        // 987 = 610 + 233 + 89 + 34 + 13 + 8
        // Each allocation = a Fibonacci number × 10⁶
        // Community (Liquidity) = 610M = 61.8% = 1/φ of total
        _initCompartment(Compartment.LiquidityMining, "Liquidity Mining", 610_000_000e18);   // F(15) = 610
        _initCompartment(Compartment.EcosystemTreasury, "Ecosystem Treasury", 233_000_000e18); // F(13) = 233
        _initCompartment(Compartment.StakingRewards, "Staking Rewards", 89_000_000e18);       // F(11) = 89
        _initCompartment(Compartment.TeamVesting, "Team Vesting", 34_000_000e18);             // F(9) = 34
        _initCompartment(Compartment.CommunityGrants, "Community Grants", 13_000_000e18);     // F(7) = 13
        _initCompartment(Compartment.InsuranceFund, "Insurance Fund", 8_000_000e18);          // F(6) = 8
    }

    function _initCompartment(Compartment comp, string memory name, uint256 allocation) internal {
        compartments[comp] = CompartmentInfo({
            name: name,
            allocation: allocation,
            distributed: 0,
            controller: msg.sender
        });
    }

    function setController(Compartment comp, address controller) external onlyOwner {
        require(controller != address(0), "Zero address");
        compartments[comp].controller = controller;
        emit ControllerChanged(comp, controller);
    }

    function distribute(Compartment comp, address to, uint256 amount) external {
        CompartmentInfo storage c = compartments[comp];
        require(msg.sender == c.controller, "Not controller");
        require(c.distributed + amount <= c.allocation, "Exceeds allocation");
        require(to != address(0), "Zero address");
        require(amount > 0, "Zero amount");

        c.distributed += amount;
        artsToken.safeTransfer(to, amount);

        emit CompartmentDistributed(comp, to, amount);
    }

    function remaining(Compartment comp) external view returns (uint256) {
        CompartmentInfo storage c = compartments[comp];
        return c.allocation - c.distributed;
    }

    function totalAllocated() external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < NUM_COMPARTMENTS; i++) {
            total += compartments[Compartment(i)].allocation;
        }
        return total;
    }

    function totalDistributed() external view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < NUM_COMPARTMENTS; i++) {
            total += compartments[Compartment(i)].distributed;
        }
        return total;
    }
}
