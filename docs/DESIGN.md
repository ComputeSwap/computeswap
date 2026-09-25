# Concentrated liquidity on the log curve: design

A Uniswap v4 hook that runs your trading function with Uniswap-v3-style concentrated liquidity. LPs pick a price range. Positions with the same or different ranges add up correctly, and fees are shared pro rata. The curve is

$$(x + p_b^{-1})\,e^{\,y + 1 + \ln p_a} = e \qquad\Longleftrightarrow\qquad y = \ln\!\frac{1}{x + p_b^{-1}} - \ln p_a$$

The weights feature (splitting a position's ETH off and auctioning it) is described in [WEIGHTS.md](WEIGHTS.md).

---

## 1. The key idea: write the curve in *price space*

Uniswap v3 never stores reserves. It stores a price and a liquidity, and derives the reserves from them. The same works for any curve that can be written as two functions of the marginal price $P$ (currency1 per currency0). For $x e^y = 1$ with liquidity $L = 1$:

$$\bar x(P) = 1/P \quad(\text{decreasing}), \qquad \bar y(P) = \ln P \quad(\text{increasing}), \qquad d\bar y = -P\,d\bar x$$

The last identity says the curve's marginal price really is $P$.

**Offsetting is translation.** A position with liquidity $L$ on $[p_a, p_b]$ is the unit curve scaled by $L$ and shifted:

$$x(P) = L\big(\bar x(P) - \bar x(p_b)\big) = L\Big(\frac1P - \frac1{p_b}\Big), \qquad y(P) = L\big(\bar y(P) - \bar y(p_a)\big) = L\ln\frac{P}{p_a}$$

At $P = p_b$ the position is all USDC; at $P = p_a$ it is all ETH. This is v3's "virtual reserves" construction.

**Why positions with different ranges add up.** Inside a range, $dx = L\,\bar x'(P)\,dP$ and $dy = L\,\bar y'(P)\,dP$. The range enters only through the constant offsets, never through the slopes. So all positions containing the current price trade together as **one** position with liquidity $\sum L_i$, and v3's machinery works unchanged: ticks, liquidityNet, active liquidity, fee growth. The curve only has to answer four questions: how much of each token lies between two prices, and where the price lands after adding or removing an amount of either token.

---

## 2. The log curve

The unit form $x e^{y} = 1$, lifted to liquidity $L$ and offset to $[p_a, p_b]$:

$$\Big(x + \frac{L}{p_b}\Big)\, e^{\,y/L + \ln p_a} = L \qquad (\text{with } L = 1 \text{ this is your } (x+p_b^{-1})e^{y+1+\ln p_a} = e)$$

| | |
|---|---|
| position reserves | $x(P) = L\,(1/P - 1/p_b)$, $\quad y(P) = L \ln(P/p_a)$ |
| ETH in ($\Delta x$), inside one range | $1/P' = 1/P + \Delta x/L$, $\quad \Delta y_{out} = L\ln(1 + P\,\Delta x/L)$ |
| USDC in ($\Delta y$), inside one range | $\ln P' = \ln P + \Delta y/L$, $\quad \Delta x_{out} = \frac{L}{P}\big(1 - e^{-\Delta y/L}\big)$ |
| meaning of $L$ | USDC absorbed per unit of $\ln P$: every 1% move inside a range trades $\approx 0.01L$ of value, **at any price level** |

Properties worth knowing:

- **Depth is flat in log-price.** In a constant-product pool, the depth per 1% move scales with $\sqrt P$. Here it is constant, and so is the LP's loss-versus-rebalancing rate, $\sigma^2 L/2$.
- **The curve is asymmetric.** USDC (currency1) is the logarithmic side. Native ETH always sorts first as currency0, so this is the right orientation for ETH/USDC. For a pair whose log-side asset sorts first, deploy the mirrored curve ($\bar x = -\ln P$, $\bar y = P$).
- **The full range is expensive in USDC.** $y = L\ln(P/p_a)$ grows without bound as $p_a \to 0$: a full-range position at $P = 1$ holds about $88.7L$ of USDC and $L$ of ETH. Concentrated ranges are the natural use.

---

## 3. 50/50 ranges (Lambert W)

A position is half ETH, half USDC by value where $P\,x = y$:

$$1 - \frac{P}{p_b} = \ln\frac{P}{p_a} \quad\Longleftrightarrow\quad \frac{P}{p_b}\,e^{P/p_b} = \frac{e\,p_a}{p_b} \quad\Longleftrightarrow\quad P_{50/50} = p_b\,W\!\Big(\frac{e\,p_a}{p_b}\Big)$$

Here $W$ is the Lambert W function (principal branch). The left side falls strictly from $1 - p_a/p_b > 0$ at $p_a$ to $-\ln(p_b/p_a) < 0$ at $p_b$, so every range has exactly one 50/50 price.

The front end runs this backwards. Fix $P$ at today's price and the same equation gives either bound from the other, in closed form:

$$p_a = P\,e^{P/p_b - 1} \qquad\qquad p_b = \frac{P}{1 + \ln(p_a/P)} \quad (\text{needs } P/e < p_a < P)$$

For example, at $P = 1$: $p_b = 2 \Rightarrow p_a = e^{-1/2} = 0.6065$, and $p_b = 4 \Rightarrow p_a = e^{-3/4} = 0.4724$. No 50/50 range reaches below $P/e$, and none is symmetric in log-price: $p_b/P$ is always larger than $P/p_a$.

`frontend/curve.js` has `lambertW` (Halley's method), `fiftyFiftyPrice`, `lowerFor5050` and `upperFor5050`. The add-liquidity form solves the bound you didn't type from the other bound *after it snaps to a tick*, so the deposit lands within a few hundredths of a percent of 50/50.

---

## 4. How liquidity is tracked

Exactly as in v3:

- **A position** stores a constant $L$ for its range. What changes as the price moves is its *composition*, $x(P)$ and $y(P)$, which is computed on demand and never stored.
- **Each initialized tick** stores `liquidityNet` (+L at a position's lower tick, −L at its upper tick), `liquidityGross`, and the fee growth "outside" the tick.
- **The pool** stores the price and the *active* liquidity: the sum of $L$ over positions that contain the price. Crossing a tick adds its `liquidityNet`, or subtracts it when moving down.
- **Same range, different users:** their $L$ values add. They trade as one position of size $L_A + L_B$ and split fees pro rata to $L$.
- **Different ranges:** they add where they overlap.

This scenario is in `test/LogCurveTrace.t.sol` and is checked against an independent model:

```
tick:        -9000     -6000     -3000   -1200      600   1800      4200   6000
alice 1e21             [==================================================]
bob   2e21             [==================================================]
carol 4e21                               [==========]
dave  3e21                                                [=========]
erin  2.5e21  [===================]
active L:      2.5   |   5.5    |   3   |    7     |  3  |    6    |  3   |  0      (x 1e21)
```

**Fees** are charged on the input of each swap step and credited as `feeGrowthGlobal += fee / L_active`. Each position earns $L\cdot(\text{fee growth inside its range})$ using v3's `feeGrowthOutside` technique. Fees are paid out on every liquidity change; removing 0 liquidity collects them.

---

## 5. Solidity architecture

```
            ┌──────────────────────────────────────────────────────────────────┐
 swapper ─▶ │ any v4 router ─▶ PoolManager.swap ─▶ hook.beforeSwap             │
 LP ──────▶ │ WeightVault (ERC-721) ─▶ hook.addLiquidity / removeLiquidity      │
            │                                   ▼                              │
            │  ConcentratedCurveHook   v4 plumbing, claims, reserves, oracle   │
            │  CurvePool (library)     ticks, bitmap, positions, fee growth    │
            │  CurveSwapMath (library) one step inside a range                 │
            │  ICurve ◀─ LogCurve      the trading function, fixed per hook     │
            └──────────────────────────────────────────────────────────────────┘
```

| file | role |
|---|---|
| `src/ConcentratedCurveHook.sol` | The v4 hook, plus a 10-minute moving-average tick per pool (used by the weights). |
| `src/libraries/CurvePool.sol` | Pool state, `modifyLiquidity`, `swap`: v4's tick-walking loop, fee growth, positions. |
| `src/libraries/CurveSwapMath.sol` | v4's `SwapMath.computeSwapStep` with the curve behind an interface, clamped so the curve can't overshoot a tick. |
| `src/libraries/CurveLiquidityAmounts.sol` | Converts between liquidity and token amounts. |
| `src/curves/LogCurve.sol`, `src/libraries/LogCurveMath.sol` | Your curve, with directed rounding. |
| `src/interfaces/ICurve.sol` | The four functions the engine asks of a curve (the same signatures as Uniswap's `SqrtPriceMath`), and rounding rules R1–R5. |
| `src/weights/*` | Position NFTs, ETH weights, Dutch auctions ([WEIGHTS.md](WEIGHTS.md)). |

### Design decisions

- **The state is `sqrtPriceX96`**, as in v4. Ticks, `sqrtPriceLimitX96`, events and the mirrored slot0 keep their meaning, and v4's `TickMath` and `TickBitmap` are reused as-is. The log curve converts internally, working in $1/P$ and $\ln P$.
- **The curve is a separate contract, fixed when the hook is deployed** (`new ConcentratedCurveHook(poolManager, curve)`), and every pool the hook creates uses it: `initializePool(key, price, mirror)` takes no curve. The pool's identity (tokens, fee, tick spacing, hook) does not include a curve, so if pools could each choose their curve, anyone could create the canonical ETH/USDC pool first on a curve of their own. The seam stays because it costs little, and because it lets the engine be checked against vanilla v4: the tests deploy a second hook on an $xy = L^2$ mock (`test/mocks/ConstantProductCurve.sol`) and compare. Compiling the log curve into the hook would save about 1k gas per curve call.
- **Custom-curve swaps.** `beforeSwap` returns a `BeforeSwapDelta` that takes the whole specified amount, so v4's own curve runs with zero. The hook settles in ERC-6909 claims, so no ERC-20 transfers happen during swaps.
- **Liquidity lives in the hook**, as ERC-6909 claims in the PoolManager. `beforeAddLiquidity` reverts, so nobody can add to v4's own curve. `beforeInitialize` reverts, so pools can only be created through the hook, which binds the curve in the same transaction.
- **Reserves are accounted per pool** (`reserves[poolId]`) with checked math, so a pool can never pay out another pool's tokens.
- **Swaps are all-or-nothing.** Reaching `sqrtPriceLimitX96`, or running out of liquidity, reverts, so the limit acts as a slippage bound.
- **Price mirroring is optional** (`mirrorPrice`). After each swap the hook makes a 1-wei swap on v4's empty curve to walk v4's slot0 to the curve price. Quoters and UIs reading `getSlot0` then see the real price. It costs about 25k gas.
- **Licensing.** The project is BUSL-1.1, like Uniswap v4-core (see `LICENSE`; the earlier MIT license is kept in `license-mit/`). From v4-core, the hook uses only the MIT libraries (`TickMath`, `TickBitmap`, `SqrtPriceMath`, `FullMath`, types). `CurvePool` is an independent implementation of the whitepaper algorithms, not a copy of v4's BUSL `Pool.sol`. The BUSL PoolManager is used only in tests and the local deployment.

### Swap sequence

1. The router calls `PoolManager.swap`, which calls `hook.beforeSwap(params)`.
2. The hook updates the pool's moving-average tick with the pre-swap tick.
3. `CurvePool.swap` walks the initialized ticks. For each step it calls `CurveSwapMath.computeSwapStep(curve, …)` and accrues fee growth; at each tick it crosses, it updates the active $L$.
4. The hook books reserves, mints claims for the input, burns claims for the output, and optionally mirrors the price.
5. The hook returns `BeforeSwapDelta(+in, −out)`. v4 then runs its own swap with amount 0 and settles with the router.

---

## 6. Precision

- **The ETH side** ($1/P$) is rational. It is computed in Q96 with directed rounding and a single rounding step, and the error is at most 1–2 wei.
- **The USDC side** ($\ln P$) uses solady's `lnWad` and `expWad`. Over 12,000 samples (`python/check_math_bounds.py`), `lnWad` is within 1.05e-18 and `expWad` within 1e-18. Every result is widened by about 4× that (`LN_ERR`, `EXP_*`), always in the pool's favour.
- **Rounding is checked exactly.** About 2,000 amount samples and 1,900 next-price samples show 0 violations of R1–R5 against 150-digit arithmetic (`python/check_curve.py`).
- **Cost to traders**, for $|tick| \le 400k$: at most about 11 × (position size × 1e-18 + 1 wei) per swap step.

---

## 7. Verification: 43 tests in 10 suites, plus 3 Python checks

| check | what it shows | result |
|---|---|---|
| `LogCurveHook.t.sol` | Deposits follow the closed form, and your invariant holds. Same-range LPs are pro rata, and active L equals the sum of in-range L across tick crossings. Also covers closed-form swaps, exact-out, no free round trip, all-or-nothing, price mirroring, fees only in range, native ETH, per-pool isolation, access control, and liquidity sizing. | 15 tests, including a 200-run solvency fuzz |
| `CurveHookInvariants.t.sol` | Random LP and swap activity on a live pool: active L = Σ in-range L, reserves ≥ Σ(principal + fees) after every operation, pro-rata fees, no round-trip profit, and everyone can exit | 512 × 30-operation sequences |
| `CurveConformance.t.sol` | The necessary conditions of R1–R5, additivity, and monotonicity | 7 properties, fuzzed |
| `CurveDump` + `check_curve.py` | The log curve against 150-digit exact math | 0 violations |
| `LogCurveTrace` + `reference_model.py` | An independent model with no ticks, only the sum of each position's offset curve under v4 fee rules | every price, amount and fee within 4.4e-15 relative |
| `UserScenario.t.sol` | ETH/USDC at $1: $100 on [0.25, 4] and $100 on [0.5, 2], six buys and sells, and a full exit | pass; `reference_model.py` replays it (worst gap 1.9 USDC units, the size of one 6-decimal step) |
| `Weights.t.sol` | Split, Dutch auction, exercise with the oracle guard, expiry, cancel and merge, flash manipulation, an owner who cannot block exercise, access control | 7 tests |
| `ConstantProductParity.t.sol` | The engine with an $xy = L^2$ test mock against a vanilla v4 pool: every delta, fee, price, tick and fee-growth value | bit-identical |

Gas per swap, router included, in the test environment:

| | vanilla v4 | hook + log curve | with mirroring |
|---|---|---|---|
| swap within a range | 127k | 185k | 210k |
| swap crossing one tick | 164k | 228k | 253k |

---

## 8. Limitations and next steps

- **Not audited.** The hook custodies all liquidity, so treat it as a prototype until it has been reviewed.
- **Partial fills.** Swaps are all-or-nothing, so routers should size trades with a quoter.
- **Fees** are a static LP fee from the PoolKey, with no protocol fee.
- **Gas.** Compiling the curve into the hook, packing reserves into pool state, and dropping the hook's own Swap event would each save a few thousand gas.

## Running

Foundry ≥ 1.0 (Cancun EVM, solc 0.8.26). The Python checks need `mpmath`.

```bash
forge test
```

```bash
forge test --match-contract "CurveDump|LogCurveTrace|MathBoundsDump|UserScenario" && python python/check_curve.py && python python/reference_model.py && python python/check_math_bounds.py
```
