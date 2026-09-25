"""Switches this project between BUSL-1.1 (current) and MIT (stored in this folder).

    python license-mit/switch_license.py mit    # BUSL-1.1 -> MIT
    python license-mit/switch_license.py busl   # MIT -> BUSL-1.1 (undo)

It swaps the root LICENSE file (the one it replaces is kept, so the switch can be undone) and rewrites the
`// SPDX-License-Identifier:` line of every Solidity file in src/, test/ and script/. lib/ is never touched: those
libraries keep their own licenses.
"""
import pathlib
import shutil
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
IDS = {"mit": "MIT", "busl": "BUSL-1.1"}
STORE = {"mit": ROOT / "license-mit" / "LICENSE", "busl": ROOT / "license-busl" / "LICENSE"}


def main(target):
    other = "busl" if target == "mit" else "mit"
    if not STORE[target].exists():
        sys.exit(f"{STORE[target].relative_to(ROOT)} not found: nothing to switch to")
    # keep the license being replaced, then install the requested one at the root
    STORE[other].parent.mkdir(exist_ok=True)
    shutil.copyfile(ROOT / "LICENSE", STORE[other])
    shutil.copyfile(STORE[target], ROOT / "LICENSE")

    changed = 0
    for folder in ("src", "test", "script"):
        for path in (ROOT / folder).rglob("*.sol"):
            text = path.read_text(encoding="utf-8")
            new = text.replace(f"SPDX-License-Identifier: {IDS[other]}", f"SPDX-License-Identifier: {IDS[target]}", 1)
            if new != text:
                path.write_text(new, encoding="utf-8")
                changed += 1
    print(f"LICENSE is now {IDS[target]}; {changed} Solidity headers switched. Update the License section of README.md.")


if __name__ == "__main__":
    if len(sys.argv) != 2 or sys.argv[1] not in IDS:
        sys.exit(__doc__)
    main(sys.argv[1])
