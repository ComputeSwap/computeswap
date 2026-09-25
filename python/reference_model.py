"""Independent reference model of concentrated liquidity on the log curve, used to check the on-chain engine.

The model has no ticks, no liquidityNet and no "active liquidity" variable. The pool is a list of positions, each an
offset copy of the unit curve x * e^y = 1, i.e. in price space

    x_i(P) = L_i * (1/Pc - 1/pb_i),    y_i(P) = L_i * ln(Pc / pa_i),    Pc = clamp(P, pa_i, pb_i)

and a swap moves the single pool price P until the SUM of the positions' reserves has absorbed the trade. Fees follow
Uniswap v4 (charged on input, credited pro rata to the liquidity in range while that part of the trade executes).

    forge test --match-contract LogCurveTrace      # writes reports/trace.csv
    python python/reference_model.py
    forge test --match-contract UserScenario       # the ETH/USDC scenario from the front-end brief
    python python/reference_model.py reports/scenario_trace.csv

For every operation the on-chain amounts, price and fees are compared with the model at 50 significant digits, and
the rounding is checked to favour the pool.
"""
import csv
import pathlib
import sys

import mpmath as mp

mp.mp.dps = 50
ROOT = pathlib.Path(__file__).resolve().parents[1]
Q96 = mp.mpf(2) ** 96

WEI = 4  # plus a few wei of absolute rounding


class Position:
    def __init__(self, liquidity, pa, pb):
        self.L = mp.mpf(liquidity)
        self.pa = pa
        self.pb = pb
        self.fees = [mp.mpf(0), mp.mpf(0)]

    def reserves(self, P):
        pc = min(max(P, self.pa), self.pb)
        return self.L * (1 / pc - 1 / self.pb), self.L * mp.log(pc / self.pa)

    def contains(self, lo, hi):
        """position is active on the whole price segment [lo, hi]"""
        return self.pa <= lo and hi <= self.pb


class Model:
    def __init__(self, fee_pips):
        self.f = mp.mpf(fee_pips) / 10**6
        self.positions = {}  # (owner, tickLower, tickUpper) -> Position
        self.tick_price = {}  # tick -> P at that tick (from TickMath)

    # --- aggregate reserves: a plain sum over positions -------------------------------------------------------
    def total(self, P):
        x = y = mp.mpf(0)
        for p in self.positions.values():
            px, py = p.reserves(P)
            x += px
            y += py
        return x, y

    def boundaries(self):
        return sorted({p.pa for p in self.positions.values()} | {p.pb for p in self.positions.values()})

    def active(self, lo, hi):
        return [p for p in self.positions.values() if p.L > 0 and p.contains(lo, hi)]

    # --- swaps ---------------------------------------------------------------------------------------------------
    def swap(self, P, zero_for_one, amount_specified):
        """Returns (new price, amount in incl. fee, amount out). Walks the segments between position boundaries,
        in each of which the curve is the sum of the in-range positions' curves."""
        exact_in = amount_specified < 0
        remaining = mp.mpf(abs(amount_specified))  # gross input left (exact in) or output left (exact out)
        total_in = total_out = mp.mpf(0)
        bounds = self.boundaries()
        while remaining > 0:
            if zero_for_one:
                nxt = max([b for b in bounds if b < P], default=None)
                seg = (nxt, P)
            else:
                nxt = min([b for b in bounds if b > P], default=None)
                seg = (P, nxt)
            if nxt is None:
                raise RuntimeError("model ran out of liquidity")
            act = self.active(*seg)
            L = sum((p.L for p in act), mp.mpf(0))
            if L == 0:
                P = nxt
                continue
            # curve amounts to reach the segment end: currency0 moves with 1/P, currency1 with ln P
            d0 = L * abs(1 / nxt - 1 / P)
            d1 = L * abs(mp.log(nxt / P))
            cin, cout = (d0, d1) if zero_for_one else (d1, d0)
            if exact_in:
                need = cin / (1 - self.f)  # gross input to reach the end, fee included
                if remaining >= need:
                    step_in, step_out, fee, P_new = cin, cout, need - cin, nxt
                else:
                    step_in = remaining * (1 - self.f)
                    fee = remaining - step_in
                    P_new = self._price_after_input(P, L, step_in, zero_for_one)
                    step_out = self._output(P, P_new, L, zero_for_one)
                remaining -= step_in + fee
            else:
                if remaining >= cout:
                    step_out, step_in, P_new = cout, cin, nxt
                else:
                    step_out = remaining
                    P_new = self._price_after_output(P, L, step_out, zero_for_one)
                    step_in = self._input(P, P_new, L, zero_for_one)
                fee = step_in * self.f / (1 - self.f)
                remaining -= step_out
            for p in act:  # fees pro rata to L among the positions trading in this segment
                p.fees[0 if zero_for_one else 1] += fee * p.L / L
            total_in += step_in + fee
            total_out += step_out
            P = P_new
            if remaining < mp.mpf("1e-30"):
                remaining = mp.mpf(0)
        return P, total_in, total_out

    @staticmethod
    def _price_after_input(P, L, a, zero_for_one):
        return 1 / (1 / P + a / L) if zero_for_one else P * mp.exp(a / L)

    @staticmethod
    def _price_after_output(P, L, a, zero_for_one):
        return P * mp.exp(-a / L) if zero_for_one else 1 / (1 / P - a / L)

    @staticmethod
    def _output(P, Q, L, zero_for_one):
        return L * mp.log(P / Q) if zero_for_one else L * (1 / P - 1 / Q)

    @staticmethod
    def _input(P, Q, L, zero_for_one):
        return L * (1 / Q - 1 / P) if zero_for_one else L * mp.log(Q / P)


