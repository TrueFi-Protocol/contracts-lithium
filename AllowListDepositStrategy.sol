// SPDX-License-Identifier: MIT
pragma solidity 0.8.10;

import {IAllowList} from "./interfaces/IAllowList.sol";
import {IBasePortfolio} from "./interfaces/IBasePortfolio.sol";

contract AllowListDepositStrategy {
    IAllowList public immutable allowList;
    uint256 public immutable allowListIndex;

    constructor(IAllowList _allowList, uint256 _allowListIndex) {
        allowList = _allowList;
        allowListIndex = _allowListIndex;
    }

    function deposit(
        IBasePortfolio portfolio,
        uint256 amount,
        bytes32[] calldata merkleProof
    ) public {
        require(
            allowList.verify(allowListIndex, keccak256(abi.encodePacked(msg.sender)), merkleProof),
            "AllowListDepositStrategy: Invalid proof"
        );
        portfolio.deposit(amount, msg.sender);
    }
}
