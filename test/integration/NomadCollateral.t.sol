// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import "@forge-std/Test.sol";
import "@forge-std/console.sol";

import {ChainIds} from "@test/utils/ChainIds.sol";
import {Addresses} from "@proposals/Addresses.sol";
import {TestProposals} from "@proposals/TestProposals.sol";
import {StringUtils} from "@proposals/utils/StringUtils.sol";
import {Well} from "@protocol/Governance/deprecated/Well.sol";
import {MErc20Delegator} from "@protocol/MErc20Delegator.sol";
import {CrossChainProposal} from "@proposals/proposalTypes/CrossChainProposal.sol";
import {MoonwellArtemisGovernor, IERC20} from "@protocol/Governance/deprecated/MoonwellArtemisGovernor.sol";
import {mipm16} from "@protocol/proposals/mips/mip-m16/mip-m16.sol";

/// @notice run this on a chainforked moonbeam node.
contract NomadCollateralMoonbeamTest is Test {
    using StringUtils for string;

    TestProposals public proposals;
    Addresses public addresses;
    Well public well;

    /// @dev reserves
    MErc20Delegator mUSDC;
    MErc20Delegator mETH;
    MErc20Delegator mwBTC;
    uint256 mUSDCReserves;
    uint256 mETHReserves;
    uint256 mwBTCReserves;

    address public constant voter = address(1);

    function setUp() public {
        address[] memory mips = new address[](1);
        mips[0] = address(new mipm16());

        addresses = new Addresses();

        mUSDC = MErc20Delegator(payable(addresses.getAddress("MOONWELL_mUSDC")));
        mUSDCReserves = mUSDC.totalReserves();

        mETH = MErc20Delegator(payable(addresses.getAddress("MOONWELL_mETH")));
        mETHReserves = mETH.totalReserves();

        mwBTC = MErc20Delegator(payable(addresses.getAddress("MOONWELL_mwBTC")));
        mwBTCReserves = mwBTC.totalReserves();

        proposals = new TestProposals(mips);
        proposals.setUp();
        proposals.testProposals(true, false, false, false, true, true, false, false);
        addresses = proposals.addresses();
    }

    function testProposalMaxOperations() public {
        MoonwellArtemisGovernor governor = MoonwellArtemisGovernor(addresses.getAddress("ARTEMIS_GOVERNOR"));
        assertEq(governor.proposalMaxOperations(), 1_000);
    }

    function testReduceReservesUSDC() public {
        IERC20 token = IERC20(addresses.getAddress("madUSDC"));
        assertTrue(mUSDC.totalReserves() < mUSDCReserves);
        assertEq(mUSDC.accrueInterest(), 0);
        assertEq(token.balanceOf(addresses.getAddress("MOONBEAM_TIMELOCK")), 0);
        assertEq(token.balanceOf(addresses.getAddress("NOMAD_REALLOCATION_MULTISIG")), mUSDCReserves);
    }

    function testReduceReservesETH() public {
        IERC20 token = IERC20(addresses.getAddress("madWETH"));
        assertTrue(mETH.totalReserves() < mETHReserves);
        assertEq(mETH.accrueInterest(), 0);
        assertEq(token.balanceOf(addresses.getAddress("MOONBEAM_TIMELOCK")), 0);
        assertEq(token.balanceOf(addresses.getAddress("NOMAD_REALLOCATION_MULTISIG")), mETHReserves);
    }

    function testReduceReservesWBTC() public {
        IERC20 token = IERC20(addresses.getAddress("madWBTC"));
        assertTrue(mwBTC.totalReserves() < mwBTCReserves);
        assertEq(mwBTC.accrueInterest(), 0);
        assertEq(token.balanceOf(addresses.getAddress("MOONBEAM_TIMELOCK")), 0);
        assertEq(token.balanceOf(addresses.getAddress("NOMAD_REALLOCATION_MULTISIG")), mwBTCReserves);
    }
}