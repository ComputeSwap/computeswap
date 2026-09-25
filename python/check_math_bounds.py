"""Measure the true error of solady's lnWad / expWad on the samples dumped by test/MathBounds.t.sol.

LogCurveMath widens every ln/exp result by an error allowance so that rounding always favours the pool. This script
checks those allowances against reality using 60-digit arithmetic:

    forge test --match-contract MathBoundsDump
    python python/check_math_bounds.py

Errors are in "wad units" (1e-18).
"""
import csv
import pathlib
import sys

import mpmath as mp

mp.mp.dps = 60
ROOT = pathlib.Path(__file__).resolve().parents[1]
WAD = mp.mpf(10) ** 18

# Allowances used by src/libraries/LogCurveMath.sol (keep in sync).
LN_ERR = 4  # wad units, per lnWad call
EXP_ABS_ERR = 4  # wad units
EXP_REL_ERR_SHIFT = 60  # plus g >> 60


def check_ln():
    worst = mp.mpf(0)
    n = 0
    with open(ROOT / "reports" / "lnwad_samples.csv") as f:
        for row in csv.DictReader(f):
            x, got = int(row["x"]), int(row["lnWad"])
            worst = max(worst, abs(got - mp.log(mp.mpf(x) / WAD) * WAD))
            n += 1
    ok = worst <= LN_ERR
    print(f"lnWad : {n} samples, worst |error| {mp.nstr(worst, 4)} wad units; allowance {LN_ERR} -> {'OK' if ok else 'VIOLATED'}")
    return ok


def check_exp():
    worst_small = mp.mpf(0)  # absolute error for outputs up to 100 WAD (the swap range)
    worst_rel = mp.mpf(0)  # relative error for larger outputs
    violations = n = 0
    with open(ROOT / "reports" / "expwad_samples.csv") as f:
        for row in csv.DictReader(f):
            z, g = int(row["z"]), int(row["expWad"])
            exact = mp.exp(mp.mpf(z) / WAD) * WAD
            if exact <= 100 * WAD:
                worst_small = max(worst_small, abs(g - exact))
            else:
                worst_rel = max(worst_rel, abs(g - exact) / exact)
            allowance = (g >> EXP_REL_ERR_SHIFT) + EXP_ABS_ERR
            # LogCurveMath uses g - allowance as a lower bound and g + allowance as an upper bound on e^z
            if g - allowance > exact or g + allowance < exact:
                violations += 1
            n += 1
    print(
        f"expWad: {n} samples, worst |error| {mp.nstr(worst_small, 4)} wad units up to 100 WAD, "
        f"worst relative error {mp.nstr(worst_rel, 4)} above; allowance (g >> {EXP_REL_ERR_SHIFT}) + {EXP_ABS_ERR} -> "
        f"{'OK' if violations == 0 else f'VIOLATED in {violations} samples'}"
    )
    return violations == 0


if __name__ == "__main__":
    ok = check_ln() & check_exp()
    sys.exit(0 if ok else 1)
