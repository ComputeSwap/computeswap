# Vendored from https://github.com/1inch/aqua

Commit `ef24220ed9647555727b06867bf509cd6959d84b` (main, 2026-09-17). Unmodified copies of `src/Aqua.sol`, `src/AquaApp.sol`,
`src/interfaces/IAqua.sol` and `src/libs/Balance.sol` and `examples/apps/interfaces/IXYCSwapCallback.sol`, under the Degensoft Aqua Source License 1.1
(see LICENSE and LICENSES/). Aqua — © Degensoft Ltd 2025.

Only the registry (`Aqua`), the app base contract (`AquaApp`) and the interface are needed here:
`Aqua` for tests and local deployments, `AquaApp`/`IAqua` by `src/aqua/`. On live chains the canonical
registry is `0x1111113ccf1426a8e30e2bff5e005d929bf6a90a` on every supported network.
