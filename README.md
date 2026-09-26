# Compute Trading Function

This is a Uniswap v4 AMM hook based on the following trading function:

$$xe^{y} = e $$

We can concentrate the liquidity within a range using the following parameters a and b:

$$[p_a, p_b]:\qquad (x + p_b^{-1})\e^{\,y + 1 + \ln p_a} = e$$

A position with liquidity $L$ holds $x = L(1/P - 1/p_b)$ ETH and $y = L\ln(P/p_a)$ USDC.

An LP can also split a position's **ETH weight** as a token and sell it in a Dutch auction. Until the token expires (15 minutes by default in the app), its holder can make the vault withdraw that liquidity at the current price and take the ETH. The LP keeps the USDC and the fees.

Details:
- [docs/DESIGN.md](docs/DESIGN.md): the math, 50/50 ranges with the use of Lambert-W equation.
- [docs/WEIGHTS.md](docs/WEIGHTS.md): the weights, and why positions are ERC-721 and weights ERC-6909.

## Running the app

Foundry ≥ 1.0  is required (`foundryup`) and Node.js ≥ 20. Run each command below in its own terminal, from this folder:

```bash
anvil
```

```bash
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

```bash
cd frontend && npm install && npm run dev
```

Open http://localhost:3000. The page is a Next.js app: its server indexes the pool's events into a database (an embedded one under `frontend/.pglite/` locally, Postgres on Vercel) and serves the activity table and the shared pool state from there, so the browser only talks to the chain for the wallet's own balances and transactions. See [docs/DEPLOY_UNICHAIN.md](docs/DEPLOY_UNICHAIN.md) for hosting it.

The deploy script creates an ETH/USDC pool (default start price $1; override with `INIT_PRICE=2500`).

- **Wallet menu:** switches between Alice, Bob, Carol and Dave in the top right.

**Left side:**
- **Add liquidity:** enter an amount and a price range, or tick **50 / 50**. With 50 / 50 on, type either the min or the max price and the other is solved so the deposit is half ETH, half USDC at today's price (for example, at $1 a max of $2 gives a min of $0.6065).
- **Liquidity chart:** shows every position as a band. The part held as USDC is green and the part held as ETH is navy. Click a band to withdraw that position or sell its ETH weight.
- **Sell popup:** after you add liquidity, a popup offers to sell the new position's ETH weight in a Dutch auction.
- **History:** every operation on the pool, read from the chain, with who did it, the ETH and USDC amounts, and the price at the time. It covers creating the pool, adding liquidity, withdrawals, buys and sells, splitting and auctioning ETH weights, buying them, exercising, cancelling and merging.

**Right side:**
- **Swap:** Buy or Sell, in ETH or USDC.
- **Reserve chart:** the pool's curve. While you type an amount, dots show where 25, 50, 75 and 100% of the swap would land.
- **ETH weights:** open auctions, and any weights you hold. This section appears only when there is something to show. **Payoff diagram**, next to each weight's buttons, shows what exercising pays at each ETH price. 

## Layout

```
src/
  ConcentratedCurveHook.sol        the v4 hook: pools, positions, swaps, fees, moving-average oracle
  curves/LogCurve.sol              your curve (ICurve), with libraries/LogCurveMath.sol
  libraries/                       ticks, fee growth and the swap loop (CurvePool, CurveSwapMath, ...)
  weights/                         WeightVault (ERC-721), WeightToken (ERC-6909), WeightAuction
script/DeployLocal.s.sol           local deployment (anvil) for the app
script/DeployUnichainSepolia.s.sol testnet deployment on Uniswap's PoolManager, see docs/DEPLOY_UNICHAIN.md
frontend/                          Next.js app: components/ (the page), lib/app.ts (chain actions), lib/curve.js (math,
                                   50/50 solver), lib/charts.js, lib/chain.js (ABIs), lib/server/ (indexer, pool state), app/api/
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
| Vectorized/solady | `2afba69bf67b78dd4abeadcc696052b3a6f71499` | MIT |

This is a prototype and has **not been audited**.
