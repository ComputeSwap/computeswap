# Computeswap as a 1inch Aqua app

Powered by Aqua — © Degensoft Ltd 2025.

[Aqua](https://github.com/1inch/aqua) is 1inch's shared liquidity layer. A liquidity provider (the *maker*) keeps their
tokens in their own wallet, approves the Aqua registry once, and *ships* a *strategy*: an ABI-encoded parameter blob plus
a virtual balance per token. An *app* is the contract that prices swaps against a strategy: it `pull`s the output from
the maker's wallet to the taker and checks that the taker `push`ed the input back. The registry holds no tokens; it only
keeps the four-level map `balances[maker][app][strategyHash][token]`. Strategies are immutable: to change one, the
maker `dock`s it and ships a new one.

This document explains how the log-curve trading function of the Uniswap v4 hook ([DESIGN.md](DESIGN.md)) becomes an Aqua
app, what changes, and how the weights and the Dutch auction ([WEIGHTS.md](WEIGHTS.md)) survive the move even though
Aqua cannot split a maker's tokens.

## 1. The mapping

| Uniswap v4 version | Aqua version |
|---|---|
| A pool holds many positions; the price is one number for all of them; ticks and `liquidityNet` aggregate the ranges that contain it. | **One strategy is one position**: `Strategy {maker, token0, token1, fee, tickLower, tickUpper, liquidity, sqrtPriceX96, salt}`. Each has its own price. The aggregation the tick machinery does on-chain, the 1inch router does off-chain by splitting an order across strategies (Aqua's design: O(n) strategies per fill, specialised instead of homogenised). |
| `CurvePool.swap` walks initialized ticks; each step is `CurveSwapMath.computeSwapStep`. | One `computeSwapStep` across the position's range, with the same `LogCurve`. No ticks, bitmap or fee growth. |
| Liquidity is held as ERC-6909 claims in the PoolManager; reserves per pool. | Balances are Aqua virtual balances, backed by the maker's wallet. |
| Fees are taken on the input and booked as `feeGrowthGlobal += fee / L`. | Fees are taken on the input by the same code and land in the maker's Aqua balance. `fees(strategy)` = balance − principal implied by (L, P). |
| State: `sqrtPriceX96` per pool. | State: `sqrtPriceX96` per strategy, kept by the app (Aqua only sees balances, and once fees have accrued the price is not derivable from them). Initialised lazily from `Strategy.sqrtPriceX96` at the first swap. |
| Swaps are all-or-nothing. | Same: `InsufficientLiquidity(filled, requested)`. |
| The hook's moving-average tick guards the exercise of weights. | The same EMA, per strategy, in the app (`getOracle`). |

The pricing is *bit-identical*: `test/aqua/AquaParity.t.sol` runs the same position on the hook (a v4 pool with one LP)
and as an Aqua strategy, sends the same six swaps to both, and asserts equal inputs, outputs, prices and ticks to the wei.
(Within one word of v4's tick bitmap; across a word boundary v4 splits the swap into two rounded steps and the results
differ by the curve's rounding allowance, about 1e-16 of the amount.)

### Contracts

```
src/aqua/
  ComputeswapAquaApp.sol     the Aqua app (inherits 1inch's AquaApp): strategies, swapExactIn/Out, quotes, price state,
                             oracle, fees. Aqua-Source-1.1 licensed (see section 6).
  AquaWeightVault.sol        positions as ERC-721 with the vault as the Aqua maker; split / exercise / merge / claim
  ComputeswapAquaRouter.sol  a taker for wallets: approve it (or send ETH, it wraps) and it pushes the input in the callback
src/weights/WeightToken.sol, WeightAuction.sol    reused unchanged
lib/aqua, lib/solidity-utils, lib/openzeppelin-contracts   vendored dependencies (see VENDORED.md in each)
script/DeployAqua.s.sol      deploys the stack against a given (or fresh) Aqua registry
test/aqua/                   30 tests: the app, the vault and auction, hook parity, invariants
```

The swap follows Aqua's callback pattern exactly as 1inch's `XYCSwap` example: `safeBalances` (reverts unless the
strategy is live), price the order, `pull` the output to the recipient, call `xycSwapCallback` on the taker, then
`_safeCheckAquaPush` under the per-strategy transient lock. The callback ABI is the one from the Aqua examples, so any
taker written for `XYCSwap` works against Computeswap unchanged.

### Two ways to be a maker

1. **Aqua-native.** An LP ships a strategy from their own wallet: `app.openingAmounts(strategy)` gives the two amounts,
   `aqua.ship(app, abi.encode(strategy), [token0, token1], amounts)` registers it. Nothing moves. Fees arrive in the
   wallet. `dock` ends it. This is the path 1inch's tooling and analytics expect (the `aqua` MCP tool's
   `strategy_overview` reads exactly these balances). **No weights are possible here** — see the next section.
2. **Through the vault.** The LP deposits into `AquaWeightVault.mint`, which ships one strategy per position with the
   vault as maker. Custodial, like the Uniswap version, but the position can be split and its ETH weight auctioned.

Both are served by the same app; a taker does not see the difference.

## 2. Why weights cannot be split on Aqua, and the workaround

A weight is a claim on one leg of a position at exercise time: the holder makes the position withdraw `units` of
liquidity *now* and takes the ETH leg. In the Uniswap version the vault owns the position inside the hook, so the lock is
real: nobody can take the ETH out from under the weight.

On Aqua the maker's tokens are in the maker's wallet and the strategy is only an allowance. The maker can `dock` at any
block, or simply move the tokens away, and Aqua cannot stop them (that is the point of Aqua). An app can `pull` a
maker's balance to anyone, so it *could* pay an exerciser directly — but only while the maker keeps the strategy and
the tokens there. A weight on a plain strategy is therefore unenforceable: **Aqua cannot split a maker's tokens.**

The workaround is the one 1inch's own documentation recommends for pooled inventory: *"A maker does not have to be an
EOA. A contract — a vault that holds pooled inventory — can be the maker and ship several strategies from one
balance."* `AquaWeightVault` is that contract:

- `mint` pulls the position's exact curve amounts from the LP, ships them as a strategy with `maker = vault` and
  `salt = positionId`, and issues the ERC-721. Aqua's `Shipped`/`Pushed` events fire like for any maker.
- Only the vault can dock its strategies (Aqua keys `dock` on `msg.sender`), and the vault refuses while weights are
  live (`LiquidityLocked`). The lock is real again.
- `split`, `merge`, `claim`, expiry and the auction are the same code and semantics as the Uniswap version; the
  `WeightToken` and `WeightAuction` contracts are reused as they are.

### Withdrawing part of an immutable strategy

`exercise` and `decreaseLiquidity` remove `units` of liquidity. Aqua strategies cannot shrink, so the vault does what
Aqua prescribes for any change: **dock, then ship** the remaining liquidity as a new strategy at the current price, with
a fresh salt. Everything the old strategy held beyond the new principal is paid out:

```
balances b0, b1             the strategy's Aqua balances (= the vault's real inventory for this position)
principal p = up(L, P)      what the curve says L holds at the current price P (rounded up)
fees      = max(b - p, 0)   the excess: swap fees plus rounding dust
keep      = up(L - units, P), capped at b - fees      re-shipped as the new strategy
released  = b - fees - keep                           the withdrawn units' principal
```

The exerciser receives `released` of the weight's leg; the NFT owner receives `released` of the other leg plus both
fees, exactly as in the Uniswap version (`test_partialExerciseReships`, `test_otherLegFollowsTheNft`). A position's
current strategy is `vault.strategyOf(positionId)`; after a re-ship the hash changes, which is Aqua's normal lifecycle
(`Docked` then `Shipped`). Routers must re-read it — they re-quote on-chain before every fill anyway.

The vault never holds more or less than the sum of its strategies' virtual balances (`AquaInvariantsTest` checks this
after every operation), so the shared-inventory caveat in 1inch's vault recipe (virtual balances exceeding real
holdings) cannot occur: each position's tokens back exactly that position's strategy.

