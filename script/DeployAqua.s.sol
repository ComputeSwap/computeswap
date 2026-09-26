// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.30;

import {Script, console2} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solady/tokens/WETH.sol";
import {Aqua} from "@1inch/aqua/Aqua.sol";
import {IAqua} from "@1inch/aqua/interfaces/IAqua.sol";

import {LogCurve} from "../src/curves/LogCurve.sol";
import {ComputeswapAquaApp} from "../src/aqua/ComputeswapAquaApp.sol";
import {ComputeswapAquaRouter} from "../src/aqua/ComputeswapAquaRouter.sol";
import {AquaWeightVault} from "../src/aqua/AquaWeightVault.sol";
import {WeightAuction} from "../src/weights/WeightAuction.sol";

/// @notice Deploys Computeswap as an Aqua app: the curve, the app, the vault (with its weight token), the auction and
///         the taker router. Writes reports/aqua-deployment.json.
///
///   Settings (environment variables, all optional):
///     AQUA      the Aqua registry. On every chain 1inch supports it is 0x1111113ccf1426a8e30e2bff5e005d929bf6a90a;
///               when unset a fresh registry is deployed (local anvil)
///     WETH      the pair's token0; when unset a WETH is deployed
///     USDC      the pair's token1; when unset a mintable 6-decimal test USDC is deployed and anvil's first four
///               accounts get 1,000,000 each
///     TREASURY  receives the auction's protocol fee (default: the deployer)
///
///   anvil
///   forge script script/DeployAqua.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked \
///     --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
contract DeployAqua is Script {
    address internal constant CANONICAL_AQUA = 0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a;
    uint24 internal constant MAX_ORACLE_DEVIATION = 100; // exercise within 100 ticks (~1%) of the moving average
    string internal constant ANVIL_MNEMONIC = "test test test test test test test test test test test junk";

    function run() external {
        address aquaAddress = vm.envOr("AQUA", address(0));
        address wethAddress = vm.envOr("WETH", address(0));
        address usdcAddress = vm.envOr("USDC", address(0));
        address treasury = vm.envOr("TREASURY", msg.sender);
        uint256 startBlock = block.number;

        vm.startBroadcast();
        if (aquaAddress == address(0)) {
            aquaAddress = CANONICAL_AQUA.code.length != 0 ? CANONICAL_AQUA : address(new Aqua());
        }
        bool usdcMintable;
        if (wethAddress == address(0)) wethAddress = address(new WETH());
        if (usdcAddress == address(0)) {
            MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
            for (uint32 i; i < 4; ++i) {
                usdc.mint(vm.addr(vm.deriveKey(ANVIL_MNEMONIC, i)), 1_000_000e6);
            }
            usdcAddress = address(usdc);
            usdcMintable = true;
        }
        LogCurve curve = new LogCurve();
        ComputeswapAquaApp app = new ComputeswapAquaApp(IAqua(aquaAddress), curve);
        AquaWeightVault vault = new AquaWeightVault(app, MAX_ORACLE_DEVIATION);
        WeightAuction auction = new WeightAuction(vault.weights(), treasury);
        ComputeswapAquaRouter router = new ComputeswapAquaRouter(app, wethAddress);
        vm.stopBroadcast();

        string memory o = "aqua";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeUint(o, "startBlock", startBlock);
        vm.serializeAddress(o, "aqua", aquaAddress);
        vm.serializeAddress(o, "weth", wethAddress);
        vm.serializeAddress(o, "usdc", usdcAddress);
        vm.serializeBool(o, "usdcMintable", usdcMintable);
        vm.serializeAddress(o, "curve", address(curve));
        vm.serializeAddress(o, "app", address(app));
        vm.serializeAddress(o, "vault", address(vault));
        vm.serializeAddress(o, "weights", address(vault.weights()));
        vm.serializeAddress(o, "auction", address(auction));
        string memory json = vm.serializeAddress(o, "router", address(router));
        vm.writeJson(json, "./reports/aqua-deployment.json");

        console2.log("aqua   ", aquaAddress);
        console2.log("app    ", address(app));
        console2.log("vault  ", address(vault));
        console2.log("auction", address(auction));
        console2.log("router ", address(router));
        console2.log("weth   ", wethAddress);
        console2.log("usdc   ", usdcAddress);
        console2.log("wrote reports/aqua-deployment.json");
    }
}
