// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {IAqua} from "@1inch/aqua/interfaces/IAqua.sol";
import {IXYCSwapCallback} from "@1inch/aqua-examples/apps/interfaces/IXYCSwapCallback.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {ComputeswapAquaApp} from "./ComputeswapAquaApp.sol";

interface IWETHLike {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title ComputeswapAquaRouter - a taker for ComputeswapAquaApp strategies
/// @notice Aqua apps hand the output to the taker first and expect the input to be pushed to the maker's balance in a
///         callback. This router does that for ordinary wallets: the caller approves it (or sends ETH, which it wraps
///         when the input token is WETH), and it pushes the input inside `xycSwapCallback`. It is the Aqua
///         counterpart of the PoolSwapTest router the front end uses on Uniswap v4.
contract ComputeswapAquaRouter is IXYCSwapCallback {
    error OnlyApp();
    error WrongValue();
    error UnexpectedSender();

    IAqua public immutable AQUA;
    ComputeswapAquaApp public immutable APP;
    address public immutable WETH;

    mapping(address token => bool) private _approvedToAqua;

    constructor(ComputeswapAquaApp app, address weth) {
        APP = app;
        AQUA = app.AQUA();
        WETH = weth;
    }

    /// @dev refunds of unused ETH come back from WETH
    receive() external payable {
        if (msg.sender != WETH) revert UnexpectedSender();
    }

    /// @notice Sells exactly `amountIn`. Send `amountIn` as ETH when the input token is WETH, or approve the router.
    function swapExactIn(
        ComputeswapAquaApp.Strategy calldata strategy,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMin,
        address to
    ) external payable returns (uint256 amountOut) {
        bool prefunded = _wrap(zeroForOne ? strategy.token0 : strategy.token1, amountIn);
        amountOut = APP.swapExactIn(strategy, zeroForOne, amountIn, amountOutMin, to, abi.encode(msg.sender, prefunded));
    }

    /// @notice Buys exactly `amountOut`. Send `amountInMax` as ETH when the input token is WETH (the unused part is
    ///         refunded), or approve the router.
    function swapExactOut(
        ComputeswapAquaApp.Strategy calldata strategy,
        bool zeroForOne,
        uint256 amountOut,
        uint256 amountInMax,
        address to
    ) external payable returns (uint256 amountIn) {
        bool prefunded = _wrap(zeroForOne ? strategy.token0 : strategy.token1, amountInMax);
        amountIn = APP.swapExactOut(strategy, zeroForOne, amountOut, amountInMax, to, abi.encode(msg.sender, prefunded));
        if (prefunded && amountInMax > amountIn) {
            IWETHLike(WETH).withdraw(amountInMax - amountIn);
            SafeTransferLib.safeTransferETH(msg.sender, amountInMax - amountIn);
        }
    }

    /// @inheritdoc IXYCSwapCallback
    function xycSwapCallback(
        address tokenIn,
        address,
        uint256 amountIn,
        uint256,
        address maker,
        address app,
        bytes32 strategyHash,
        bytes calldata takerData
    ) external override {
        if (msg.sender != address(APP) || app != address(APP)) revert OnlyApp();
        (address payer, bool prefunded) = abi.decode(takerData, (address, bool));
        if (!prefunded) SafeTransferLib.safeTransferFrom(tokenIn, payer, address(this), amountIn);
        if (!_approvedToAqua[tokenIn]) {
            _approvedToAqua[tokenIn] = true;
            SafeTransferLib.safeApproveWithRetry(tokenIn, address(AQUA), type(uint256).max);
        }
        // moves the input from this router to the maker's wallet and credits the strategy
        AQUA.push(maker, app, strategyHash, tokenIn, amountIn);
    }

    function _wrap(address tokenIn, uint256 amount) private returns (bool prefunded) {
        if (msg.value == 0) return false;
        if (tokenIn != WETH || msg.value != amount) revert WrongValue();
        IWETHLike(WETH).deposit{value: msg.value}();
        return true;
    }
}
