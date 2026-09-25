// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";

import {DeployBase} from "./DeployBase.s.sol";
import {ConcentratedCurveHook} from "../src/ConcentratedCurveHook.sol";
import {WeightVault} from "../src/weights/WeightVault.sol";
import {WeightAuction} from "../src/weights/WeightAuction.sol";

/// @notice Deploys the local stack for the front-end on anvil and writes frontend/deployments.json.
///
///   Settings (environment variables, all optional):
///     INIT_PRICE=1   starting ETH price in USDC (whole dollars; default 1 for local tests)
///
///   anvil
///   forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked \
///     --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
contract DeployLocal is DeployBase {
    /// @dev anvil's default mnemonic: its first accounts get test USDC
    string internal constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";

    function run() external {
        uint256 initPrice = vm.envOr("INIT_PRICE", uint256(1));
        uint256 startBlock = block.number;

        vm.startBroadcast();
        PoolManager manager = new PoolManager(msg.sender);
        PoolSwapTest router = new PoolSwapTest(IPoolManager(address(manager)));
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        (ConcentratedCurveHook hook, WeightVault vault, WeightAuction auction) = deployStack(IPoolManager(address(manager)));
        PoolKey memory key =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(address(usdc)), FEE, TICK_SPACING, IHooks(address(hook)));
        hook.initializePool(key, sqrtPriceX96ForUsd(initPrice), true);
        for (uint32 i; i < 4; ++i) {
            usdc.mint(vm.addr(vm.deriveKey(ANVIL_MNEMONIC, i)), 1_000_000e6);
        }
        vm.stopBroadcast();

        console2.log("pool created at ETH = $", initPrice);
        writeDeployments(
            Deployment({
                poolManager: address(manager),
                router: address(router),
                usdc: address(usdc),
                usdcMintable: true,
                curve: address(hook.curve()),
                hook: address(hook),
                vault: address(vault),
                weights: address(vault.weights()),
                auction: address(auction),
                startBlock: startBlock
            }),
            "http://127.0.0.1:8545",
            "Local (anvil)",
            ""
        );
    }
}
