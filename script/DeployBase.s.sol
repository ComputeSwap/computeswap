// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {ConcentratedCurveHook} from "../src/ConcentratedCurveHook.sol";
import {ICurve} from "../src/interfaces/ICurve.sol";
import {LogCurve} from "../src/curves/LogCurve.sol";
import {WeightVault} from "../src/weights/WeightVault.sol";
import {WeightAuction} from "../src/weights/WeightAuction.sol";

/// @notice What every deployment shares: the curve, the hook at an address that carries its permission flags, the
///         weights stack, and the frontend/deployments.json the app reads.
abstract contract DeployBase is Script {
    /// @dev the deterministic CREATE2 deployer that forge routes `new X{salt: ...}` through (present on every OP chain)
    address internal constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    uint160 internal constant FLAG_MASK = (1 << 14) - 1;
    uint160 internal constant FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );
    uint24 internal constant FEE = 3000; // 0.3%
    int24 internal constant TICK_SPACING = 10;
    uint24 internal constant MAX_ORACLE_DEVIATION = 100; // exercise within 100 ticks (~1%) of the moving average

    struct Deployment {
        address poolManager;
        address router;
        address usdc;
        bool usdcMintable;
        address curve;
        address hook;
        address vault;
        address weights;
        address auction;
        uint256 startBlock;
    }

    /// @dev Deploys the curve, the hook bound to it, the vault and the auction (call inside a broadcast)
    function deployStack(IPoolManager manager, address treasury)
        internal
        returns (ConcentratedCurveHook hook, WeightVault vault, WeightAuction auction)
    {
        ICurve curve = new LogCurve();
        // v4 reads a hook's permissions from its address: mine a CREATE2 salt that gives the right low bits
        bytes memory initCode = abi.encodePacked(type(ConcentratedCurveHook).creationCode, abi.encode(manager, curve));
        bytes32 initCodeHash = keccak256(initCode);
        bytes32 salt;
        address predicted;
        for (uint256 i;; ++i) {
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), CREATE2_DEPLOYER, salt, initCodeHash))))
            );
            if (uint160(predicted) & FLAG_MASK == FLAGS && predicted.code.length == 0) break;
        }
        // deploy through the CREATE2 deployer explicitly (forge does not route `new X{salt: ...}` through it on
        // every chain); it takes salt ++ init code and returns the new address
        (bool ok, bytes memory deployed) = CREATE2_DEPLOYER.call(abi.encodePacked(salt, initCode));
        require(ok && deployed.length == 20 && address(bytes20(deployed)) == predicted, "hook deployment");
        hook = ConcentratedCurveHook(predicted);
        vault = new WeightVault(hook, MAX_ORACLE_DEVIATION);
        auction = new WeightAuction(vault.weights(), treasury);
    }

    /// @dev sqrtPriceX96 for a whole-dollar ETH price in a native-ETH (18 decimals) / USDC (6 decimals) pool
    function sqrtPriceX96ForUsd(uint256 usdPerEth) internal pure returns (uint160) {
        // raw price = usd * 1e6 / 1e18 (USDC units per wei); sqrtPriceX96 = sqrt(raw) * 2^96
        return uint160(FixedPointMathLib.sqrt(FullMath.mulDiv(usdPerEth, 1 << 192, 1e12)));
    }

    function writeDeployments(Deployment memory d, string memory rpc, string memory chainName, string memory explorer)
        internal
    {
        string memory o = "deployments";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeString(o, "chainName", chainName);
        vm.serializeString(o, "rpc", rpc);
        vm.serializeString(o, "explorer", explorer);
        vm.serializeUint(o, "startBlock", d.startBlock);
        vm.serializeAddress(o, "poolManager", d.poolManager);
        vm.serializeAddress(o, "router", d.router);
        vm.serializeAddress(o, "usdc", d.usdc);
        vm.serializeBool(o, "usdcMintable", d.usdcMintable);
        vm.serializeAddress(o, "curve", d.curve);
        vm.serializeAddress(o, "hook", d.hook);
        vm.serializeAddress(o, "vault", d.vault);
        vm.serializeAddress(o, "weights", d.weights);
        vm.serializeUint(o, "fee", FEE);
        vm.serializeUint(o, "tickSpacing", uint256(int256(TICK_SPACING)));
        string memory json = vm.serializeAddress(o, "auction", d.auction);
        vm.writeJson(json, "./frontend/deployments.json");
        console2.log("hook   ", d.hook);
        console2.log("vault  ", d.vault);
        console2.log("auction", d.auction);
        console2.log("usdc   ", d.usdc);
        console2.log("wrote frontend/deployments.json");
    }
}
