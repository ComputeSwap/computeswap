"""Exact verification of a curve's directed rounding (rules R1-R5 in src/interfaces/ICurve.sol).

Reads the samples written by test/CurveDump.t.sol and compares every on-chain result with the exact real-valued
answer, computed with 150 significant digits:

    forge test --match-contract CurveDump
    python python/check_curve.py

To check a new curve, add its unit reserves xu(s), yu(s) and their inverses (as functions of sqrtPriceX96) to CURVES
and a CurveDump instance in test/CurveDump.t.sol.
"""
import csv
import pathlib
import sys

import mpmath as mp

mp.mp.dps = 150
ROOT = pathlib.Path(__file__).resolve().parents[1]
Q96 = mp.mpf(2) ** 96
UINT160_MAX = 2**160 - 1
E18 = mp.mpf(10) ** -18


def price(s):
    return (mp.mpf(s) / Q96) ** 2


def sqrt_price(P):
    return Q96 * mp.sqrt(P)


# --- curves: unit reserves as functions of the sqrt price, and their inverses (None = no such price) ---------------

def log_xu(s):
    return 1 / price(s)


def log_yu(s):
    return mp.log(price(s))


def log_from_x(X):
    return Q96 / mp.sqrt(X) if X > 0 else None


def log_from_y(Y):
    return Q96 * mp.exp(Y / 2)


CURVES = {
    "logcurve": (log_xu, log_yu, log_from_x, log_from_y),
}


def check_amounts(name, xu, yu):
    bad = n = 0
    worst = {"amount0": mp.mpf(0), "amount1": mp.mpf(0)}
    with open(ROOT / "reports" / f"{name}_amounts.csv") as f:
        for row in csv.DictReader(f):
            a, b, l = int(row["sqrtA"]), int(row["sqrtB"]), int(row["liquidity"])
            if a > b:
                a, b = b, a
            exact0 = l * (xu(a) - xu(b))
            exact1 = l * (yu(b) - yu(a))
            up0, down0 = int(row["amount0Up"]), int(row["amount0Down"])
            up1, down1 = int(row["amount1Up"]), int(row["amount1Down"])
            if not (up0 >= exact0 >= down0 and up1 >= exact1 >= down1):
                bad += 1
                if bad <= 5:
                    print("  R1 violated:", row, mp.nstr(exact0, 30), mp.nstr(exact1, 30))
            unit = l * E18 + 1  # rounding measured against (position size * 1e-18 + 1 wei)
            worst["amount0"] = max(worst["amount0"], (up0 - down0) / unit)
            worst["amount1"] = max(worst["amount1"], (up1 - down1) / unit)
            n += 1
    print(f"  amounts: {n} samples, R1 violations: {bad}; worst up-down gap "
          f"{mp.nstr(worst['amount0'], 3)} / {mp.nstr(worst['amount1'], 3)} x (L * 1e-18 + 1 wei)")
    return bad == 0


def check_next(name, xu, yu, from_x, from_y):
    names = {0: "R2 currency0 in ", 1: "R3 currency0 out", 2: "R4 currency1 in ", 3: "R5 currency1 out"}
    bad = {k: 0 for k in names}
    n = {k: 0 for k in names}
    with open(ROOT / "reports" / f"{name}_next.csv") as f:
        for row in csv.DictReader(f):
            kind = int(row["kind"])
            s, l, amt, nxt = int(row["sqrtP"]), int(row["liquidity"]), int(row["amount"]), int(row["next"])
            d = mp.mpf(amt) / l
            if kind == 0:  # price falls; result must be >= exact
                exact = from_x(xu(s) + d)
                ok = exact is not None and s >= nxt >= exact
            elif kind == 1:  # price rises; result must be >= exact
                exact = from_x(xu(s) - d)
                ok = exact is not None and nxt >= exact and nxt >= s
            elif kind == 2:  # price rises; result must be <= exact
                exact = from_y(yu(s) + d)
                ok = exact is not None and (s <= nxt <= exact or (nxt == UINT160_MAX and exact > UINT160_MAX))
            else:  # price falls; result must be <= exact
                exact = from_y(yu(s) - d)
                ok = exact is not None and nxt <= exact and nxt <= s
            n[kind] += 1
            if not ok:
                bad[kind] += 1
                if bad[kind] <= 3:
                    print(f"  {names[kind]} violated: s={s} L={l} amount={amt} next={nxt} exact={exact}")
    for k in names:
        print(f"  {names[k]}: {n[k]:5d} samples, violations {bad[k]}")
    return sum(bad.values()) == 0


if __name__ == "__main__":
    selected = sys.argv[1:] or list(CURVES)
    ok = True
    for name in selected:
        xu, yu, from_x, from_y = CURVES[name]
        print(name)
        ok &= check_amounts(name, xu, yu)
        ok &= check_next(name, xu, yu, from_x, from_y)
    print("ALL ROUNDING RULES HOLD" if ok else "ROUNDING RULE VIOLATIONS FOUND")
    sys.exit(0 if ok else 1)
