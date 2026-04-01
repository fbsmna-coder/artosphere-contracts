// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/PhiCertificate.sol";

contract PhiCertificateTest is Test {
    PhiCertificate public cert;

    address public admin = makeAddr("admin");
    address public minter = makeAddr("minter");
    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    function setUp() public {
        vm.prank(admin);
        cert = new PhiCertificate();

        // Authorize minter
        vm.prank(admin);
        cert.setAuthorizedMinter(minter, true);
    }

    function test_mintCertificate() public {
        vm.prank(minter);
        uint256 tokenId = cert.mintCertificate(alice, 0, 100e18);

        assertEq(tokenId, 0);
        assertEq(cert.ownerOf(0), alice);
        assertEq(cert.contributionCount(alice), 1);

        (
            address recipient,
            uint256 actionType,
            uint256 actionValue,
            uint256 timestamp,
            uint256 phiHash,
            uint256 fibonacciRank
        ) = cert.certificates(0);

        assertEq(recipient, alice);
        assertEq(actionType, 0);
        assertEq(actionValue, 100e18);
        assertEq(timestamp, block.timestamp);
        assertGt(phiHash, 0);
        assertEq(fibonacciRank, 1); // F(1) = 1 >= 1
    }

    function test_unauthorizedMint_reverts() public {
        vm.prank(bob);
        vm.expectRevert("Not authorized");
        cert.mintCertificate(alice, 0, 100e18);
    }

    function test_soulbound_transfer_reverts() public {
        vm.prank(minter);
        cert.mintCertificate(alice, 0, 100e18);

        // Try to transfer from alice to bob
        vm.prank(alice);
        vm.expectRevert("Soulbound: non-transferable");
        cert.transferFrom(alice, bob, 0);
    }

    function test_phiHash_deterministic() public {
        // Same inputs at the same timestamp should produce the same hash
        uint256 ts = block.timestamp;

        vm.warp(ts);
        vm.prank(minter);
        uint256 id1 = cert.mintCertificate(alice, 0, 100e18);

        vm.warp(ts);
        vm.prank(minter);
        uint256 id2 = cert.mintCertificate(alice, 0, 100e18);

        (, , , , uint256 hash1,) = cert.certificates(id1);
        (, , , , uint256 hash2,) = cert.certificates(id2);

        // Same user, same actionType, same value, same timestamp => same phiHash
        assertEq(hash1, hash2);
    }

    function test_fibonacciRank() public {
        // Mint multiple certificates and check Fibonacci rank progression
        // F(1)=1, F(2)=1, F(3)=2, F(4)=3, F(5)=5
        // For count=1: rank=1 (F(1)=1>=1)
        // For count=2: rank=3 (F(3)=2>=2)
        // For count=3: rank=4 (F(4)=3>=3)
        // For count=5: rank=5 (F(5)=5>=5)

        vm.startPrank(minter);
        cert.mintCertificate(alice, 0, 1e18); // count=1
        (, , , , , uint256 rank1) = cert.certificates(0);
        assertEq(rank1, 1); // F(1)=1 >= 1

        cert.mintCertificate(alice, 0, 1e18); // count=2
        (, , , , , uint256 rank2) = cert.certificates(1);
        assertEq(rank2, 3); // F(3)=2 >= 2

        cert.mintCertificate(alice, 0, 1e18); // count=3
        (, , , , , uint256 rank3) = cert.certificates(2);
        assertEq(rank3, 4); // F(4)=3 >= 3

        cert.mintCertificate(alice, 0, 1e18); // count=4
        cert.mintCertificate(alice, 0, 1e18); // count=5
        (, , , , , uint256 rank5) = cert.certificates(4);
        assertEq(rank5, 5); // F(5)=5 >= 5
        vm.stopPrank();
    }

    function test_userCertificateCount() public {
        assertEq(cert.getUserCertificateCount(alice), 0);

        vm.startPrank(minter);
        cert.mintCertificate(alice, 0, 1e18);
        assertEq(cert.getUserCertificateCount(alice), 1);

        cert.mintCertificate(alice, 1, 2e18);
        assertEq(cert.getUserCertificateCount(alice), 2);

        cert.mintCertificate(alice, 2, 3e18);
        assertEq(cert.getUserCertificateCount(alice), 3);
        vm.stopPrank();

        // Bob should still be 0
        assertEq(cert.getUserCertificateCount(bob), 0);
    }
}
