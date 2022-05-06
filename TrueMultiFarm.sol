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
        // total amount of a particular token staked
        uint256 totalStaked;
        // who staked how much
        mapping(address => uint256) staked;
    }

    struct Rewards {
        // track overall cumulative rewards
        uint256 cumulativeRewardPerToken;
        // track total rewards
        uint256 totalClaimedRewards;
        uint256 totalRewards;
        // track previous cumulate rewards for accounts
        mapping(address => uint256) previousCumulatedRewardPerToken;
        // track claimable rewards for accounts
        mapping(address => uint256) claimableReward;
    }

    struct RewardDistribution {
        ITrueDistributor distributor;
        Stakes shares;
        Rewards farmRewards;
    }

    mapping(IERC20 => Stakes) public stakes;

    IERC20[] public rewardTokens;
    mapping(IERC20 => RewardDistribution) _rewardDistributions;

    mapping(IERC20 => IERC20[]) public rewardsAvailable;
    // rewardToken -> stakingToken -> Rewards
    mapping(IERC20 => mapping(IERC20 => Rewards)) public stakerRewards;

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

    /**
     * @dev Stake tokens for TRU rewards.
     * Also claims any existing rewards.
     * @param amount Amount of tokens to stake
     */
    function stake(IERC20 token, uint256 amount) external override update(token) {
        stakes[token].staked[msg.sender] = stakes[token].staked[msg.sender] + amount;
        stakes[token].totalStaked = stakes[token].totalStaked + amount;
        _claim(token);

        token.safeTransferFrom(msg.sender, address(this), amount);
        emit Stake(token, msg.sender, amount);
    }

    /**
     * @dev Remove staked tokens
     * @param amount Amount of tokens to unstake
     */
    function unstake(IERC20 token, uint256 amount) external override update(token) {
        _unstake(token, amount);
    }

    /**
     * @dev Claim TRU rewards
     */
    function claim(IERC20[] calldata tokens) external override {
        uint256 tokensLength = tokens.length;

        distribute();
        for (uint256 i = 0; i < tokensLength; i++) {
            updateRewards(tokens[i]);
        }
        for (uint256 i = 0; i < tokensLength; i++) {
            _claim(tokens[i]);
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
            _claim(tokens[i]);
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
            _updateClaimableRewardsForFarm(rewardToken, stakedTokens[i]);
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
        stakes[token].staked[msg.sender] -= (amount);
        stakes[token].totalStaked -= (amount);

        token.safeTransfer(msg.sender, amount);
        emit Unstake(token, msg.sender, amount);
    }

    /**
     * @dev Internal claim function
     */
    function _claim(IERC20 token) internal {
        for (uint256 i = 0; i < rewardsAvailable[token].length; i++) {
            IERC20 rewardToken = rewardsAvailable[token][i];
            uint256 rewardToClaim = stakerRewards[rewardToken][token].claimableReward[msg.sender];
            if (rewardToClaim == 0) {
                continue;
            }

            stakerRewards[rewardToken][token].totalClaimedRewards += rewardToClaim;
            stakerRewards[rewardToken][token].claimableReward[msg.sender] = 0;

            Rewards storage farmRewards = _rewardDistributions[rewardToken].farmRewards;
            farmRewards.totalClaimedRewards += rewardToClaim;
            farmRewards.claimableReward[address(token)] -= rewardToClaim;

            rewardToken.safeTransfer(msg.sender, rewardToClaim);
            emit Claim(token, msg.sender, rewardToClaim);
        }
    }

    function claimable(
        IERC20 rewardToken,
        IERC20 stakedToken,
        address account
    ) external view returns (uint256) {
        return _claimable(rewardToken, stakedToken, account);
    }

    /**
     * @dev View to estimate the claimable reward for an account that is staking token
     * @return claimable rewards for account
     */
    function _claimable(
        IERC20 rewardToken,
        IERC20 stakedToken,
        address account
    ) internal view returns (uint256) {
        Rewards storage _stakerRewards = stakerRewards[rewardToken][stakedToken];

        if (stakes[stakedToken].staked[account] == 0) {
            return _stakerRewards.claimableReward[account];
        }
        // estimate pending reward from distributor
        uint256 pending = _pendingDistribution(rewardToken, stakedToken);
        // calculate total rewards (including pending)
        uint256 newTotalRewards = (pending + _stakerRewards.totalClaimedRewards) * PRECISION;
        // calculate block reward
        uint256 totalBlockReward = newTotalRewards - _stakerRewards.totalRewards;
        // calculate next cumulative reward per stakedToken
        uint256 nextcumulativeRewardPerToken = _stakerRewards.cumulativeRewardPerToken +
            (totalBlockReward / stakes[stakedToken].totalStaked);
        return
            _stakerRewards.claimableReward[account] +
            ((nextcumulativeRewardPerToken - _stakerRewards.previousCumulatedRewardPerToken[account]) *
                stakes[stakedToken].staked[account]) /
            PRECISION;
    }

    function _pendingDistribution(IERC20 rewardToken, IERC20 stakedToken) internal view returns (uint256) {
        Stakes storage shares = _rewardDistributions[rewardToken].shares;
        Rewards storage farmRewards = _rewardDistributions[rewardToken].farmRewards;
        ITrueDistributor distributor = _rewardDistributions[rewardToken].distributor;
        // estimate pending reward from distributor
        uint256 pending = distributor.farm() == address(this) ? distributor.nextDistribution() : 0;

        // calculate new total rewards ever received by farm
        uint256 newTotalRewards = (rewardToken.balanceOf(address(this)) + pending + farmRewards.totalClaimedRewards) * PRECISION;
        // calculate new rewards that were received since previous distribution
        uint256 totalBlockReward = newTotalRewards - farmRewards.totalRewards;

        uint256 cumulativeRewardPerShare = farmRewards.cumulativeRewardPerToken;
        if (shares.totalStaked > 0) {
            cumulativeRewardPerShare += totalBlockReward / shares.totalStaked;
        }

        uint256 newReward = (shares.staked[address(stakedToken)] *
            (cumulativeRewardPerShare - farmRewards.previousCumulatedRewardPerToken[address(stakedToken)])) / PRECISION;

        return farmRewards.claimableReward[address(stakedToken)] + newReward;
    }

    /**
     * @dev Distribute rewards from distributor and increase cumulativeRewardPerShare in Multifarm
     */
    function distribute() internal {
        // TODO optimize to distribute only tokens that matter
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            _distribute(rewardTokens[i]);
        }
    }

    function _distribute(IERC20 rewardToken) internal {
        ITrueDistributor distributor = _rewardDistributions[rewardToken].distributor;
        if (distributor.nextDistribution() > 0 && distributor.farm() == address(this)) {
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
        Rewards storage farmRewards = _rewardDistributions[rewardToken].farmRewards;
        // calculate new total rewards ever received by farm
        uint256 newTotalRewards = (rewardToken.balanceOf(address(this)) + (farmRewards.totalClaimedRewards)) * PRECISION;
        // calculate new rewards that were received since previous distribution
        uint256 rewardSinceLastUpdate = newTotalRewards - farmRewards.totalRewards;
        // update info about total farm rewards
        farmRewards.totalRewards = newTotalRewards;
        // if there are sub farms increase their value per share
        uint256 totalStaked = _rewardDistributions[rewardToken].shares.totalStaked;
        if (totalStaked > 0) {
            farmRewards.cumulativeRewardPerToken += rewardSinceLastUpdate / totalStaked;
        }
    }

    /**
     * @dev Update rewards for the farm on token and for the staker.
     * The function must be called before any modification of staker's stake and to update values when claiming rewards
     */
    function updateRewards(IERC20 stakedToken) internal {
        for (uint256 i = 0; i < rewardsAvailable[stakedToken].length; i++) {
            _updateTokenFarmRewards(rewardsAvailable[stakedToken][i], stakedToken);
            _updateClaimableRewardsForStaker(rewardsAvailable[stakedToken][i], stakedToken);
        }
    }

    /**
     * @dev Update rewards data for the token farm - update all values associated with total available rewards for the farm inside multifarm
     */
    function _updateTokenFarmRewards(IERC20 rewardToken, IERC20 stakedToken) internal {
        _updateClaimableRewardsForFarm(rewardToken, stakedToken);
        _updateTotalRewards(rewardToken, stakedToken);
    }

    /**
     * @dev Increase total claimable rewards for token farm in multifarm.
     * This function must be called before share of the token in multifarm is changed and to update total claimable rewards for the staker
     */
    function _updateClaimableRewardsForFarm(IERC20 rewardToken, IERC20 stakedToken) internal {
        Rewards storage farmRewards = _rewardDistributions[rewardToken].farmRewards;
        uint256 tokenShares = _rewardDistributions[rewardToken].shares.staked[address(stakedToken)];

        if (tokenShares > 0) {
            uint256 newReward = (tokenShares *
                (farmRewards.cumulativeRewardPerToken - farmRewards.previousCumulatedRewardPerToken[address(stakedToken)])) /
                PRECISION;

            farmRewards.claimableReward[address(stakedToken)] += newReward;
        }
        farmRewards.previousCumulatedRewardPerToken[address(stakedToken)] = farmRewards.cumulativeRewardPerToken;
    }

    /**
     * @dev Update total reward for the farm
     * Get total farm reward as claimable rewards for the given farm plus total rewards claimed by stakers in the farm
     */
    function _updateTotalRewards(IERC20 rewardToken, IERC20 stakedToken) internal {
        Rewards storage farmRewards = _rewardDistributions[rewardToken].farmRewards;
        Rewards storage _stakerRewards = stakerRewards[rewardToken][stakedToken];

        uint256 totalRewards = (farmRewards.claimableReward[address(stakedToken)] + _stakerRewards.totalClaimedRewards) * PRECISION;
        // calculate received reward
        uint256 rewardReceivedSinceLastUpdate = totalRewards - _stakerRewards.totalRewards;

        // if there are stakers of the stakedToken, increase cumulativeRewardPerToken by newly received reward per total staked amount
        if (stakes[stakedToken].totalStaked > 0) {
            _stakerRewards.cumulativeRewardPerToken += rewardReceivedSinceLastUpdate / stakes[stakedToken].totalStaked;
        }

        // update farm rewards
        _stakerRewards.totalRewards = totalRewards;
    }

    /**
     * @dev Update claimable rewards for the msg.sender who is staking this token
     * Increase claimable reward by the number that is
     * staker's stake times the change of cumulativeRewardPerToken for the given token since this function was previously called
     * This method must be called before any change of staker's stake
     */
    function _updateClaimableRewardsForStaker(IERC20 rewardToken, IERC20 stakedToken) internal {
        Rewards storage _stakerRewards = stakerRewards[rewardToken][stakedToken];

        if (stakes[stakedToken].staked[msg.sender] > 0) {
            // increase claimable reward for sender by amount staked by the staker times the growth of cumulativeRewardPerToken since last update
            _stakerRewards.claimableReward[msg.sender] +=
                ((_stakerRewards.cumulativeRewardPerToken - _stakerRewards.previousCumulatedRewardPerToken[msg.sender]) *
                    stakes[stakedToken].staked[msg.sender]) /
                PRECISION;
        }
        // update previous cumulative for sender
        _stakerRewards.previousCumulatedRewardPerToken[msg.sender] = _stakerRewards.cumulativeRewardPerToken;
    }
}
