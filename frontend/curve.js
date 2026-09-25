// Log-curve math in human units, used for instant previews and the charts (the chain is the source of truth).
//   price P = USDC per ETH, amounts in ETH / USDC, liquidity L in USDC per unit of ln(P)
//   position on [pa, pb]:  x(P) = L (1/Pc - 1/pb),   y(P) = L ln(Pc/pa),   Pc = clamp(P, pa, pb)
//   i.e. the unit curve x e^y = 1 scaled by L and offset:  (x + L/pb) e^(y/L + ln pa) = L

export const FEE = 0.003;

export function reserves(pos, P) {
  const pc = Math.min(Math.max(P, pos.pa), pos.pb);
  return { x: pos.L * (1 / pc - 1 / pos.pb), y: pos.L * Math.log(pc / pos.pa) };
}

export function totals(positions, P) {
  let x = 0;
  let y = 0;
  for (const p of positions) {
    const r = reserves(p, P);
    x += r.x;
    y += r.y;
  }
  return { x, y };
}

/** Liquidity trading at price P: the sum of L over ranges containing P */
export function activeLiquidity(positions, P) {
  return positions.reduce((s, p) => s + (p.pa <= P && P < p.pb ? p.L : 0), 0);
}

/** Dollar value of a position's ETH leg (the "ETH weight") at price P: P * x(P) */
export function ethLegValue(pos, P) {
  return P * reserves(pos, P).x;
}

function boundaries(positions) {
  return [...new Set(positions.flatMap((p) => [p.pa, p.pb]))].sort(
    (a, b) => a - b,
  );
}

/**
 * Swap along the aggregate curve, segment by segment between range edges (the pool's tick walk, without ticks).
 * zeroForOne = sell ETH for USDC. exactIn: `amount` is the input including the fee; otherwise the desired output.
 * Returns { ok, price, amountIn, amountOut, fee } or { ok: false, reason }.
 */
export function simulateSwap(
  positions,
  P,
  zeroForOne,
  exactIn,
  amount,
  fee = FEE,
) {
  if (!(amount > 0)) return { ok: false, reason: "enter an amount" };
  const edges = boundaries(positions);
  let remaining = amount;
  let totalIn = 0;
  let totalOut = 0;
  let feeTotal = 0;
  for (let guard = 0; remaining > amount * 1e-12 && guard < 500; guard++) {
    const candidates = zeroForOne
      ? edges.filter((e) => e < P * (1 - 1e-12))
      : edges.filter((e) => e > P * (1 + 1e-12));
    if (candidates.length === 0)
      return {
        ok: false,
        reason: "not enough liquidity: the swap would leave every range",
      };
    const next = zeroForOne ? Math.max(...candidates) : Math.min(...candidates);
    const mid = Math.sqrt(P * next);
    const L = activeLiquidity(positions, mid);
    if (L === 0) {
      P = next; // an empty stretch of price is crossed for free
      continue;
    }
    const d0 = L * Math.abs(1 / next - 1 / P); // ETH between P and next
    const d1 = L * Math.abs(Math.log(next / P)); // USDC between P and next
    const curveIn = zeroForOne ? d0 : d1;
    const curveOut = zeroForOne ? d1 : d0;
    let stepIn;
    let stepOut;
    let stepFee;
    let Pn;
    if (exactIn) {
      const need = curveIn / (1 - fee);
      if (remaining >= need) {
        [stepIn, stepOut, stepFee, Pn] = [
          curveIn,
          curveOut,
          need - curveIn,
          next,
        ];
      } else {
        stepIn = remaining * (1 - fee);
        stepFee = remaining - stepIn;
        Pn = zeroForOne ? 1 / (1 / P + stepIn / L) : P * Math.exp(stepIn / L);
        stepOut = zeroForOne ? L * Math.log(P / Pn) : L * (1 / P - 1 / Pn);
      }
      remaining -= stepIn + stepFee;
    } else {
      if (remaining >= curveOut) {
        [stepOut, stepIn, Pn] = [curveOut, curveIn, next];
      } else {
        stepOut = remaining;
        Pn = zeroForOne
          ? P * Math.exp(-stepOut / L)
          : 1 / (1 / P - stepOut / L);
        stepIn = zeroForOne ? L * (1 / Pn - 1 / P) : L * Math.log(Pn / P);
      }
      stepFee = (stepIn * fee) / (1 - fee);
      remaining -= stepOut;
    }
    totalIn += stepIn + stepFee;
    totalOut += stepOut;
    feeTotal += stepFee;
    P = Pn;
  }
  return {
    ok: true,
    price: P,
    amountIn: totalIn,
    amountOut: totalOut,
    fee: feeTotal,
  };
}