### What the exercise guard can and cannot do here

Exercise is refused unless the strategy's current tick is within `maxOracleDeviation` (100 ticks, ~1%) of its
moving-average tick, the same rule as the hook. A move made in the same block never enters the average
(`test_flashManipulationBlocked`), so a flash-loan push is useless.

One thing is different from a shared pool. On Aqua every position is its own market with a single LP, so the LP can move
their own price by trading against themselves at no cost (they pay the fee to themselves). In the Uniswap version the
same is true only in a pool where that LP is the only liquidity. What makes a sustained manipulation expensive in both
cases is arbitrage: a strategy quoting ETH 20% above market is sold into by anyone routing through Aqua, and the LP
pays that difference on every round while waiting for the average to follow. Keep the exercise oracle in mind when
buying a weight on a thinly-arbitraged pair; `_checkOracle` is a single function to swap for a Chainlink feed or a
reference pool if that is preferred. An off-market *opening* price is likewise arbitraged at the LP's expense, so
`MintParams.sqrtPriceX96` should be the market price (the 1inch Spot Price API is the natural source for a UI).

## 3. Numbers

The README scenario's range 2 ($100 on [0.5, 2] at ETH = $1) as a strategy: shipped as 41.90 ETH + 58.10 USDC; selling
1 ETH into it pays 0.9911 USDC (`test_swapExactIn_closedForm`, checked against $L\ln(1 + P\,\Delta x(1-f)/L)$); the ETH
weight sold in a 15-minute Dutch auction, ETH pushed to ~$0.80, exercise refused in the same block and allowed an hour
later, paying $L(1/P - 1/p_b)$ of ETH to the buyer and the USDC leg plus fees to the LP (`test_splitAuctionExercise`).

