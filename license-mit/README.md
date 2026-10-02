# license-mit

Archival **MIT** license text (`LICENSE`) and a maintainer script (`switch_license.py`) to change the repo’s root license and SPDX headers in `src/`, `test/`, and `script/`.

Current license for the project is **BUSL-1.1** at the repo root. See [README § License](../README.md#license).

## Switching licenses (maintainers only)

From the repo root:

```bash
python license-mit/switch_license.py mit
```

Copies this folder’s MIT text to `LICENSE`, saves the previous BUSL text under `license-busl/LICENSE`, and sets SPDX to MIT in project Solidity.

```bash
python license-mit/switch_license.py busl
```

Reverts that. Do not run either unless you intend to re-license the whole tree; `lib/` is untouched.