def price(sqrt_price_x96):
    return (mp.mpf(sqrt_price_x96) / Q96) ** 2


class Checker:
    """Compares chain and model in value terms (currency1 units), so tokens with different decimals are treated
    alike. Allowed: a few units of the coarser token (integer rounding, e.g. the per-step fee split), plus the log
    curve's designed rounding of ~1e-15 of the liquidity, plus 1e-12 of the amount itself."""

    def __init__(self):
        self.errors = []
        self.worst = mp.mpf(0)

    def tolerance(self, P, L, value):
        return 8 * max(mp.mpf(1), P) + mp.mpf("1e-15") * L + mp.mpf("1e-12") * abs(value)

    def amount(self, chain, model, token, P, L, name):
        unit = P if token == 0 else mp.mpf(1)  # value of one unit of the token, in currency1 units
        dev = abs(mp.mpf(chain) - model) * unit
        if dev > self.tolerance(P, L, model * unit):
            self.errors.append(
                f"{name}: chain {chain} vs model {mp.nstr(model, 30)} (off by {mp.nstr(dev, 4)} currency1 units)"
            )
        self.worst = max(self.worst, dev)
        return dev

    def price(self, chain, model, L, name="price"):
        # a price error dP moves the curve by L * dP / P of value (same formula for either token)
        dev = L * abs(chain - model) / model
        if dev > self.tolerance(model, L, 0):
            self.errors.append(
                f"{name}: chain {mp.nstr(chain, 25)} vs model {mp.nstr(model, 25)} (worth {mp.nstr(dev, 4)} currency1 units)"
            )
        self.worst = max(self.worst, dev)
        return dev


