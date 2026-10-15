# Deployed contracts

Live demos:

| Chain | App | Repository |
|---|---|---|
| Unichain Sepolia (Uniswap v4 hook) | [computeswap.vercel.app](https://computeswap.vercel.app) | this repo |
| Ethereum Sepolia (1inch Aqua app) | [computeswap-aqua.vercel.app](https://computeswap-aqua.vercel.app) | [ComputeSwap/computeswap-aqua](https://github.com/ComputeSwap/computeswap-aqua) |

Deploy procedures: [DEPLOY_UNICHAIN.md](DEPLOY_UNICHAIN.md) (v4 hook), [computeswap-aqua/docs/DEPLOY_SEPOLIA.md](https://github.com/ComputeSwap/computeswap-aqua/blob/main/docs/DEPLOY_SEPOLIA.md) (Aqua).

## Unichain Sepolia (chain ID 1301)

Explorer base URL: [sepolia.uniscan.xyz](https://sepolia.uniscan.xyz) (Blockscout API: [unichain-sepolia.blockscout.com](https://unichain-sepolia.blockscout.com)).

Pool created at deploy block `63535871`. Uniswap v4 `PoolManager`: `0x00B036B58a818B1BC34d502D3fE730Db729e62AC`. Router (`PoolSwapTest`): `0x9140a78c1A137c7fF1c151EC8231272aF78a99A4`.

| Contract | Address | Explorer |
|---|---|---|
| `ConcentratedCurveHook` | `0xD5bb04dee339596Aa1387E24Bab075e157cb6888` | [link](https://sepolia.uniscan.xyz/address/0xD5bb04dee339596Aa1387E24Bab075e157cb6888) |
| `LogCurve` | `0xFb0B07896a087b41D87E1B28416C065C8fe3EeF7` | [link](https://sepolia.uniscan.xyz/address/0xFb0B07896a087b41D87E1B28416C065C8fe3EeF7) |
| `WeightVault` | `0xbb4f58898eb30f617A753EB2866D4a69d098cA34` | [link](https://sepolia.uniscan.xyz/address/0xbb4f58898eb30f617A753EB2866D4a69d098cA34) |
| `WeightToken` | `0x3691B2913289b96ecd6dd36e8308c36B10Be9967` | [link](https://sepolia.uniscan.xyz/address/0x3691B2913289b96ecd6dd36e8308c36B10Be9967) |
| `WeightAuction` | `0x7B6512dC66D29A2ef5ca673a4c966173e6F6dC9A` | [link](https://sepolia.uniscan.xyz/address/0x7B6512dC66D29A2ef5ca673a4c966173e6F6dC9A) |
| `TestUSDC` (mintable) | `0x197899470fF01CFC88f65819b93E2b0eef4aA85f` | [link](https://sepolia.uniscan.xyz/address/0x197899470fF01CFC88f65819b93E2b0eef4aA85f) |

Contract source is published on the explorers linked above (see also [DEPLOY_UNICHAIN.md §5](DEPLOY_UNICHAIN.md#5-publish-the-source-optional-recommended)).

## Ethereum Sepolia — Aqua (chain ID 11155111)

Explorer: [sepolia.etherscan.io](https://sepolia.etherscan.io). Addresses from [computeswap-aqua `frontend/deployments.json`](https://github.com/ComputeSwap/computeswap-aqua/blob/main/frontend/deployments.json) (deploy block `11785665`).

| Contract | Address | Explorer |
|---|---|---|
| Aqua registry | `0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a` | [link](https://sepolia.etherscan.io/address/0x1111113ccf1426a8e30e2bff5e005d929bf6a90a) |
| Aqua app (`app`) | `0xF63175Eded8C55Ba1939356Ad61129fDb3260Ad5` | [link](https://sepolia.etherscan.io/address/0xF63175Eded8C55Ba1939356Ad61129fDb3260Ad5) |
| Weight vault (`vault`) | `0x59aeF356ecDA87C6ED3B62Bb55efd5f63B2186e9` | [link](https://sepolia.etherscan.io/address/0x59aef356ecda87c6ed3b62bb55efd5f63b2186e9) |
| `WeightToken` | `0x0692161cdD1Ef947f2f98d745D1fEE2C53bF6AAd` | [link](https://sepolia.etherscan.io/address/0x0692161cdd1ef947f2f98d745d1fee2c53bf6aad) |
| `WeightAuction` | `0x926C9cf95e4Ab6fB96c2100A6e9F4BDbA341A582` | [link](https://sepolia.etherscan.io/address/0x926c9cf95e4ab6fb96c2100a6e9f4bdba341a582) |
| Circle USDC | `0x1c7D4B196Cb0C7B01d743Fbc6116a902379C7238` | [link](https://sepolia.etherscan.io/address/0x1c7d4b196cb0c7b01d743fbc6116a902379c7238) |
| WETH | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` | [link](https://sepolia.etherscan.io/address/0xfff9976782d46cc05630d1f6ebab18b2324d6b14) |

Verify Aqua deployments with `forge script … --verify` as documented in computeswap-aqua.