Gas in the test environment (`--match-test test_gasProfile -vv`):

| operation | gas |
|---|---|
| `swapExactIn` through the router, warm | 76k |
| `swapExactOut` through the router, warm | 129k |
| `mint` (ship a position) | 325k |
| `split` | 153k |
| `exercise` part of a position (dock + ship) | 181k |
| `exercise` the rest (dock only) | 77k |
| collect fees (dock + ship) | 187k |

For comparison the hook swap is 185k (210k with price mirroring) and its exercise 242k. The dock + ship on every
withdrawal is what Aqua's immutability costs; a swap is cheaper because there are no ticks to walk and no PoolManager
round trip.

## 4. Running it

Tests (Foundry downloads solc 0.8.26 for the Uniswap side and 0.8.30 for the Aqua side; `foundry.toml` no longer pins a
version because Uniswap's `PoolManager` pins `0.8.26` and 1inch's `AquaApp` needs `^0.8.30`):

```bash
forge test
```

```bash
forge test --match-path "test/aqua/*" -vv
```

`AquaParityTest` deploys the v4 side from its build artifact, so on a fresh checkout run `forge build` (or the whole
`forge test`) before filtering to it.

Local deployment with a fresh Aqua registry, a WETH and a mintable test USDC:

```bash
anvil
```

```bash
forge script script/DeployAqua.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

On a chain 1inch supports, set `AQUA=0x1111113ccf1426a8e30e2bff5e005d929bf6a90a` (the canonical registry, same address
everywhere), `WETH` and `USDC`. The script writes `reports/aqua-deployment.json`.

Taker flow for a contract: implement `xycSwapCallback` (push the input with `aqua.push(maker, app, strategyHash,
tokenIn, amountIn)`) and call `app.swapExactIn(strategy, zeroForOne, amountIn, amountOutMin, to, takerData)`. For a
wallet: approve `ComputeswapAquaRouter` (or send ETH when the input is WETH) and call its `swapExactIn` /
`swapExactOut`. Quotes: `app.quoteExactIn` / `quoteExactOut`; a strategy's price: `app.currentSqrtPrice`.

The 1inch MCP server (`claude mcp add --transport http 1inch-business https://api.1inch.com/mcp/protocol`) exposes the
Aqua analytics without a key: `strategy_overview`, `strategy_activity` and `list_opened` read the same
`(maker, app, strategyHash)` this app uses, once the app is deployed on a supported chain.

## 5. What is not done

- **The front end** still drives the Uniswap hook. Porting it is a redesign rather than a rewiring: there is no single
  pool price, every position (strategy) has its own curve and price, and the swap form has to pick a strategy (or
  split across several, which is the router's job). The contracts expose everything a UI needs
  (`vault.strategyOf`, `app.currentSqrtPrice`, `app.quoteExactIn`, `vault.positionAmounts`, `vault.previewExercise`).
- **Native ETH.** Aqua settles ERC-20 only, so the pair is WETH/USDC. The router wraps ETH for takers; the vault takes
  and pays WETH.
- **Partial fills.** Like the hook, an order the range cannot fill reverts. Routers size orders with the quote.
- **Taker gating.** Strategies created through the 1inch dApp carry a KycNFT check; this app has none. Whether 1inch
  routes to it is 1inch's decision (see their "Becoming a resolver" documentation).
- Not audited.

## 6. Licensing

`lib/aqua` is 1inch's code under the Degensoft Aqua Source License 1.1 (`lib/aqua/LICENSES/Aqua-Source-1.1.txt`).
`ComputeswapAquaApp` inherits their `AquaApp` base contract, which that license treats as a modification/extension
(§3): the file carries the Aqua license identifier, the attribution above, and its change date. The rest of the
project (including the vault, router and tests, which only call Aqua through its interface) stays BUSL-1.1 (§3.3:
independent code that calls or interfaces with the Licensed Work). Commercial triggers (§5: more than US$100k of fees
in a rolling year or US$10M under control) need a commercial license from Degensoft; the same section currently waives
enforcement for routing/aggregation/market-making volume. Review this before production use.
