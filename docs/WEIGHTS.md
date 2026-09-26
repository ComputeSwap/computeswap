# Splitting an LP position into weights, and selling the ETH weight in a Dutch auction

A log-curve position with liquidity $L$ on $[p_a, p_b]$ holds two amounts that move with the price $P$ (USDC per ETH):

$$x(P) = L\left(\frac1P - \frac1{p_b}\right)\ \text{ETH}, \qquad y(P) = L\ln\frac{P}{p_a}\ \text{USDC} \qquad (p_a \le P \le p_b)$$

These are the position's two **weights**. The LP can split one of them off as a token for a while and sell it. The ETH weight is the natural one to sell.

## 1. What the ETH weight gives its holder

Definition: the holder can tell the vault to withdraw the liquidity behind the weight at any time before expiry, **at the price at that moment**. The holder gets the ETH part and the LP gets the USDC part. If ETH has fallen from $1 to $0.80, the position holds more ETH than before, so the weight pays more ETH.

| | ETH in the weight | its dollar value $V(P) = P\,x(P)$ |
|---|---|---|
| $0 \le P \le p_a$ | $L(1/p_a - 1/p_b)$, its maximum | $L\,\dfrac{P}{p_a}\Big(1 - \dfrac{p_a}{p_b}\Big)$: rises in a straight line from 0 |
| $p_a \le P \le p_b$ | $L(1/P - 1/p_b)$ | $L\Big(1 - \dfrac{P}{p_b}\Big)$: falls in a straight line to 0 |
| $P \ge p_b$ | 0 | 0 |

**On a linear price axis the payoff is a triangle.** It is 0 at $P = 0$, rises in a straight line to its peak $L(1 - p_a/p_b)$ at $p_a$, falls in a straight line to 0 at $p_b$, and stays at 0 above. Per unit of liquidity, the right side is $w(P) = 1 - P/p_b$ on $(p_a, p_b)$.

- **Below $p_a$** the weight is already all ETH, a fixed amount, so its dollar value falls with the ETH price.
- **Inside the range** the ETH amount shrinks as the price rises. Because $x = L(1/P - 1/p_b)$, the dollar value $P\,x$ is linear in $P$ as well.
- **On a log price axis** the same straight lines look curved. The shape itself is two straight lines.

As options, the triangle is exactly

$$V(P) = \frac{L}{p_b}\,(p_b - P)^+ \;-\; \frac{L}{p_a}\,(p_a - P)^+,$$

that is, long $L/p_b$ puts struck at $p_b$ and short $L/p_a$ puts struck at $p_a$. The app draws this diagram under every ETH weight, with that position's own $p_a$ and $p_b$. For an auction it also draws the current auction price. A buyer never gains by paying more than the peak $L(1 - p_a/p_b)$, so the sell popup starts auctions at the peak and lets them fall to today's value.

The holder can exercise at any time before expiry (American style) and is paid in ETH (physical settlement). The USDC weight is the mirror image. It pays $L\ln(P/p_a)$ USDC and grows as ETH rises.

Example: range 2, $[0.5, 2]$, worth $100 at $1 (L = 83.775):

| ETH price | ETH weight | worth | USDC left to the LP |
|---|---|---|---|
| $1.00 | 41.90 ETH | $41.90 | 58.10 |
| $0.80 (UI run) | 62.83 ETH | $50.27 | 39.42 + fees |
| $0.50 (floor of the range) | 125.66 ETH | $62.83 (the maximum) | 0 |

## 2. Which token standard

The design uses two kinds of token.

**The position is an ERC-721** (`WeightVault`, symbol `LCLP`). Each position is unique (its range, fees and lock state), and whoever owns the NFT receives the other leg and the fees when a weight is exercised. A position can be sold as a unit, and the payout follows it (`test_otherLegFollowsTheNft`).

**Each weight series is an ERC-6909 id** (`WeightToken`). One series is "the ETH weight of position #n, expiring at T". It is fungible within the series, and one token unit is one unit of liquidity.

| option for the weight | why not |
|---|---|
| ERC-721 per weight | Not divisible. The LP could not sell 40% to one buyer and 60% to another, and the auction could only sell the whole lot. |
| ERC-20 per series | Each split would deploy a new token contract (≈ 1M gas), and wallets would need to discover every new address. Expiry still needs a custom `balanceOf`. |
| ERC-1155 | Fungible ids work, but every transfer calls `onERC1155Received` on the receiver. That adds a re-entrancy surface in the middle of an auction purchase or exercise, and contracts must implement the hook to hold the token. Batch transfers aren't needed here. |
| **ERC-6909** | Minimal multi-token: fungible per id, no receiver callbacks, per-id allowances and operators. A new series is a new id in the existing contract, with no deployment. Uniswap v4 itself uses it for its claims, so it fits the stack. |

The units are liquidity units. The ETH a unit pays is not fixed: it is $x(P)/L$ at exercise. So the units measure how much of the position you own, not an amount of ETH. `decimals(id)` is 6 because $L$ is in USDC per unit of $\ln P$. Wallets that only understand ERC-20 can be served later by a per-series ERC-20 wrapper.

## 3. Expiry: "auto-burned" without a transaction

