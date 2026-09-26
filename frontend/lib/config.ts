// The deployment the app talks to: frontend/deployments.json, written by the deploy scripts.
import { ethers } from "ethers";

export const LOCAL_RPC = "http://127.0.0.1:8545";
export const LOCAL_CHAIN_ID = 31337;

export type Deployment = {
  chainId: number;
  chainName?: string;
  rpc?: string;
  explorer?: string;
  hook: string;
  vault: string;
  weights: string;
  auction: string;
  router: string;
  usdc: string;
  poolManager?: string;
  curve?: string;
  fee: number;
  tickSpacing: number;
  startBlock?: number;
  historyStartBlock?: number;
  usdcMintable?: boolean;
};

export type PoolKey = {
  currency0: string;
  currency1: string;
  fee: number;
  tickSpacing: number;
  hooks: string;
};

export function poolKeyOf(dep: Deployment): PoolKey {
  return {
    currency0: ethers.ZeroAddress,
    currency1: dep.usdc,
    fee: Number(dep.fee),
    tickSpacing: Number(dep.tickSpacing),
    hooks: dep.hook,
  };
}

export function poolIdOf(key: PoolKey): string {
  return ethers.keccak256(
    ethers.AbiCoder.defaultAbiCoder().encode(
      ["address", "address", "uint24", "int24", "address"],
      [key.currency0, key.currency1, key.fee, key.tickSpacing, key.hooks],
    ),
  );
}

export const isLocal = (dep: Deployment) =>
  Number(dep.chainId) === LOCAL_CHAIN_ID;
