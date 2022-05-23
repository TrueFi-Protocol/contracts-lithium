// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {ITrueDistributor} from "./interfaces/ITrueDistributor.sol";
import {ITrueMultiFarm} from "./interfaces/ITrueMultiFarm.sol";

/**
 * @title TrueMultiFarm
 * @notice Deposit liquidity tokens to earn TRU rewards over time
 * @dev Staking pool where tokens are staked for TRU rewards
 * A Distributor contract decides how much TRU all farms in total can earn over time
 * Calling setShare() by owner decides ratio of rewards going to respective token farms
 * You can think of this contract as of a farm that is a distributor to the multiple other farms
 * A share of a farm in the multifarm is it's stake
 */

contract TrueMultiFarm is ITrueMultiFarm, Ownable, Initializable {
    using SafeERC20 for IERC20;

    uint256 private constant PRECISION = 1e30;

    struct Stakes {
        uint256 totalStaked;
        mapping(address => uint256) staked;
    }

    struct FarmRewards {
        uint256 cumulativeRewardPerShare;
        uint256 unclaimedRewards;
        mapping(address => uint256) previousCumulatedRewardPerShare;
    }

    struct StakerRewards {
        uint256 cumulativeRewardPerToken;
        mapping(address => uint256) previousCumulatedRewardPerToken;
    }

    struct RewardDistribution {
        ITrueDistributor distributor;
        Stakes shares;
        FarmRewards farmRewards;
    }

    mapping(IERC20 => Stakes) public stakes;

    IERC20[] public rewardTokens;
    mapping(IERC20 => RewardDistribution) _rewardDistributions;

    mapping(IERC20 => IERC20[]) public rewardsAvailable;
    // rewardToken -> stakingToken -> Rewards
    mapping(IERC20 => mapping(IERC20 => StakerRewards)) public stakerRewards;
    mapping(IERC20 => uint256) public undistributedRewards;
    mapping(IERC20 => uint256) public rescuedFunds;

    /**
     * @dev Emitted when an account stakes
     * @param who Account staking
     * @param amountStaked Amount of tokens staked
     */
    event Stake(IERC20 indexed token, address indexed who, uint256 amountStaked);

    /**
     * @dev Emitted when an account unstakes
     * @param who Account unstaking
     * @param amountUnstaked Amount of tokens unstaked
     */
    event Unstake(IERC20 indexed token, address indexed who, uint256 amountUnstaked);

    /**
     * @dev Emitted when an account claims TRU rewards
     * @param who Account claiming
     * @param amountClaimed Amount of TRU claimed
     */
    event Claim(IERC20 indexed token, address indexed who, uint256 amountClaimed);

    event DistributorAdded(IERC20 indexed rewardToken, ITrueDistributor indexed distributor);

    /**
     * @dev Update all rewards associated with the token and msg.sender
     */
    modifier update(IERC20 token) {
        distribute();
        updateRewards(token);
        _;
    }

    function getDistributor(IERC20 rewardToken) external view returns (ITrueDistributor) {
        return _rewardDistributions[rewardToken].distributor;
    }

    function getRewardTokens() external view returns (IERC20[] memory) {
        return rewardTokens;
    }

    function getShares(IERC20 rewardToken, IERC20 stakedToken) external view returns (uint256) {
        return _rewardDistributions[rewardToken].shares.staked[address(stakedToken)];
    }

    function getTotalShares(IERC20 rewardToken) external view returns (uint256) {
        return _rewardDistributions[rewardToken].shares.totalStaked;
    }

    function getAvailableRewardsForToken(IERC20 stakedToken) external view returns (IERC20[] memory) {
        return rewardsAvailable[stakedToken];
    }

    /**
     * @dev How much is staked by staker on token farm
     */
    function staked(IERC20 token, address staker) external view returns (uint256) {
        return stakes[token].staked[staker];
    }

    function addDistributor(ITrueDistributor distributor) external onlyOwner {
        require(distributor.farm() == address(this), "TrueMultiFarm: Distributor farm is not set");
        IERC20 rewardToken = distributor.trustToken();
        if (address(_rewardDistributions[rewardToken].distributor) == address(0)) {
            rewardTokens.push(rewardToken);
        }
        _rewardDistributions[rewardToken].distributor = distributor;

        emit DistributorAdded(rewardToken, distributor);
    }

    function removeDistributor(IERC20 rewardToken) external onlyOwner {
        _distribute(rewardToken);
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (rewardTokens[i] == rewardToken) {
                rewardTokens[i] = rewardTokens[rewardTokens.length - 1];
                rewardTokens.pop();
                break;
            }
        }

        delete _rewardDistributions[rewardToken].distributor;
    }

    /**
     * @dev Stake tokens for TRU rewards.
     * Also claims any existing rewards.
     * @param amount Amount of tokens to stake
     */
    function stake(IERC20 token, uint256 amount) external override update(token) {
        _claimAll(token);
        stakes[token].staked[msg.sender] += amount;
        stakes[token].totalStaked += amount;

        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Stake(token, msg.sender, amount);
    }

    /**
     * @dev Remove staked tokens
     * @param amount Amount of tokens to unstake
     */
    function unstake(IERC20 token, uint256 amount) external override update(token) {
        _claimAll(token);
        _unstake(token, amount);
    }

    /**
     * @dev Claim all rewards
     */
    function claim(IERC20[] calldata stakedTokens) external override {
        uint256 stakedTokensLength = stakedTokens.length;

        distribute();
        for (uint256 i = 0; i < stakedTokensLength; i++) {
            updateRewards(stakedTokens[i]);
        }
        for (uint256 i = 0; i < stakedTokensLength; i++) {
            _claimAll(stakedTokens[i]);
        }
    }

    /**
     * @dev Claim rewardTokens
     */
    function claim(IERC20[] calldata stakedTokens, IERC20[] calldata rewards) external {
        uint256 stakedTokensLength = stakedTokens.length;
        uint256 rewardTokensLength = rewards.length;

        for (uint256 i = 0; i < rewardTokensLength; i++) {
            _distribute(rewards[i]);
        }
        for (uint256 i = 0; i < stakedTokensLength; i++) {
            updateRewards(stakedTokens[i], rewards);
        }
        for (uint256 i = 0; i < stakedTokensLength; i++) {
            _claim(stakedTokens[i], rewards);
        }
    }

    /**
     * @dev Unstake amount and claim rewards
     */
    function exit(IERC20[] calldata tokens) external override {
        distribute();

        uint256 tokensLength = tokens.length;

        for (uint256 i = 0; i < tokensLength; i++) {
            updateRewards(tokens[i]);
        }
        for (uint256 i = 0; i < tokensLength; i++) {
            _claimAll(tokens[i]);
            _unstake(tokens[i], stakes[tokens[i]].staked[msg.sender]);
        }
    }

    /*
     * What proportional share of rewards get distributed to this token?
     * The denominator is visible in the public `shares()` view.
     */
    function getShare(IERC20 rewardToken, IERC20 stakedToken) external view returns (uint256) {
        return _rewardDistributions[rewardToken].shares.staked[address(stakedToken)];
    }

    /**
     * @dev Set shares for farms
     * Example: setShares([DAI, USDC], [1, 2]) will ensure that 33.(3)% of rewards will go to DAI farm and rest to USDC farm
     * If later setShares([DAI, TUSD], [2, 1]) will be called then shares of DAI will grow to 2, shares of USDC won't change and shares of TUSD will be 1
     * So this will give 40% of rewards going to DAI farm, 40% to USDC and 20% to TUSD
     * @param stakedTokens Token addresses
     * @param updatedShares share of the i-th token in the multifarm
     */
    function setShares(
        IERC20 rewardToken,
        IERC20[] calldata stakedTokens,
        uint256[] calldata updatedShares
    ) external onlyOwner {
        uint256 tokensLength = stakedTokens.length;

        require(tokensLength == updatedShares.length, "TrueMultiFarm: Array lengths mismatch");
        distribute();

        for (uint256 i = 0; i < tokensLength; i++) {
            _updateTokenFarmRewards(rewardToken, stakedTokens[i]);
        }

        Stakes storage shares = _rewardDistributions[rewardToken].shares;

        for (uint256 i = 0; i < tokensLength; i++) {
            uint256 oldStaked = shares.staked[address(stakedTokens[i])];
            shares.staked[address(stakedTokens[i])] = updatedShares[i];
            shares.totalStaked = shares.totalStaked - oldStaked + updatedShares[i];
            if (updatedShares[i] == 0) {
                _removeReward(rewardToken, stakedTokens[i]);
            } else if (oldStaked == 0) {
                rewardsAvailable[stakedTokens[i]].push(rewardToken);
            }
        }
    }

    function _removeReward(IERC20 rewardToken, IERC20 stakedToken) internal {
        IERC20[] storage rewardsAvailableForToken = rewardsAvailable[stakedToken];
        for (uint256 i = 0; i < rewardsAvailableForToken.length; i++) {
            if (rewardsAvailableForToken[i] == rewardToken) {
                rewardsAvailableForToken[i] = rewardsAvailableForToken[rewardsAvailableForToken.length - 1];
                rewardsAvailableForToken.pop();
                return;
            }
        }
    }

    /**
     * @dev Internal unstake function
     * @param amount Amount of tokens to unstake
     */
    function _unstake(IERC20 token, uint256 amount) internal {
        require(amount <= stakes[token].staked[msg.sender], "TrueMultiFarm: Cannot withdraw amount bigger than available balance");
        stakes[token].staked[msg.sender] -= amount;
        stakes[token].totalStaked -= amount;

        token.safeTransfer(msg.sender, amount);
        emit Unstake(token, msg.sender, amount);
    }

    function _claimAll(IERC20 token) internal {
        IERC20[] memory rewards = rewardsAvailable[token];
        _claim(token, rewards);
    }

    function _claim(IERC20 stakedToken, IERC20[] memory rewards) internal {
        uint256 rewardsLength = rewards.length;
        for (uint256 i = 0; i < rewardsLength; i++) {
            IERC20 rewardToken = rewards[i];
            StakerRewards storage _stakerRewards = stakerRewards[rewardToken][stakedToken];

            uint256 rewardToClaim = 0;
            if (stakes[stakedToken].staked[msg.sender] > 0) {
                rewardToClaim = _nextReward(
                    _stakerRewards,
                    _stakerRewards.cumulativeRewardPerToken,
                    stakes[stakedToken].staked[msg.sender],
                    msg.sender
                );
            }
            _stakerRewards.previousCumulatedRewardPerToken[msg.sender] = _stakerRewards.cumulativeRewardPerToken;

            if (rewardToClaim == 0) {
                continue;
            }

            FarmRewards storage farmRewards = _rewardDistributions[rewardToken].farmRewards;
            farmRewards.unclaimedRewards -= rewardToClaim;

            rewardToken.safeTransfer(msg.sender, rewardToClaim);
            emit Claim(stakedToken, msg.sender, rewardToClaim);
        }
    }

    function claimable(
        IERC20 rewardToken,
        IERC20 stakedToken,
        address account
    ) external view returns (uint256) {
        return _claimable(rewardToken, stakedToken, account);
    }

    function rescue(IERC20 rewardToken) external {
        uint256 amount = undistributedRewards[rewardToken];
        if (amount == 0) {
            return;
        }
        undistributedRewards[rewardToken] = 0;
        rescuedFunds[rewardToken] += amount;
        rewardToken.safeTransfer(owner(), amount);
    }

    /**
     * @dev Distribute rewards from distributor and increase cumulativeRewardPerShare in Multifarm
     */
    function distribute() internal {
        uint256 rewardTokensLength = rewardTokens.length;
        // TODO optimize to distribute only tokens that matter
        for (uint256 i = 0; i < rewardTokensLength; i++) {
            _distribute(rewardTokens[i]);
        }
    }

    function _distribute(IERC20 rewardToken) internal {
        ITrueDistributor distributor = _rewardDistributions[rewardToken].distributor;
        if (address(distributor) != address(0) && distributor.nextDistribution() > 0 && distributor.farm() == address(this)) {
            distributor.distribute();
        }
        _updateCumulativeRewardPerShare(rewardToken);
    }

    /**
     * @dev This function must be called before any change of token share in multifarm happens (e.g. before shares.totalStaked changes)
     * This will also update cumulativeRewardPerToken after distribution has happened
     * 1. Get total lifetime rewards as Balance of TRU plus total rewards that have already been claimed
     * 2. See how much reward we got since previous update (R)
     * 3. Increase cumulativeRewardPerToken by R/total shares
     */
    function _updateCumulativeRewardPerShare(IERC20 rewardToken) internal {
        FarmRewards storage farmRewards = _rewardDistributions[rewardToken].farmRewards;
        uint256 newUnclaimedRewards = _rewardBalance(rewardToken);
        uint256 rewardSinceLastUpdate = (newUnclaimedRewards - farmRewards.unclaimedRewards) * PRECISION;

        farmRewards.unclaimedRewards = newUnclaimedRewards;

        // if there are sub farms increase their value per share
        uint256 totalStaked = _rewardDistributions[rewardToken].shares.totalStaked;
        if (totalStaked > 0) {
            farmRewards.cumulativeRewardPerShare += rewardSinceLastUpdate / totalStaked;
        }
    }

    /**
     * @dev Update rewards for the farm on token and for the staker.
     * The function must be called before any modification of staker's stake and to update values when claiming rewards
     */
    function updateRewards(IERC20 stakedToken) internal {
        uint256 rewardLength = rewardsAvailable[stakedToken].length;

        for (uint256 i = 0; i < rewardLength; i++) {
            _updateTokenFarmRewards(rewardsAvailable[stakedToken][i], stakedToken);
        }
    }

    function updateRewards(IERC20 stakedToken, IERC20[] memory rewards) internal {
        uint256 rewardLength = rewards.length;

        for (uint256 i = 0; i < rewardLength; i++) {
            _updateTokenFarmRewards(rewards[i], stakedToken);
        }
    }

    function _rewardBalance(IERC20 rewardToken) internal view returns (uint256) {
        return rewardToken.balanceOf(address(this)) - stakes[rewardToken].totalStaked + rescuedFunds[rewardToken];
    }

    function _updateTokenFarmRewards(IERC20 rewardToken, IERC20 stakedToken) internal {
        RewardDistribution storage distribution = _rewardDistributions[rewardToken];
        FarmRewards storage farmRewards = distribution.farmRewards;
        uint256 totalStaked = stakes[stakedToken].totalStaked;
        uint256 cumulativeRewardPerShareChange = farmRewards.cumulativeRewardPerShare -
            farmRewards.previousCumulatedRewardPerShare[address(stakedToken)];

        if (totalStaked > 0) {
            stakerRewards[rewardToken][stakedToken].cumulativeRewardPerToken +=
                (cumulativeRewardPerShareChange * distribution.shares.staked[address(stakedToken)]) /
                totalStaked;
        } else {
            undistributedRewards[rewardToken] += cumulativeRewardPerShareChange / PRECISION;
        }
        farmRewards.previousCumulatedRewardPerShare[address(stakedToken)] = farmRewards.cumulativeRewardPerShare;
    }

    function _claimable(
        IERC20 rewardToken,
        IERC20 stakedToken,
        address account
    ) internal view returns (uint256) {
        Stakes storage shares = _rewardDistributions[rewardToken].shares;
        FarmRewards storage farmRewards = _rewardDistributions[rewardToken].farmRewards;
        StakerRewards storage _stakerRewards = stakerRewards[rewardToken][stakedToken];
        ITrueDistributor distributor = _rewardDistributions[rewardToken].distributor;

        uint256 stakedAmount = stakes[stakedToken].staked[account];
        if (stakedAmount == 0) {
            return 0;
        }

        uint256 rewardSinceLastUpdate = _rewardSinceLastUpdate(farmRewards, distributor, rewardToken);
        uint256 nextCumulativeRewardPerToken = _nextCumulativeReward(
            farmRewards,
            _stakerRewards,
            shares,
            rewardSinceLastUpdate,
            address(stakedToken)
        );
        return _nextReward(_stakerRewards, nextCumulativeRewardPerToken, stakedAmount, account);
    }

    function _rewardSinceLastUpdate(
        FarmRewards storage farmRewards,
        ITrueDistributor distributor,
        IERC20 rewardToken
    ) internal view returns (uint256) {
        uint256 pending = 0;
        if (address(distributor) != address(0) && distributor.farm() == address(this)) {
            pending = distributor.nextDistribution();
        }

        uint256 newUnclaimedRewards = _rewardBalance(rewardToken) + pending;
        return newUnclaimedRewards - farmRewards.unclaimedRewards;
    }

    function _nextCumulativeReward(
        FarmRewards storage farmRewards,
        StakerRewards storage _stakerRewards,
        Stakes storage shares,
        uint256 rewardSinceLastUpdate,
        address stakedToken
    ) internal view returns (uint256) {
        uint256 cumulativeRewardPerShare = farmRewards.cumulativeRewardPerShare;
        uint256 nextCumulativeRewardPerToken = _stakerRewards.cumulativeRewardPerToken;
        uint256 totalStaked = stakes[IERC20(stakedToken)].totalStaked;
        if (shares.totalStaked > 0) {
            cumulativeRewardPerShare += (rewardSinceLastUpdate * PRECISION) / shares.totalStaked;
        }
        if (totalStaked > 0) {
            nextCumulativeRewardPerToken +=
                (shares.staked[stakedToken] * (cumulativeRewardPerShare - farmRewards.previousCumulatedRewardPerShare[stakedToken])) /
                totalStaked;
        }
        return nextCumulativeRewardPerToken;
    }

    function _nextReward(
        StakerRewards storage _stakerRewards,
        uint256 _cumulativeRewardPerToken,
        uint256 _stake,
        address _account
    ) internal view returns (uint256) {
        return ((_cumulativeRewardPerToken - _stakerRewards.previousCumulatedRewardPerToken[_account]) * _stake) / PRECISION;
    }
}
