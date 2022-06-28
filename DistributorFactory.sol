pragma solidity ^0.8.10;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ITrueDistributor} from "./interfaces/ITrueDistributor.sol";

contract DistributorFactory {
    event DistributorCreated(ITrueDistributor distributor);

    address public implementation;

    constructor(address _implementation) {
        implementation = _implementation;
    }

    function create(
        uint256 _distributionStart,
        uint256 _duration,
        uint256 _amount,
        IERC20 _rewardToken
    ) external {
        ITrueDistributor deployed = ITrueDistributor(Clones.clone(implementation));
        deployed.initialize(_distributionStart, _duration, _amount, _rewardToken);

        emit DistributorCreated(deployed);
    }
}
