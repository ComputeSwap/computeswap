// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC20} from "solady/tokens/ERC20.sol";

/// @title TestUSDC - a 6-decimal test dollar that anyone can mint, for testnets only
/// @notice Circle's testnet USDC faucet gives a few dollars an hour; this token lets testers mint what a demo needs.
contract TestUSDC is ERC20 {
    error MintTooLarge();

    /// @notice Largest amount one mint call can create (100,000 tUSDC)
    uint256 public constant MAX_MINT = 100_000e6;

    function name() public pure override returns (string memory) {
        return "Test USD Coin";
    }

    function symbol() public pure override returns (string memory) {
        return "tUSDC";
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        if (amount > MAX_MINT) revert MintTooLarge();
        _mint(to, amount);
    }
}
