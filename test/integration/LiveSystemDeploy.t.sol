//SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.19;

import {TransparentUpgradeableProxy, ITransparentUpgradeableProxy} from "@openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {ProxyAdmin} from "@openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {IERC20Metadata as IERC20} from "@openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import "@forge-std/Test.sol";

import {MErc20} from "@protocol/MErc20.sol";
import {MToken} from "@protocol/MToken.sol";
import {ChainIds} from "@utils/ChainIds.sol";
import {Configs} from "@proposals/Configs.sol";
import {AllChainAddresses as Addresses} from "@proposals/Addresses.sol";
import {Comptroller} from "@protocol/Comptroller.sol";
import {Unitroller} from "@protocol/Unitroller.sol";
import {MErc20Delegator} from "@protocol/MErc20Delegator.sol";
import {TemporalGovernor} from "@protocol/governance/TemporalGovernor.sol";
import {MultiRewardDistributor} from "@protocol/rewards/MultiRewardDistributor.sol";
import {MultiRewardDistributorCommon} from "@protocol/rewards/MultiRewardDistributorCommon.sol";
import {PostProposalCheck} from "@test/integration/PostProposalCheck.sol";

import {ExponentialNoError} from "@protocol/ExponentialNoError.sol";

contract LiveSystemDeploy is Test, ExponentialNoError, PostProposalCheck {
    using ChainIds for uint256;

    MultiRewardDistributor mrd;
    Comptroller comptroller;

    address deprecatedMoonwellVelo;

    MToken[] mTokens;

    mapping(MToken => address[] rewardTokens) rewardsConfig;

    function setUp() public override {
        // undo this once PostProposalCheck is refactored
        //super.setUp();
        vm.envUint("PRIMARY_FORK_ID").createForksAndSelect();

        addresses = new Addresses();

        mrd = MultiRewardDistributor(addresses.getAddress("MRD_PROXY"));
        comptroller = Comptroller(addresses.getAddress("UNITROLLER"));

        MToken[] memory markets = comptroller.getAllMarkets();

        for (uint256 i = 0; i < markets.length; i++) {
            mTokens.push(markets[i]);

            MultiRewardDistributorCommon.MarketConfig[] memory configs = mrd
                .getAllMarketConfigs(markets[i]);

            for (uint256 j = 0; j < configs.length; j++) {
                rewardsConfig[markets[i]].push(configs[j].emissionToken);
            }
        }

        assertEq(mTokens.length > 0, true, "No markets found");
    }

    function _mintMToken(
        address mToken,
        uint256 amount
    ) internal returns (bool) {
        if (mToken == deprecatedMoonwellVelo) {
            return false;
        }

        address underlying = MErc20(mToken).underlying();

        if (underlying == addresses.getAddress("WETH")) {
            vm.deal(addresses.getAddress("WETH"), amount);
        }
        deal(underlying, address(this), amount);
        IERC20(underlying).approve(mToken, amount);

        assertEq(
            MErc20Delegator(payable(mToken)).mint(amount),
            0,
            "Mint failed"
        );

        return true;
    }

    function _getMaxSupplyAmount(
        address mToken
    ) private view returns (uint256) {
        uint256 supplyCap = comptroller.supplyCaps(address(mToken));

        uint256 totalCash = MToken(mToken).getCash();
        uint256 totalBorrows = MToken(mToken).totalBorrows();
        uint256 totalReserves = MToken(mToken).totalReserves();

        uint256 totalSupplies = (totalCash + totalBorrows) - totalReserves;

        if (totalSupplies >= supplyCap) {
            return 0;
        }

        return supplyCap - totalSupplies;
    }

    function _calculateSupplyRewards(
        MToken mToken,
        address emissionToken,
        uint256 amount,
        uint256 toWarp
    ) private view returns (uint256 expectedRewards) {
        MultiRewardDistributorCommon.MarketConfig memory marketConfig = mrd
            .getConfigForMarket(mToken, emissionToken);

        uint256 endTime = marketConfig.endTime;

        uint256 timeDelta;
        if (vm.getBlockTimestamp() > endTime) {
            // if endTime is in the past then we need to decrease
            timeDelta = toWarp - (vm.getBlockTimestamp() - endTime);
        } else {
            timeDelta = toWarp;
        }

        expectedRewards =
            (timeDelta * marketConfig.supplyEmissionsPerSec * amount) /
            MErc20(address(mToken)).totalSupply();
    }

    function _calculateBorrowRewards(
        MToken mToken,
        address emissionToken,
        uint256 amount,
        uint256 toWarp
    ) private view returns (uint256 expectedRewards) {
        MultiRewardDistributorCommon.MarketConfig memory config = mrd
            .getConfigForMarket(mToken, emissionToken);

        uint256 endTime = config.endTime;

        uint256 timeDelta;
        if (vm.getBlockTimestamp() > endTime) {
            // if endTime is in the past then we need to decrease
            timeDelta = toWarp - (vm.getBlockTimestamp() - endTime);
        } else {
            timeDelta = toWarp;
        }

        expectedRewards =
            (timeDelta * config.borrowEmissionsPerSec * amount) /
            mToken.totalBorrows();
    }

    function testGuardianCanPauseTemporalGovernor() public {
        TemporalGovernor gov = TemporalGovernor(
            payable(addresses.getAddress("TEMPORAL_GOVERNOR"))
        );

        vm.prank(addresses.getAddress("SECURITY_COUNCIL"));
        gov.togglePause();

        assertTrue(gov.paused());
        assertFalse(gov.guardianPauseAllowed());
        assertEq(gov.lastPauseTime(), block.timestamp);
    }

    function testFuzz_EmissionsAdminCanChangeOwner(
        uint256 mTokenIndex,
        address newOwner
    ) public {
        mTokenIndex = _bound(mTokenIndex, 0, mTokens.length - 1);
        address emissionsAdmin = addresses.getAddress("TEMPORAL_GOVERNOR");
        vm.assume(newOwner != emissionsAdmin);

        vm.startPrank(emissionsAdmin);

        MToken mToken = mTokens[mTokenIndex];

        for (uint256 i = 0; i < rewardsConfig[mToken].length; i++) {
            mrd._updateOwner(mToken, rewardsConfig[mToken][i], newOwner);
        }
        vm.stopPrank();
    }

    function testFuzz_EmissionsAdminCanChangeRewardStream(
        uint256 mTokenIndex,
        address newOwner
    ) public {
        mTokenIndex = _bound(mTokenIndex, 0, mTokens.length - 1);
        address emissionsAdmin = addresses.getAddress("TEMPORAL_GOVERNOR");
        vm.assume(newOwner != emissionsAdmin);

        vm.startPrank(emissionsAdmin);
        MToken mToken = mTokens[mTokenIndex];

        for (uint256 i = 0; i < rewardsConfig[mToken].length; i++) {
            mrd._updateBorrowSpeed(mToken, rewardsConfig[mToken][i], 0.123e18);
        }
        vm.stopPrank();
    }

    function testFuzz_UpdateEmissionConfigEndTimeSuccess(
        uint256 mTokenIndex
    ) public {
        mTokenIndex = _bound(mTokenIndex, 0, mTokens.length - 1);
        MToken mToken = mTokens[mTokenIndex];

        vm.startPrank(addresses.getAddress("TEMPORAL_GOVERNOR"));

        for (uint256 i = 0; i < rewardsConfig[mToken].length; i++) {
            mrd._updateEndTime(
                mToken,
                rewardsConfig[mToken][i],
                block.timestamp + 4 weeks
            );

            MultiRewardDistributorCommon.MarketConfig memory config = mrd
                .getConfigForMarket(mToken, rewardsConfig[mToken][i]);

            assertEq(
                config.endTime,
                block.timestamp + 4 weeks,
                "End time incorrect"
            );
        }
        vm.stopPrank();
    }

    function testFuzz_UpdateEmissionConfigSupplySuccess(
        uint256 mTokenIndex
    ) public {
        mTokenIndex = _bound(mTokenIndex, 0, mTokens.length - 1);

        MToken mToken = mTokens[mTokenIndex];

        for (uint256 i = 0; i < rewardsConfig[mToken].length; i++) {
            vm.prank(addresses.getAddress("TEMPORAL_GOVERNOR"));
            mrd._updateSupplySpeed(
                mToken,
                rewardsConfig[mToken][i],
                1e18 /// pay 1 op per second in rewards
            );

            MultiRewardDistributorCommon.MarketConfig memory config = mrd
                .getConfigForMarket(mToken, rewardsConfig[mToken][i]);

            assertEq(
                config.supplyEmissionsPerSec,
                1e18,
                "Supply emissions incorrect"
            );
        }
    }

    function testFuzz_UpdateEmissionConfigBorrowSuccess(
        uint256 mTokenIndex
    ) public {
        mTokenIndex = _bound(mTokenIndex, 0, mTokens.length - 1);

        MToken mToken = mTokens[mTokenIndex];

        for (uint256 i = 0; i < rewardsConfig[mToken].length; i++) {
            vm.prank(addresses.getAddress("TEMPORAL_GOVERNOR"));
            mrd._updateBorrowSpeed(
                mToken,
                rewardsConfig[mToken][i],
                1e18 /// pay 1 op per second in rewards to borrowers
            );

            MultiRewardDistributorCommon.MarketConfig memory config = mrd
                .getConfigForMarket(mToken, rewardsConfig[mToken][i]);

            assertEq(
                config.borrowEmissionsPerSec,
                1e18,
                "Borrow emissions incorrect"
            );
        }
    }

    function testFuzz_MintMTokenSucceeds(
        uint256 mTokenIndex,
        uint256 mintAmount
    ) public {
        mTokenIndex = _bound(mTokenIndex, 0, mTokens.length - 1);

        MToken mToken = mTokens[mTokenIndex];

        uint256 max = _getMaxSupplyAmount(address(mToken));

        if (max <= 1000e8) {
            return;
        }

        // 1000e8 to 90% of max supply
        mintAmount = _bound(mintAmount, 1000e8, max - (max / 10));

        IERC20 token = IERC20(MErc20(address(mToken)).underlying());

        address sender = address(this);
        uint256 startingTokenBalance = token.balanceOf(address(mToken));

        bool minted = _mintMToken(address(mToken), mintAmount);
        assertEq(minted, true, "Mint failed");

        assertTrue(
            MErc20Delegator(payable(address(mToken))).balanceOf(sender) > 0,
            "mToken balance should be gt 0 after mint"
        ); /// ensure balance is gt 0

        assertEq(
            token.balanceOf(address(mToken)) - startingTokenBalance,
            mintAmount,
            "Underlying balance not updated"
        ); /// ensure underlying balance is sent to mToken
    }

    function testFuzz_BorrowMTokenSucceed(
        uint256 mTokenIndex,
        uint256 mintAmount
    ) public {
        mTokenIndex = _bound(mTokenIndex, 0, mTokens.length - 1);
        MToken mToken = mTokens[mTokenIndex];

        uint256 max = _getMaxSupplyAmount(address(mToken));

        if (max <= 1000e8) {
            return;
        }

        // 1000e8 to 90% of max supply
        mintAmount = _bound(mintAmount, 1000e8, max - (max / 10));

        bool minted = _mintMToken(address(mToken), mintAmount);
        if (!minted) {
            return;
        }

        uint256 expectedCollateralFactor = 0.5e18;
        (, uint256 collateralFactorMantissa) = comptroller.markets(
            address(mToken)
        );

        // check colateral factor
        if (collateralFactorMantissa < expectedCollateralFactor) {
            vm.prank(addresses.getAddress("TEMPORAL_GOVERNOR"));
            comptroller._setCollateralFactor(
                MToken(mToken),
                expectedCollateralFactor
            );
        }

        address sender = address(this);

        uint256 balanceBefore = sender.balance;

        address[] memory _mTokens = new address[](1);
        _mTokens[0] = address(mToken);

        comptroller.enterMarkets(_mTokens);
        assertTrue(
            comptroller.checkMembership(sender, mToken),
            "Membership check failed"
        );

        uint256 borrowAmount = mintAmount / 3;

        assertEq(
            MErc20Delegator(payable(address(mToken))).borrow(borrowAmount),
            0,
            "Borrow failed"
        );

        IERC20 token = IERC20(MErc20(address(mToken)).underlying());

        if (address(token) == addresses.getAddress("WETH")) {
            assertEq(
                sender.balance - balanceBefore,
                borrowAmount,
                "Wrong borrow amount"
            );
        } else {
            assertEq(
                token.balanceOf(sender),
                borrowAmount,
                "Wrong borrow amount"
            );
        }
    }

    function testFuzz_SupplyReceivesRewards(
        uint256 mTokenIndex,
        uint256 supplyAmount,
        uint256 toWarp
    ) public {
        mTokenIndex = _bound(mTokenIndex, 0, mTokens.length - 1);
        MToken mToken = mTokens[mTokenIndex];

        uint256 max = _getMaxSupplyAmount(address(mToken));

        if (max <= 1000e8) {
            return;
        }

        // 1000e8 to 90% of max supply
        supplyAmount = _bound(supplyAmount, 1000e8, max - (max / 10));

        bool minted = _mintMToken(address(mToken), supplyAmount);

        if (!minted) {
            return;
        }

        toWarp = _bound(toWarp, 1_000_000, 4 weeks);

        vm.warp(block.timestamp + toWarp);

        for (uint256 i = 0; i < rewardsConfig[mToken].length; i++) {
            uint256 expectedReward = _calculateSupplyRewards(
                MToken(mToken),
                rewardsConfig[mToken][i],
                mToken.balanceOf(address(this)),
                toWarp
            );

            MultiRewardDistributorCommon.RewardInfo[] memory rewards = mrd
                .getOutstandingRewardsForUser(MToken(mToken), address(this));

            for (uint256 j = 0; j < rewards.length; j++) {
                if (rewards[j].emissionToken != rewardsConfig[mToken][i]) {
                    continue;
                }
                assertApproxEqRel(
                    rewards[j].supplySide,
                    expectedReward,
                    0.1e18,
                    "Supply rewards not correct"
                );
                assertApproxEqRel(
                    rewards[j].totalAmount,
                    expectedReward,
                    0.1e18,
                    "Total rewards not correct"
                );
            }
        }
    }

    function testFuzz_BorrowReceivesRewards(
        uint256 mTokenIndex,
        uint256 supplyAmount,
        uint256 toWarp
    ) public {
        toWarp = _bound(toWarp, 1_000_000, 4 weeks);
        mTokenIndex = _bound(mTokenIndex, 0, mTokens.length - 1);
        MToken mToken = mTokens[mTokenIndex];

        uint256 max = _getMaxSupplyAmount(address(mToken));

        if (max <= 1000e8) {
            return;
        }

        // 1000e8 to 90% of max supply
        supplyAmount = _bound(supplyAmount, 1000e8, max - (max / 10));

        bool minted = _mintMToken(address(mToken), supplyAmount);

        if (!minted) {
            return;
        }

        uint256 expectedCollateralFactor = 0.5e18;
        (, uint256 collateralFactorMantissa) = comptroller.markets(
            address(mToken)
        );

        // check colateral factor
        if (collateralFactorMantissa < expectedCollateralFactor) {
            vm.prank(addresses.getAddress("TEMPORAL_GOVERNOR"));
            comptroller._setCollateralFactor(
                MToken(mToken),
                expectedCollateralFactor
            );
        }

        address sender = address(this);

        {
            address[] memory _mTokens = new address[](1);
            _mTokens[0] = address(mToken);

            comptroller.enterMarkets(_mTokens);
        }

        assertTrue(
            comptroller.checkMembership(sender, MToken(mToken)),
            "Membership check failed"
        );

        uint256 borrowAmount = supplyAmount / 3;

        assertEq(
            comptroller.borrowAllowed(address(mToken), sender, borrowAmount),
            0,
            "Borrow allowed"
        );

        assertEq(
            MErc20Delegator(payable(address(mToken))).borrow(borrowAmount),
            0,
            "Borrow failed"
        );

        vm.warp(vm.getBlockTimestamp() + toWarp);

        for (uint256 i = 0; i < rewardsConfig[mToken].length; i++) {
            uint256 expectedReward = _calculateBorrowRewards(
                MToken(mToken),
                rewardsConfig[mToken][i],
                mToken.borrowBalanceStored(sender),
                toWarp
            );
            MultiRewardDistributorCommon.RewardInfo[] memory rewards = mrd
                .getOutstandingRewardsForUser(MToken(mToken), sender);

            for (uint256 j = 0; j < rewards.length; j++) {
                if (rewards[j].emissionToken != rewardsConfig[mToken][i]) {
                    continue;
                }
                assertApproxEqRel(
                    rewards[j].borrowSide,
                    expectedReward,
                    0.1e18,
                    "Borrow rewards not correct"
                );
            }
        }
    }

    function testFuzz_SupplyBorrowReceiveRewards(
        uint256 mTokenIndex,
        uint256 supplyAmount,
        uint256 toWarp
    ) public {
        toWarp = _bound(toWarp, 1_000_000, 4 weeks);

        mTokenIndex = _bound(mTokenIndex, 0, mTokens.length - 1);
        MToken mToken = mTokens[mTokenIndex];

        uint256 max = _getMaxSupplyAmount(address(mToken));

        if (max <= 1000e8) {
            return;
        }

        // 1000e8 to 90% of max supply
        supplyAmount = _bound(supplyAmount, 1000e8, max - (max / 10));

        bool minted = _mintMToken(address(mToken), supplyAmount);

        if (!minted) {
            return;
        }

        uint256 expectedCollateralFactor = 0.5e18;
        (, uint256 collateralFactorMantissa) = comptroller.markets(
            address(mToken)
        );

        // check colateral factor
        if (collateralFactorMantissa < expectedCollateralFactor) {
            vm.prank(addresses.getAddress("TEMPORAL_GOVERNOR"));
            comptroller._setCollateralFactor(
                MToken(mToken),
                expectedCollateralFactor
            );
        }

        address sender = address(this);

        address[] memory _mTokens = new address[](1);
        _mTokens[0] = address(mToken);

        comptroller.enterMarkets(_mTokens);
        assertTrue(
            comptroller.checkMembership(sender, mToken),
            "Membership check failed"
        );

        {
            uint256 borrowAmount = supplyAmount / 3;

            assertEq(
                MErc20Delegator(payable(address(mToken))).borrow(borrowAmount),
                0,
                "Borrow failed"
            );
        }

        vm.warp(vm.getBlockTimestamp() + toWarp);

        for (uint256 i = 0; i < rewardsConfig[mToken].length; i++) {
            uint256 expectedSupplyReward = _calculateSupplyRewards(
                MToken(mToken),
                rewardsConfig[mToken][i],
                mToken.balanceOf(sender),
                toWarp
            );

            uint256 expectedBorrowReward = _calculateBorrowRewards(
                MToken(mToken),
                rewardsConfig[mToken][i],
                mToken.borrowBalanceStored(sender),
                toWarp
            );

            MultiRewardDistributorCommon.RewardInfo[] memory rewards = mrd
                .getOutstandingRewardsForUser(MToken(mToken), sender);

            for (uint256 j = 0; j < rewards.length; j++) {
                if (rewards[j].emissionToken != rewardsConfig[mToken][i]) {
                    continue;
                }

                assertApproxEqRel(
                    rewards[j].supplySide,
                    expectedSupplyReward,
                    0.1e18,
                    "Supply rewards not correct"
                );

                assertApproxEqRel(
                    rewards[j].borrowSide,
                    expectedBorrowReward,
                    0.1e18,
                    "Borrow rewards not correct"
                );

                assertApproxEqRel(
                    rewards[j].totalAmount,
                    expectedSupplyReward + expectedBorrowReward,
                    0.1e18,
                    "Total rewards not correct"
                );
            }
        }
    }

    function testFuzz_LiquidateAccountReceiveRewards(
        uint256 mTokenIndex,
        uint256 rewardTokenIndex,
        uint256 mintAmount,
        uint256 toWarp
    ) public {
        toWarp = _bound(toWarp, 1_000_000, 4 weeks);

        mTokenIndex = _bound(mTokenIndex, 0, mTokens.length - 1);
        rewardTokenIndex = _bound(
            rewardTokenIndex,
            0,
            rewardsConfig[mTokens[mTokenIndex]].length - 1
        );
        MToken mToken = mTokens[mTokenIndex];

        uint256 max = _getMaxSupplyAmount(address(mToken));

        if (max <= 1000e8) {
            return;
        }

        // 1000e8 to 90% of max supply
        mintAmount = _bound(mintAmount, 1000e8, max - (max / 10));

        bool minted = _mintMToken(address(mToken), mintAmount);

        if (!minted) {
            return;
        }

        uint256 borrowAmount = mintAmount / 3;

        {
            uint256 expectedCollateralFactor = 0.5e18;
            (, uint256 collateralFactorMantissa) = comptroller.markets(
                address(mToken)
            );
            // check colateral factor
            if (collateralFactorMantissa < expectedCollateralFactor) {
                vm.prank(addresses.getAddress("TEMPORAL_GOVERNOR"));
                comptroller._setCollateralFactor(
                    MToken(mToken),
                    expectedCollateralFactor
                );
            }

            address[] memory _mTokens = new address[](1);
            _mTokens[0] = address(mToken);

            comptroller.enterMarkets(_mTokens);

            assertTrue(
                comptroller.checkMembership(address(this), MToken(mToken)),
                "Membership check failed"
            );
        }

        assertEq(
            MErc20Delegator(payable(address(mToken))).borrow(borrowAmount),
            0,
            "Borrow failed"
        );

        vm.warp(vm.getBlockTimestamp() + toWarp);

        address token = MErc20(address(mToken)).underlying();

        uint256 balanceBefore = mToken.balanceOf(address(this));

        uint256 expectedSupplyReward = _calculateSupplyRewards(
            MToken(mToken),
            rewardsConfig[mToken][rewardTokenIndex],
            balanceBefore / 3,
            toWarp
        );

        uint256 expectedBorrowReward = _calculateBorrowRewards(
            MToken(mToken),
            rewardsConfig[mToken][rewardTokenIndex],
            mToken.borrowBalanceStored(address(this)),
            toWarp
        );

        /// borrower is now underwater on loan
        deal(address(mToken), address(this), balanceBefore / 3);

        {
            (uint256 err, uint256 liquidity, uint256 shortfall) = comptroller
                .getHypotheticalAccountLiquidity(
                    address(this),
                    address(mToken),
                    0,
                    0
                );

            assertEq(err, 0, "Error in hypothetical liquidity calculation");
            assertEq(liquidity, 0, "Liquidity not 0");
            assertGt(shortfall, 0, "Shortfall not gt 0");
        }

        uint256 repayAmt = borrowAmount / 2;

        deal(token, address(100_000_000), repayAmt);

        vm.startPrank(address(100_000_000));
        IERC20(token).approve(address(mToken), repayAmt);

        assertEq(
            MErc20Delegator(payable(address(mToken))).liquidateBorrow(
                address(this),
                repayAmt,
                MErc20(address(mToken))
            ),
            0,
            "Liquidation failed"
        );

        vm.stopPrank();

        MultiRewardDistributorCommon.RewardInfo[] memory rewardsPaid = mrd
            .getOutstandingRewardsForUser(MToken(mToken), address(this));

        for (uint256 j = 0; j < rewardsPaid.length; j++) {
            if (
                rewardsPaid[j].emissionToken !=
                rewardsConfig[mToken][rewardTokenIndex]
            ) {
                continue;
            }

            assertApproxEqRel(
                rewardsPaid[j].supplySide,
                expectedSupplyReward,
                0.1e18,
                "Supply rewards not correct"
            );

            assertApproxEqRel(
                rewardsPaid[j].borrowSide,
                expectedBorrowReward,
                0.1e18,
                "Borrow rewards not correct"
            );

            assertApproxEqRel(
                rewardsPaid[j].totalAmount,
                expectedSupplyReward + expectedBorrowReward,
                0.1e18,
                "Total rewards not correct"
            );
        }
    }

    receive() external payable {}
}