// --- 50 / 50 ranges ----------------------------------------------------------------------------------------------
// A position holds equal dollar amounts of ETH and USDC where P·x = y, i.e. 1 − P/pb = ln(P/pa). Solving for P:
//   P·e^(P/pb) = e·pa   =>   P = pb · W(e·pa / pb)          (W = Lambert W, principal branch)
// Fixing P instead, the same equation gives each bound from the other in closed form:
//   pa = P·e^(P/pb − 1)          pb = P / (1 + ln(pa/P))     (needs P/e < pa < P, i.e. pb > P)

/** Principal branch of Lambert W: the w >= -1 with w·e^w = z, for z >= -1/e (Halley's method). */
export function lambertW(z) {
  const branch = z + 1 / Math.E;
  if (branch < -1e-15) return NaN;
  if (branch <= 1e-15) return -1; // the branch point, where Halley's step would divide by zero
  if (z === 0) return 0;
  let w = z < 1 ? z * (1 - z) : Math.log(z) - Math.log(Math.log(z) + 1); // starting guess
  if (z < -0.3) w = -1 + Math.sqrt(2 * (1 + Math.E * z));
  for (let i = 0; i < 50; i++) {
    const ew = Math.exp(w);
    const f = w * ew - z;
    const step = f / (ew * (w + 1) - ((w + 2) * f) / (2 * w + 2));
    w -= step;
    if (Math.abs(step) <= 1e-15 * (1 + Math.abs(w))) break;
  }
  return w;
}

/** The price at which a position on [pa, pb] is half ETH, half USDC by value */
export function fiftyFiftyPrice(pa, pb) {
  return pb * lambertW((Math.E * pa) / pb);
}

/** The min price that makes [pa, pb] 50/50 at price P (any pb > P) */
export function lowerFor5050(P, pb) {
  return pb > P ? P * Math.exp(P / pb - 1) : NaN;
}

/** The max price that makes [pa, pb] 50/50 at price P (needs P/e < pa < P) */
export function upperFor5050(P, pa) {
  const k = 1 + Math.log(pa / P);
  return pa < P && k > 0 ? P / k : NaN;
}

/** Dollar value of one unit of liquidity on [pa, pb] at price P */
export function valuePerL(pa, pb, P) {
  const r = reserves({ pa, pb, L: 1 }, P);
  return P * r.x + r.y;
}

// --- ticks and prices (currency0 = ETH with 18 decimals, currency1 = USDC with 6) ------------------------------------
export const DECIMAL_SHIFT = 1e12; // human price = raw price * 10^(18 - 6)

export function tickToPrice(tick) {
  return 1.0001 ** tick * DECIMAL_SHIFT;
}

export function priceToTick(price, spacing) {
  const t = Math.log(price / DECIMAL_SHIFT) / Math.log(1.0001);
  return Math.round(t / spacing) * spacing;
}

export function sqrtPriceToPrice(sqrtPriceX96) {
  const s = Number(sqrtPriceX96) / 2 ** 96;
  return s * s * DECIMAL_SHIFT;
}

/** sqrtPriceX96 for a human price, exactly (BigInt): sqrt(p * 1e-12) * 2^96 */
export function priceToSqrtPriceX96(price) {
  const pWad = BigInt(Math.round(price * 1e18));
  return isqrt((pWad << 192n) / 10n ** 30n);
}

/** floor(sqrt(n)): integer Newton iteration started above the root */
function isqrt(n) {
  if (n < 2n) return n;
  let x = BigInt(Math.ceil(Math.sqrt(Number(n)) * (1 + 1e-9))) + 1n;
  for (;;) {
    const y = (x + n / x) >> 1n;
    if (y >= x) return x;
    x = y;
  }
}