Nothing on a blockchain runs on its own at a given time, so expiry is lazy.

- `WeightToken.balanceOf` returns 0 once the series has expired.
- Transfers of an expired series revert with `SeriesExpired`.
- `WeightVault.exercise` reverts after expiry.
- `WeightVault.lockedLiquidity` returns 0, so the LP can `decreaseLiquidity` everything.

To every reader this looks exactly like a burn, with no keeper and no gas spent at expiry. The stale numbers stay in storage, but nothing can use them.

## 4. Contracts

```
WeightVault (ERC-721)   owns every position inside the hook (salt = tokenId)
  mint(key, tickLower, tickUpper, L, max0, max1, deadline)   open a position, NFT to the LP
  decreaseLiquidity(id, L, min0, min1, deadline)             withdraw unlocked liquidity / collect fees (0)
  split(id, units, leg, duration) -> seriesId                lock units, mint that many weight tokens to the LP
  exercise(seriesId, units, minLeg, deadline)                before expiry, oracle-checked: withdraw units now,
                                                             leg -> caller, other leg + all fees -> NFT owner
  merge(seriesId, units)                                     owner burns weights they hold, unlocking early
  claim(currency, to)                                        owner payouts that could not be pushed (section 5)
  previewExercise(seriesId, units)                           amounts + whether the oracle allows it now
WeightToken (ERC-6909)  one id per series; balance reads 0 after expiry; only the vault mints/burns
WeightAuction           create(seriesId, lot, payToken, start, floor, drop): escrows the lot
                        start price for one block (no buys yet; seller can cancel), then falls to floor over drop,
                        then stays at floor
                        buy(auctionId, amount, maxCost): partial fills once the drop starts; seller gets sale minus 5% of (sale − floor)
                        cancel(auctionId): unsold weights go back (or the auction just closes if they lapsed)
ConcentratedCurveHook   + a moving-average tick per pool (time constant 10 min), updated at every swap
```

The lifecycle that the UI walks through:

```
LP: add liquidity ──> popup: split the ETH weight (share, days) ──> Dutch auction (1-block announce, drop, start, floor)
buyer: buy (all or part) ──> ... ETH falls ... ──> exercise: vault withdraws that liquidity at today's price
                                                     buyer <- ETH leg      LP (NFT owner) <- USDC leg + fees
             or: nothing happens for 5 days ──> weights lapse, lock lifts ──> LP withdraws everything
```

Only one series per position can be live at a time. Splitting again is allowed once it has expired or been fully merged or exercised.

## 5. Safety

**Flash manipulation.** Exercise happens at the pool's current price. Without a guard, a holder could dump ETH into the pool (a flash loan is enough), exercise at the depressed price to take a much larger ETH leg, and buy the ETH back. So `exercise` reverts with `OracleDeviation(tick, emaTick)` unless the current tick is within `maxOracleDeviation` = 100 ticks (≈ 1%) of the hook's moving-average tick. That average is updated at the start of every swap, before the swap moves the price, with time constant τ = 10 min. A move made in the same block doesn't change it (`test_flashManipulationBlocked`).
- Holding a manipulated price long enough to drag the average (≈ 30 min for a 20% move) means paying arbitrageurs the whole time.
- What remains exploitable is a move of up to 1% inside the tolerance. Lower `maxOracleDeviation` to tighten it.

**Liveness near expiry.** After a real, sharp move, exercise is refused until the average catches up. The UI run needed about 33 minutes after a 23% drop. Holders should not wait for the last half hour before expiry in a volatile market. A different oracle, such as Chainlink or a v4 TWAP hook, can replace `getOracle` without other changes.

**The LP cannot block an exercise.** The owner's payout used to be a plain push, so an LP could sell the weight and then move the NFT to a contract that rejects ETH, or to a USDC-blacklisted address. Every exercise would then revert until the weight lapsed. Now a failed push is credited to `owed[owner][currency]`, and the owner withdraws it with `claim(currency, to)`. `test_ownerCannotBlockExercise` fails with `ETHTransferFailed()` without the fix and passes with it.

**Locked means locked.** While a series is live, the vault refuses to withdraw its units: `LiquidityLocked(free)` reports what can still be withdrawn. Exercising burns the caller's tokens first, so no one can exercise more than they hold.

**Auction.** The lot is escrowed in the auction contract, so the seller can't sell it twice. Buyers cap their cost with `maxCost`. Buying a lapsed lot reverts, and cancelling one simply closes the auction.

Not audited.

## 6. Verified

`test/Weights.t.sol` has 7 tests:
- your example (weight bought after 6 h of a Dutch auction; ETH pushed to $0.79; exercise refused right after the move, allowed an hour later; exact amounts);
- expiry;
- cancel and merge;
- flash manipulation;
- the other leg following the NFT;
- the owner not being able to block an exercise;
- access control.

The same flow was clicked through in the front end (see the README) on a local chain. At each step the numbers matched the vault's preview to the wei, apart from the exerciser's gas.

| step (UI run) | gas |
|---|---|
| split | 183k |
| create auction (plus approve 47k) | 182k |
| buy | 92–97k |
| exercise | 242k |
