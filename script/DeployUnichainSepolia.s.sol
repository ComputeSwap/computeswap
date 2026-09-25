// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

import {DeployBase} from "./DeployBase.s.sol";
import {TestUSDC} from "./TestUSDC.sol";
import {ConcentratedCurveHook} from "../src/ConcentratedCurveHook.sol";
import {WeightVault} from "../src/weights/WeightVault.sol";
import {WeightAuction} from "../src/weights/WeightAuction.sol";

/// @notice Deploys the log-curve hook, its weights stack and the ETH/USDC pool on Unichain Sepolia (chain 1301), using
///         Uniswap's own PoolManager and PoolSwapTest router there, and writes frontend/deployments.json.
///
///   Settings (environment variables, all optional):
///     INIT_PRICE=2500      starting ETH price in USDC (whole dollars)
///     USDC=0x31d0...768F   use this USDC instead of deploying a mintable test token (e.g. Circle's testnet USDC)
///     APP_RPC=https://...  the RPC the web app reads through (default: the public, rate-limited sepolia.unichain.org)
///
///   forge script script/DeployUnichainSepolia.s.sol --rpc-url https://sepolia.unichain.org --account deployer --broadcast
///
///   See docs/DEPLOY_UNICHAIN.md for the whole procedure.
contract DeployUnichainSepolia is DeployBase {
    uint256 internal constant CHAIN_ID = 1301;
    /// @dev Uniswap v4 on Unichain Sepolia (docs.uniswap.org/contracts/v4/deployments)
    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
    address internal constant POOL_SWAP_TEST = 0x9140a78c1A137c7fF1c151EC8231272aF78a99A4;

    function run() external {
        require(block.chainid == CHAIN_ID, "not Unichain Sepolia (1301)");
        require(address(POOL_MANAGER).code.length != 0, "no PoolManager at the expected address");
        uint256 initPrice = vm.envOr("INIT_PRICE", uint256(2500));
        address usdcEnv = vm.envOr("USDC", address(0));
        uint256 startBlock = block.number;

        vm.startBroadcast();
        address usdc = usdcEnv == address(0) ? address(new TestUSDC()) : usdcEnv;
        (ConcentratedCurveHook hook, WeightVault vault, WeightAuction auction) = deployStack(POOL_MANAGER);
        // create the pool right away, on the hook's curve, with v4's own price kept in sync
        PoolKey memory key =
            PoolKey(CurrencyLibrary.ADDRESS_ZERO, Currency.wrap(usdc), FEE, TICK_SPACING, IHooks(address(hook)));
        hook.initializePool(key, sqrtPriceX96ForUsd(initPrice), true);
        vm.stopBroadcast();

        console2.log("pool created at ETH = $", initPrice);
        writeDeployments(
            Deployment({
                poolManager: address(POOL_MANAGER),
                router: POOL_SWAP_TEST,
                usdc: usdc,
                usdcMintable: usdcEnv == address(0),
                curve: address(hook.curve()),
                hook: address(hook),
                vault: address(vault),
                weights: address(vault.weights()),
                auction: address(auction),
                startBlock: startBlock
            }),
            vm.envOr("APP_RPC", string("https://sepolia.unichain.org")),
            "Unichain Sepolia",
            "https://sepolia.uniscan.xyz"
        );
    }
}
