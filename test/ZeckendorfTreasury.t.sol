// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../src/PhiCoin.sol";
import "../src/ZeckendorfTreasury.sol";
import "../src/PhiMath.sol";

contract ZeckendorfTreasuryTest is Test {
    PhiCoin public phiCoinImpl;
    PhiCoin public phiCoin;
    ERC1967Proxy public coinProxy;

    ZeckendorfTreasury public treasury;

    address public admin = makeAddr("admin");
    address public alice = makeAddr("alice");
    address public controller = makeAddr("controller");

    uint256 public constant TOTAL_SUPPLY = 1_618_033_988e18;

    function setUp() public {
        // Deploy PhiCoin via proxy
        phiCoinImpl = new PhiCoin();
        bytes memory coinInit = abi.encodeWithSelector(PhiCoin.initialize.selector, admin);
        coinProxy = new ERC1967Proxy(address(phiCoinImpl), coinInit);
        phiCoin = PhiCoin(address(coinProxy));

        // Deploy ZeckendorfTreasury
        treasury = new ZeckendorfTreasury(address(phiCoin));

        // Grant minter role and fund treasury
        vm.startPrank(admin);
        phiCoin.grantRole(phiCoin.MINTER_ROLE(), admin);
        phiCoin.mintTo(address(treasury), TOTAL_SUPPLY);
        vm.stopPrank();
    }

    function test_totalAllocated() public view {
        uint256 total = treasury.totalAllocated();
        assertEq(total, TOTAL_SUPPLY, "Total allocated must equal 1,618,033,988 ARTS");
    }

    function test_distribute() public {
        // Owner is default controller
        uint256 amount = 1000e18;
        uint256 balBefore = phiCoin.balanceOf(alice);

        vm.prank(address(this)); // test contract is the deployer/owner
        treasury.distribute(ZeckendorfTreasury.Compartment.CommunityGrants, alice, amount);

        uint256 balAfter = phiCoin.balanceOf(alice);
        // Account for spiral burn fee on transfer (~0.618% max)
        assertApproxEqRel(balAfter - balBefore, amount, 0.01e18, "alice should receive tokens (minus burn)");

        // Check distributed tracking
        (, , uint256 distributed, ) = treasury.compartments(ZeckendorfTreasury.Compartment.CommunityGrants);
        assertEq(distributed, amount, "distributed should be updated");
    }

    function test_distributeExceedsAllocation_reverts() public {
        // CommunityGrants allocation = 63,245,986e18
        uint256 tooMuch = 63_245_987e18; // 1 token over allocation

        vm.prank(address(this));
        vm.expectRevert("Exceeds allocation");
        treasury.distribute(ZeckendorfTreasury.Compartment.CommunityGrants, alice, tooMuch);
    }

    function test_unauthorizedDistribute_reverts() public {
        vm.prank(alice); // alice is not a controller
        vm.expectRevert("Not controller");
        treasury.distribute(ZeckendorfTreasury.Compartment.CommunityGrants, alice, 100e18);
    }

    function test_changeController() public {
        // Change controller of InsuranceFund to `controller`
        treasury.setController(ZeckendorfTreasury.Compartment.InsuranceFund, controller);

        // Old controller (this) should fail
        vm.prank(address(this));
        vm.expectRevert("Not controller");
        treasury.distribute(ZeckendorfTreasury.Compartment.InsuranceFund, alice, 100e18);

        // New controller should succeed
        vm.prank(controller);
        treasury.distribute(ZeckendorfTreasury.Compartment.InsuranceFund, alice, 100e18);

        assertApproxEqRel(phiCoin.balanceOf(alice), 100e18, 0.01e18, "alice should receive ~100 ARTS (minus burn)");
    }

    function test_remaining() public {
        uint256 communityAllocation = 63_245_986e18;

        // Before any distribution
        uint256 rem = treasury.remaining(ZeckendorfTreasury.Compartment.CommunityGrants);
        assertEq(rem, communityAllocation, "remaining should equal full allocation");

        // After distribution
        uint256 distAmount = 10_000e18;
        vm.prank(address(this));
        treasury.distribute(ZeckendorfTreasury.Compartment.CommunityGrants, alice, distAmount);

        rem = treasury.remaining(ZeckendorfTreasury.Compartment.CommunityGrants);
        assertEq(rem, communityAllocation - distAmount, "remaining should decrease");
    }
}
