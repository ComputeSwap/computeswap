// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ERC6909} from "solady/tokens/ERC6909.sol";
import {LibString} from "solady/utils/LibString.sol";

/// @title WeightToken - ERC-6909 claims on one leg ("weight") of a split LP position
/// @notice Token id = series id. One unit is the right, until the series expires, to make the WeightVault withdraw one
///         unit of the position's liquidity L at the current price and receive that unit's leg: x(P) of currency0
///         (the ETH weight) or y(P) of currency1 (the USDC weight). The other leg goes to the position's owner.
///         Units of a series are fungible and can be sold in part; different series are different ids.
///
///         Expiry needs no transaction: from `expiry` on, balances read as zero and transfers revert, so the tokens
///         are burned in effect, and the vault stops counting their liquidity as locked.
contract WeightToken is ERC6909 {
    using LibString for uint256;

    error OnlyVault();
    error SeriesExpired(uint256 id);

    struct SeriesInfo {
        uint64 expiry;
        uint8 leg; // 0 = currency0 (ETH), 1 = currency1 (USDC)
        uint8 decimals; // decimals of a liquidity unit
        uint256 positionId;
    }

    address public immutable vault;
    mapping(uint256 id => SeriesInfo) public seriesInfo;

    constructor() {
        vault = msg.sender;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert OnlyVault();
        _;
    }

    function createSeries(uint256 id, uint256 positionId, uint64 expiry, uint8 leg, uint8 unitDecimals)
        external
        onlyVault
    {
        seriesInfo[id] = SeriesInfo({expiry: expiry, leg: leg, decimals: unitDecimals, positionId: positionId});
    }

    function mint(address to, uint256 id, uint256 amount) external onlyVault {
        _mint(to, id, amount);
    }

    function burn(address from, uint256 id, uint256 amount) external onlyVault {
        _burn(from, id, amount);
    }

    function expiryOf(uint256 id) public view returns (uint64) {
        return seriesInfo[id].expiry;
    }

    function isExpired(uint256 id) public view returns (bool) {
        return block.timestamp >= seriesInfo[id].expiry;
    }

    /// @notice Balances of an expired series read as zero: the weight has lapsed.
    function balanceOf(address owner, uint256 id) public view override returns (uint256) {
        return isExpired(id) ? 0 : super.balanceOf(owner, id);
    }

    function _beforeTokenTransfer(address from, address to, uint256 id, uint256) internal view override {
        // mints and vault burns happen before expiry (the vault checks); holder-to-holder moves of a lapsed weight fail
        if (from != address(0) && to != address(0) && isExpired(id)) revert SeriesExpired(id);
    }

    function name(uint256 id) public view override returns (string memory) {
        return string.concat(seriesInfo[id].leg == 0 ? "ETH" : "USDC", " weight #", id.toString());
    }

    function symbol(uint256 id) public view override returns (string memory) {
        return string.concat(seriesInfo[id].leg == 0 ? "wETHx" : "wUSDCy", "-", id.toString());
    }

    /// @notice One unit is one unit of liquidity L; for the log curve L is denominated in currency1.
    function decimals(uint256 id) public view override returns (uint8) {
        return seriesInfo[id].decimals;
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }
}
