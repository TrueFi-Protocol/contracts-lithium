// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {ITrueDistributor} from "../interfaces/ITrueDistributor.sol";

/**
 * @title LinearTrueDistributor
 * @notice Distribute TRU in a linear fashion
 * @dev Distributor contract which uses a linear distribution
 *
 * Contracts are registered to receive distributions. Once registered,
 * a farm contract can claim TRU from the distributor.
 * - Distributions are based on time.
 * - Owner can withdraw funds in case distribution need to be re-allocated
 */
contract LinearTrueDistributor is ITrueDistributor, Ownable, Initializable {
    using SafeERC20 for IERC20;

    // ================ WARNING ==================
    // ===== THIS CONTRACT IS INITIALIZABLE ======
    // === STORAGE VARIABLES ARE DECLARED BELOW ==
    // REMOVAL OR REORDER OF VARIABLES WILL RESULT
    // ========= IN STORAGE CORRUPTION ===========

    IERC20 public override asset;
    uint256 public distributionStart;
    uint256 public duration;
    uint256 public totalAmount;
    uint256 public lastDistribution;
    uint256 public distributed;

    // contract which claim tokens from distributor
    address public override farm;

    // ======= STORAGE DECLARATION END ============

    /**
     * @dev Emitted when the farm address is changed
     * @param newFarm new farm contract
     */
    event FarmChanged(address newFarm);

    /**
     * @dev Emitted when the total distributed amount is changed
     * @param newTotalAmount new totalAmount value
     */
    event TotalAmountChanged(uint256 newTotalAmount);

    /**
     * @dev Emitted when a distribution occurs
     * @param amount Amount of TRU distributed to farm
     */
    event Distributed(uint256 amount);

    /**
     * @dev Emitted when a distribution is restarted after it was over
     */
    event DistributionRestarted(uint256 _distributionStart, uint256 _duration, uint256 _dailyDistribution);

    /**
     * @dev Initialize distributor
     * @param _distributionStart Start time for distribution
     * @param _duration Length of distribution
     * @param _amount Amount to distribute
     * @param _asset TRU address
     */
    function initialize(
        uint256 _distributionStart,
        uint256 _duration,
        uint256 _amount,
        IERC20 _asset
    ) public initializer {
        _transferOwnership(_msgSender());
        distributionStart = _distributionStart;
        lastDistribution = _distributionStart;
        duration = _duration;
        totalAmount = _amount;
        asset = _asset;
    }

    /**
     * @dev Set contract to receive distributions
     * Will distribute to previous contract if farm already exists
     * @param newFarm New farm for distribution
     */
    function setFarm(address newFarm) external onlyOwner {
        require(newFarm != address(0), "LinearTrueDistributor: Farm address can't be the zero address");
        distribute();
        farm = newFarm;
        emit FarmChanged(newFarm);
    }

    /**
     * @dev Distribute tokens to farm in linear fashion based on time
     */
    function distribute() public override {
        // cannot distribute until distribution start
        uint256 amount = nextDistribution();

        if (amount == 0) {
            return;
        }

        // transfer tokens & update state
        lastDistribution = block.timestamp;
        distributed += (amount);
        asset.safeTransfer(farm, amount);

        emit Distributed(amount);
    }

    /**
     * @dev Calculate next distribution amount
     * @return amount of tokens for next distribution
     */
    function nextDistribution() public view override returns (uint256) {
        // return 0 if before distribution or farm is not set
        if (block.timestamp < distributionStart || farm == address(0)) {
            return 0;
        }

        // calculate distribution amount
        uint256 amount = totalAmount - (distributed);
        if (block.timestamp < distributionStart + (duration)) {
            amount = ((block.timestamp - (lastDistribution)) * (totalAmount)) / (duration);
        }
        return amount;
    }

    /**
     * @dev Withdraw funds (for instance if owner decides to create a new distribution)
     * Distributes remaining funds before withdrawing
     * Ends current distribution
     */
    function empty() external override onlyOwner {
        distribute();
        distributed = 0;
        totalAmount = 0;
        asset.safeTransfer(msg.sender, asset.balanceOf(address(this)));
    }

    /**
     * @dev Change amount of tokens distributed daily by changing total distributed amount
     * @param dailyDistribution New daily distribution
     */
    function setDailyDistribution(uint256 dailyDistribution) external onlyOwner {
        distribute();
        uint256 timeLeft = distributionStart + (duration) - (block.timestamp);
        if (timeLeft > duration) {
            timeLeft = duration;
        } else {
            distributionStart = block.timestamp;
            duration = timeLeft;
        }
        totalAmount = (dailyDistribution * (timeLeft)) / (1 days);
        distributed = 0;
        emit TotalAmountChanged(totalAmount);
    }

    /**
     * @dev Restart the distribution that has ended
     */
    function restart(
        uint256 _distributionStart,
        uint256 _duration,
        uint256 _dailyDistribution
    ) external onlyOwner {
        require(
            block.timestamp > distributionStart + (duration),
            "LinearTrueDistributor: Cannot restart distribution before it's over"
        );
        require(_distributionStart > block.timestamp, "LinearTrueDistributor: Cannot restart distribution from the past");

        distribute();

        distributionStart = _distributionStart;
        lastDistribution = _distributionStart;
        duration = _duration;
        totalAmount = (_dailyDistribution * (_duration)) / (1 days);
        distributed = 0;
    }
}
