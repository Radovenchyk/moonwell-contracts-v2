// SPDX-License-Identifier: agpl-3.0
pragma solidity 0.6.12;

import {SafeMath} from "./libraries/SafeMath.sol";
import {DistributionTypes} from "./libraries/DistributionTypes.sol";
import {IDistributionManager} from "./interfaces/IDistributionManager.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/**
 * @title DistributionManager
 * @notice Accounting contract to manage multiple staking distributions
 * @author Moonwell
 **/
contract DistributionManager is IDistributionManager {
    using SafeMath for uint256;

    struct AssetData {
        uint128 emissionPerSecond;
        uint128 lastUpdateTimestamp;
        uint256 index;
        mapping(address => uint256) users;
    }

    uint256 public DISTRIBUTION_END;

    address public EMISSION_MANAGER;

    uint8 public constant PRECISION = 18;

    mapping(address => AssetData) public assets;

    event AssetConfigUpdated(address indexed asset, uint256 emission);
    event AssetIndexUpdated(address indexed asset, uint256 index);
    event UserIndexUpdated(
        address indexed user,
        address indexed asset,
        uint256 index
    );

    function __DistributionManager_init_unchained(
        address emissionManager,
        uint256 distributionDuration
    ) internal {
        require(emissionManager != address(0), "ZERO_ADDRESS");
        DISTRIBUTION_END = block.timestamp.add(distributionDuration);
        EMISSION_MANAGER = emissionManager;
    }

    /**
     * @dev Configures the distribution of rewards for an asset. This method is useful because it automatically
     *      computes the amount of the asset that is staked.
     **/
    function configureAsset(
        uint128 emissionsPerSecond,
        IERC20 underlyingAsset
    ) external override {
        require(msg.sender == EMISSION_MANAGER, "ONLY_EMISSION_MANAGER");

        // Grab the balance of the underlying asset.
        uint256 totalStaked = underlyingAsset.balanceOf(address(this));

        // Pass data through to the configure assets function.
        _configureAssetInternal(
            emissionsPerSecond,
            totalStaked,
            address(underlyingAsset)
        );
    }

    /**
     * @dev Configures the distribution of rewards for a list of assets
     **/
    function configureAssets(
        uint128[] memory emissionPerSecond,
        uint256[] memory totalStaked,
        address[] memory underlyingAsset
    ) external override {
        require(msg.sender == EMISSION_MANAGER, "ONLY_EMISSION_MANAGER");
        require(
            emissionPerSecond.length == totalStaked.length &&
                totalStaked.length == underlyingAsset.length,
            "PARAM_LENGTHS"
        );

        for (uint256 i = 0; i < emissionPerSecond.length; ++i) {
            _configureAssetInternal(
                emissionPerSecond[i],
                totalStaked[i],
                underlyingAsset[i]
            );
        }
    }

    function _configureAssetInternal(
        uint128 emissionsPerSecond,
        uint256 totalStaked,
        address underlyingAsset
    ) internal {
        AssetData storage assetConfig = assets[underlyingAsset];

        _updateAssetStateInternal(underlyingAsset, assetConfig, totalStaked);

        assetConfig.emissionPerSecond = emissionsPerSecond;

        emit AssetConfigUpdated(underlyingAsset, emissionsPerSecond);
    }

    /**
     * @dev Updates the state of one distribution, mainly rewards index and timestamp
     * @param underlyingAsset The address used as key in the distribution, for example stkMFAM or the mTokens addresses on Moonwell
     * @param assetConfig Storage pointer to the distribution's config
     * @param totalStaked Current total of staked assets for this distribution
     * @return The new distribution index
     **/
    function _updateAssetStateInternal(
        address underlyingAsset,
        AssetData storage assetConfig,
        uint256 totalStaked
    ) internal returns (uint256) {
        uint256 oldIndex = assetConfig.index;
        uint128 lastUpdateTimestamp = assetConfig.lastUpdateTimestamp;

        if (block.timestamp == lastUpdateTimestamp) {
            return oldIndex;
        }

        uint256 newIndex = _getAssetIndex(
            oldIndex,
            assetConfig.emissionPerSecond,
            lastUpdateTimestamp,
            totalStaked
        );

        if (newIndex != oldIndex) {
            assetConfig.index = newIndex;
            emit AssetIndexUpdated(underlyingAsset, newIndex);
        }

        assetConfig.lastUpdateTimestamp = uint128(block.timestamp);

        return newIndex;
    }

    /**
     * @dev Updates the state of an user in a distribution
     * @param user The user's address
     * @param asset The address of the reference asset of the distribution
     * @param stakedByUser Amount of tokens staked by the user in the distribution at the moment
     * @param totalStaked Total tokens staked in the distribution
     * @return The accrued rewards for the user until the moment
     **/
    function _updateUserAssetInternal(
        address user,
        address asset,
        uint256 stakedByUser,
        uint256 totalStaked
    ) internal returns (uint256) {
        AssetData storage assetData = assets[asset];
        uint256 userIndex = assetData.users[user];
        uint256 accruedRewards = 0;

        uint256 newIndex = _updateAssetStateInternal(
            asset,
            assetData,
            totalStaked
        );

        if (userIndex != newIndex) {
            if (stakedByUser != 0) {
                accruedRewards = _getRewards(stakedByUser, newIndex, userIndex);
            }

            assetData.users[user] = newIndex;
            emit UserIndexUpdated(user, asset, newIndex);
        }

        return accruedRewards;
    }

    /**
     * @dev Used by "frontend" stake contracts to update the data of an user when claiming rewards from there
     * @param user The address of the user
     * @param stakes List of structs of the user data related with his stake
     * @return The accrued rewards for the user until the moment
     **/
    function _claimRewards(
        address user,
        DistributionTypes.UserStakeInput[] memory stakes
    ) internal returns (uint256) {
        uint256 accruedRewards = 0;

        for (uint256 i = 0; i < stakes.length; ++i) {
            accruedRewards = accruedRewards.add(
                _updateUserAssetInternal(
                    user,
                    stakes[i].underlyingAsset,
                    stakes[i].stakedByUser,
                    stakes[i].totalStaked
                )
            );
        }

        return accruedRewards;
    }

    /**
     * @dev Return the accrued rewards for an user over a list of distribution
     * @param user The address of the user
     * @param stakes List of structs of the user data related with his stake
     * @return The accrued rewards for the user until the moment
     **/
    function _getUnclaimedRewards(
        address user,
        DistributionTypes.UserStakeInput[] memory stakes
    ) internal view returns (uint256) {
        uint256 accruedRewards = 0;

        for (uint256 i = 0; i < stakes.length; ++i) {
            AssetData storage assetConfig = assets[stakes[i].underlyingAsset];
            uint256 assetIndex = _getAssetIndex(
                assetConfig.index,
                assetConfig.emissionPerSecond,
                assetConfig.lastUpdateTimestamp,
                stakes[i].totalStaked
            );

            accruedRewards = accruedRewards.add(
                _getRewards(
                    stakes[i].stakedByUser,
                    assetIndex,
                    assetConfig.users[user]
                )
            );
        }
        return accruedRewards;
    }

    /**
     * @dev Internal function for the calculation of user's rewards on a distribution
     * @param principalUserBalance Amount staked by the user on a distribution
     * @param reserveIndex Current index of the distribution
     * @param userIndex Index stored for the user, representation his staking moment
     * @return The rewards
     **/
    function _getRewards(
        uint256 principalUserBalance,
        uint256 reserveIndex,
        uint256 userIndex
    ) internal pure returns (uint256) {
        return principalUserBalance.mul(reserveIndex.sub(userIndex)).div(1e18);
    }

    /**
     * @dev Calculates the next value of an specific distribution index, with validations
     * @param currentIndex Current index of the distribution
     * @param emissionPerSecond Representing the total rewards distributed per second per asset unit, on the distribution
     * @param lastUpdateTimestamp Last moment this distribution was updated
     * @param totalBalance of tokens considered for the distribution
     * @return The new index.
     **/
    function _getAssetIndex(
        uint256 currentIndex,
        uint256 emissionPerSecond,
        uint128 lastUpdateTimestamp,
        uint256 totalBalance
    ) internal view returns (uint256) {
        if (
            emissionPerSecond == 0 ||
            totalBalance == 0 ||
            lastUpdateTimestamp == block.timestamp ||
            lastUpdateTimestamp >= DISTRIBUTION_END
        ) {
            return currentIndex;
        }

        uint256 currentTimestamp = block.timestamp > DISTRIBUTION_END
            ? DISTRIBUTION_END
            : block.timestamp;
        uint256 timeDelta = currentTimestamp.sub(lastUpdateTimestamp);
        return
            emissionPerSecond.mul(timeDelta).mul(1e18).div(totalBalance).add(
                currentIndex
            );
    }

    /**
     * @dev Returns the data of an user on a distribution
     * @param user Address of the user
     * @param asset The address of the reference asset of the distribution
     * @return The new index
     **/
    function getUserAssetData(
        address user,
        address asset
    ) public view returns (uint256) {
        return assets[asset].users[user];
    }

    /**
     * @dev Changes the emissions manager.
     */
    function setEmissionsManager(address newEmissionsManager) external {
        require(msg.sender == EMISSION_MANAGER, "ONLY_EMISSION_MANAGER");
        EMISSION_MANAGER = newEmissionsManager;
    }
}