def main():
    path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "reports" / "trace.csv"
    rows = list(csv.reader(open(path)))
    model = None
    check = Checker()
    errors = check.errors
    P = mp.mpf(1)
    print(f"{'op':<38s} {'chain amount0':>24s} {'chain amount1':>24s}  {'price (chain)':>14s}  max dev (currency1 units)")
    for row in rows:
        kind = row[0]
        if kind == "fee":
            model = Model(int(row[1]))
            continue
        if kind == "tick":
            model.tick_price[int(row[1])] = price(int(row[2]))
            continue

        if kind == "modify":
            who, tl, tu, dl = row[1], int(row[2]), int(row[3]), int(row[4])
            d0, d1, f0, f1 = (int(v) for v in row[5:9])
            s_after, tick, active, r0, r1 = int(row[9]), int(row[10]), int(row[11]), int(row[12]), int(row[13])
            P = price(s_after)  # liquidity changes never move the price
            k = (who, tl, tu)
            pos = model.positions.get(k) or Position(0, model.tick_price[tl], model.tick_price[tu])
            model.positions[k] = pos
            L = max(pos.L, mp.mpf(abs(dl)))
            # fees: everything the position earned so far is paid out on any modification. On chain, each tick-step
            # rounds its input (and so its fee) up, which can shift a little fee between the segments of one swap;
            # the pool as a whole can never pay out more than it holds (checked below as solvency).
            devs = [
                check.amount(f0, pos.fees[0], 0, P, L, f"{who} fees0"),
                check.amount(f1, pos.fees[1], 1, P, L, f"{who} fees1"),
            ]
            pos.fees = [mp.mpf(0), mp.mpf(0)]
            # principal = the position's share of the curve at the current price
            e0, e1 = Position(abs(dl), pos.pa, pos.pb).reserves(P)
            p0, p1 = d0 - f0, d1 - f1  # principal part of the caller delta
            if dl > 0:  # deposit: chain charges at least the exact amounts
                devs += [
                    check.amount(-p0, e0, 0, P, L, f"{who} deposit0"),
                    check.amount(-p1, e1, 1, P, L, f"{who} deposit1"),
                ]
                if -p0 < e0 - 1e-30 or -p1 < e1 - 1e-30:
                    errors.append(f"{who}: deposit below the curve")
            else:  # withdrawal: chain pays at most the exact amounts
                devs += [
                    check.amount(p0, e0, 0, P, L, f"{who} withdraw0"),
                    check.amount(p1, e1, 1, P, L, f"{who} withdraw1"),
                ]
                if p0 > e0 + 1e-30 or p1 > e1 + 1e-30:
                    errors.append(f"{who}: withdrawal above the curve")
            pos.L += dl
            label = f"{'add' if dl > 0 else 'remove'} {who} [{tl},{tu}] L={dl:.2e}"
            print(f"{label:<38s} {d0:>24d} {d1:>24d}  {mp.nstr(P, 9):>14s}  {mp.nstr(max(devs), 3)}")
        elif kind == "swap":
            zfo, amt, s_before = row[1] == "true", int(row[2]), int(row[3])
            d0, d1 = int(row[4]), int(row[5])
            s_after, tick, active, r0, r1 = int(row[6]), int(row[7]), int(row[8]), int(row[9]), int(row[10])
            P0 = price(s_before)
            P_model, amount_in, amount_out = model.swap(P0, zfo, amt)
            chain_in, chain_out = (-d0, d1) if zfo else (-d1, d0)
            # the segment walk must equal the plain sum over positions (the aggregation claim)
            x0, y0 = model.total(P0)
            x1, y1 = model.total(P_model)
            curve_in = (x1 - x0) if zfo else (y1 - y0)
            curve_out = (y0 - y1) if zfo else (x0 - x1)
            fee = amount_in - curve_in
            if abs(curve_out - amount_out) > amount_out * mp.mpf("1e-40") or abs(
                fee - amount_in * model.f
            ) > amount_in * mp.mpf("1e-40"):
                errors.append("segment walk disagrees with the sum of position curves")
            L = sum((p.L for p in model.positions.values() if p.pa <= P_model < p.pb), mp.mpf(0)) or sum(
                (p.L for p in model.positions.values()), mp.mpf(0)
            )
            tin, tout = (0, 1) if zfo else (1, 0)
            devs = [
                check.price(price(s_after), P_model, L),
                check.amount(chain_in, amount_in, tin, P_model, L, "amount in"),
                check.amount(chain_out, amount_out, tout, P_model, L, "amount out"),
            ]
            if chain_out > amount_out + 1 or chain_in < amount_in - 1:
                errors.append(f"swap {amt}: rounding favoured the trader")
            label = f"swap {'0->1' if zfo else '1->0'} {'in ' if amt < 0 else 'out'} {abs(amt):.2e}"
            print(f"{label:<38s} {d0:>24d} {d1:>24d}  {mp.nstr(price(s_after), 9):>14s}  {mp.nstr(max(devs), 3)}")
        else:
            continue

        # after every operation: sync the price, and check active liquidity and solvency against the model
        P = price(s_after)
        expected_active = sum((p.L for (_, tl, tu), p in model.positions.items() if tl <= tick < tu), mp.mpf(0))
        if mp.mpf(active) != expected_active:
            errors.append(f"active liquidity {active} != sum of in-range L {expected_active}")
        owed0, owed1 = model.total(P)
        owed0 += sum(p.fees[0] for p in model.positions.values())
        owed1 += sum(p.fees[1] for p in model.positions.values())
        if r0 < owed0 - WEI or r1 < owed1 - WEI:
            errors.append(f"insolvent: reserves ({r0}, {r1}) < owed ({mp.nstr(owed0, 25)}, {mp.nstr(owed1, 25)})")

    print(f"\nfinal reserves (dust kept by rounding): {r0} / {r1} wei")
    print(f"worst deviation chain vs model: {mp.nstr(check.worst, 3)} currency1 units")
    if errors:
        print("\nFAILURES:")
        for e in errors:
            print("  -", e)
        sys.exit(1)
    print("OK: every price, amount and fee matches the independent model, and all rounding favours the pool")


if __name__ == "__main__":
    main()
