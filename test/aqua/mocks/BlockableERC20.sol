// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

/// @dev A token with a blocklist, like USDC's: transfers to a blocked address revert
contract BlockableERC20 is MockERC20 {
    mapping(address => bool) public blocked;

    constructor(string memory n, string memory s, uint8 d) MockERC20(n, s, d) {}

    function setBlocked(address who, bool isBlocked) external {
        blocked[who] = isBlocked;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        require(!blocked[to], "blocked");
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        require(!blocked[to], "blocked");
        return super.transferFrom(from, to, amount);
    }
}
