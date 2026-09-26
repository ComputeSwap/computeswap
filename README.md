# Compute Trading Function 

This is an ETH/USDC Uniswap v4 hook built on your trading function, with concentrated liquidity:

$$x\,e^{y} = 1 \qquad\text{offset for a range } [p_a, p_b]:\qquad (x + p_b^{-1})\,e^{\,y + 1 + \ln p_a} = e$$

A position with liquidity $L$ holds $x = L(1/P - 1/p_b)$ ETH and $y = L\ln(P/p_a)$ USDC. Positions with the same or different ranges add up as in Uniswap v3, and fees are shared pro rata.

An LP can also split a position's **ETH weight** off as a token and sell it in a Dutch auction. Until the token expires (5 days by default), its holder can make the vault withdraw that liquidity at the current price and take the ETH. The LP keeps the USDC and the fees.

More detail:
- [docs/DESIGN.md](docs/DESIGN.md): the math, 50/50 ranges, how liquidity is tracked, the architecture, and the verification results.
- [docs/WEIGHTS.md](docs/WEIGHTS.md): the weights, and why positions are ERC-721 and weights ERC-6909.

## Run the app

You need Foundry ≥ 1.0 (`foundryup`) and Python 3, plus internet access, because the page loads ethers.js from jsdelivr. Run each command below in its own terminal, from this folder:

```bash
anvil
```

```bash
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

```bash
python frontend/serve.py
```

Then open http://127.0.0.1:5173. `serve.py` is a static file server with browser caching turned off, so edits to the page show up on the next reload.

The deploy script also creates the ETH/USDC pool (default start price $1; override with `INIT_PRICE=2500`).

If anvil was already running with an older version of the contracts, restart it and run the deploy command again.

**On a Mac**, see [docs/SETUP_MAC.md](docs/SETUP_MAC.md). **To put it on the Unichain Sepolia testnet**, follow [docs/DEPLOY_UNICHAIN.md](docs/DEPLOY_UNICHAIN.md). There, visitors connect their own browser wallet.

- **Wallet menu:** switches between Alice, Bob, Carol and Dave. Each has 10,000 ETH and 1,000,000 USDC.
- **+1h / +1d / +5d:** move the chain's clock forward.

**Left side:**
- **Add liquidity:** enter an amount and a price range, or tick **50 / 50**. With 50 / 50 on, type either the min or the max price and the other is solved so the deposit is half ETH, half USDC at today's price (for example, at $1 a max of $2 gives a min of $0.6065).
- **Liquidity chart:** shows every position as a band. The part held as USDC is green and the part held as ETH is navy. Click a band to withdraw that position or sell its ETH weight.
- **Sell popup:** after you add liquidity, a popup offers to sell the new position's ETH weight in a Dutch auction.
- **History:** every operation on the pool, read from the chain, with who did it, the ETH and USDC amounts, and the price at the time. It covers creating the pool, adding liquidity, withdrawals, buys and sells, splitting and auctioning ETH weights, buying them, exercising, cancelling and merging.

**Right side:**
- **Swap:** Buy or Sell, in ETH or USDC.
- **Reserve chart:** the pool's curve. While you type an amount, dots show where 25, 50, 75 and 100% of the swap would land.
- **ETH weights:** open auctions, and any weights you hold (Exercise). This section appears only when there is something to show. **Payoff diagram**, next to each weight's buttons, shows what exercising pays at each ETH price. It is a triangle that rises in a straight line from $0 to its peak at that position's pₐ, then falls in a straight line to $0 at p_b. For an auction, the current auction price is drawn as a dashed line.

## Test scenario

This is your scenario: ETH at $1, $100 on [0.25, 4] and $100 on [0.5, 2], then buys and sells. It runs in `test/UserScenario.t.sol`, and the same run was repeated click by click in the app.

These two ranges are not 50/50 at $1: range 1 is 35.10 ETH + 64.90 USDC and range 2 is 41.90 ETH + 58.10 USDC. The 50/50 ranges at $1 are [0.4724, 4] and [0.6065, 2].

| swap (0.3% fee) | trader gets / pays | ETH after |
|---|---|---|
| buy 10 ETH | −10.4350 USDC | $1.082932 |
| sell 25 ETH | +24.5356 USDC | $0.897426 |
| buy with 30 USDC | +29.7871 ETH | $1.128434 |
| sell 5 ETH | +5.5074 USDC | $1.081829 |
| buy 20 ETH | −23.7267 USDC | $1.296686 |
| sell ETH for 15 USDC | −12.2954 ETH | $1.155969 |

Withdrawing everything returns 59.5091 ETH + 142.1179 USDC, leaving 6 wei and 8 USDC units of rounding in the pool's favor. Every swap executed exactly at the chain's quote, and an independent Python model matches every price, amount and fee.

## Layout

```
src/
  ConcentratedCurveHook.sol        the v4 hook: pools, positions, swaps, fees, moving-average oracle
  curves/LogCurve.sol              your curve (ICurve), with libraries/LogCurveMath.sol
  libraries/                       ticks, fee growth and the swap loop (CurvePool, CurveSwapMath, ...)
  weights/                         WeightVault (ERC-721), WeightToken (ERC-6909), WeightAuction
script/DeployLocal.s.sol           local deployment (anvil) for the app
script/DeployUnichainSepolia.s.sol testnet deployment on Uniswap's PoolManager, see docs/DEPLOY_UNICHAIN.md
frontend/                          index.html, app.js, curve.js (math, 50/50 solver), charts.js, chain.js
test/                              43 tests; test/mocks holds an x*y curve used only to check the engine against v4
python/                            high-precision checks and an independent reference model
license-mit/                       the previous MIT license, and how to switch back
```

## Tests

```bash
forge test
```

```bash
forge test --match-contract "UserScenario|WeightsTest" -vv
```

## License

The project is licensed under the **Business Source License 1.1**, in the same form Uniswap uses for v4-core: see [LICENSE](LICENSE).
- Anyone may copy, modify and use it outside production.
- Production use needs your permission until the Change Date (2030-09-22). After that date it becomes MIT.
- Replace `[YOUR NAME OR COMPANY]` in `LICENSE` with the owner's legal name before publishing.

The earlier MIT license is kept in [license-mit/](license-mit/), with a script and instructions to switch back.

The libraries in `lib/` keep their own licenses.

| library | commit | license |
|---|---|---|
| Uniswap/v4-core | `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | MIT libraries used by `src/`; the BUSL `PoolManager` only in tests and the local deployment |
| foundry-rs/forge-std | `1de6eecf821de7fe2c908cc48d3ab3dced20717f` | MIT / Apache-2.0 |
| transmissions11/solmate | `4b47a19038b798b4a33d9749d25e570443520647` | AGPL-3.0, test mocks only |
| Vectorized/solady | `2afba69bf67b78dd4abeadcc696052b3a6f71499` | MIT |

This is a prototype and has **not been audited**.
