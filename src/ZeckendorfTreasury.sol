// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./PhiMath.sol";

/// @title ZeckendorfTreasury — Treasury with Fibonacci-proportioned compartments
/// @author IBG Technologies / Artosphere Phase 2
/// @notice Total supply (1,618,033,988 ARTS) is decomposed into 6 Fibonacci compartments
///         inspired by the Zeckendorf theorem. Each compartment has a dedicated controller
///         who can distribute tokens according to its purpose.
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

        // Fibonacci-proportioned allocation (Zeckendorf decomposition of 1,618,033,988)
        // 701,408,733 + 433,494,437 + 267,914,296 + 102,334,155 + 63,245,986 + 49,636,381
        // = 1,618,033,988
        _initCompartment(Compartment.LiquidityMining, "Liquidity Mining", 701_408_733e18);
        _initCompartment(Compartment.EcosystemTreasury, "Ecosystem Treasury", 433_494_437e18);
        _initCompartment(Compartment.StakingRewards, "Staking Rewards", 267_914_296e18);
        _initCompartment(Compartment.TeamVesting, "Team Vesting", 102_334_155e18);
        _initCompartment(Compartment.CommunityGrants, "Community Grants", 63_245_986e18);
        _initCompartment(Compartment.InsuranceFund, "Insurance Fund", 49_636_381e18);
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
