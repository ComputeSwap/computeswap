# Stored: the MIT license

The project is now licensed under the **Business Source License 1.1** (BUSL-1.1), in the same form Uniswap uses for v4-core. The license text is in [`../LICENSE`](../LICENSE), and every Solidity file in `src/`, `test/` and `script/` starts with `// SPDX-License-Identifier: BUSL-1.1`.

This folder keeps the earlier MIT license so you can go back to it.

The BUSL parameters follow Uniswap v4-core:

| parameter | this project | Uniswap v4-core |
|---|---|---|
| Change License | MIT License | MIT License |
| Change Date | 2030-09-26 (four years) | about four years after release |
| Additional Use Grant | None | a list published at an ENS name |

Only the Parameters block may be edited. Covenant 4 of the license forbids changing any other part of the text.

## Bring the MIT license back

From the project folder:

```bash
python license-mit/switch_license.py mit
```

This does three things:
1. Moves the current BUSL text to `license-busl/LICENSE`, so you can undo the switch.
2. Copies `license-mit/LICENSE` to `LICENSE` at the project root.
3. Changes the SPDX line of every Solidity file in `src/`, `test/` and `script/` from `BUSL-1.1` to `MIT`.

After that, update the "License" section of `../README.md`.

To undo the switch:

```bash
python license-mit/switch_license.py busl
```

To do it by hand:
1. Copy `license-mit/LICENSE` over `LICENSE` at the project root.
2. In each `.sol` file under `src/`, `test/` and `script/`, change the first line to `// SPDX-License-Identifier: MIT`.

Leave `lib/` alone. Those libraries keep their own licenses:
- solady: MIT
- forge-std: MIT or Apache-2.0
- v4-core: MIT libraries, plus a BUSL PoolManager that is used only in tests and the local deployment
- solmate: AGPL, test mocks only

## Mixing the two, as Uniswap does

Uniswap puts most of v4-core under BUSL but keeps its interfaces and pure math libraries under MIT, so other projects can build against them. You can do the same here. For example, to let anyone write a curve for the hook:
1. Put this MIT text next to the BUSL one, as `licenses/MIT_LICENSE` and `licenses/BUSL_LICENSE`.
2. Set `src/interfaces/ICurve.sol` back to `// SPDX-License-Identifier: MIT`.
