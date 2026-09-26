# Running the project on a Mac

Local setup: **anvil**, deploy with Foundry, then the **Next.js** app at http://localhost:3000.

## 1. Get the project

Clone or copy the repo to a normal folder on disk (for example `~/Projects/ComputeSwap`). Avoid building inside cloud-synced folders (OneDrive, iCloud Drive): Foundry writes thousands of files under `out/`, `cache/`, and `broadcast/`.

You should have at least:

```
LICENSE  README.md  foundry.toml  remappings.txt
docs/  frontend/  lib/  license-mit/  python/  script/  src/  test/
```

`lib/` holds vendored Uniswap v4, solady, forge-std, and solmate. You do not need committed `out/`, `cache/`, or `broadcast/`; Foundry recreates them.

## 2. Install the tools (once)

Open **Terminal** (Applications → Utilities).

**Foundry** (`forge`, `anvil`, `cast`):

```bash
curl -L https://foundry.paradigm.xyz | bash
```

```bash
foundryup
```

```bash
forge --version
```

Tested with Foundry 1.8.3; any 1.x should work.

**Node.js ≥ 20** for the frontend (`brew install node` if needed).

**Python 3** is optional, for high-precision checks in `python/`:

```bash
python3 -m pip install --user mpmath
```

## 3. Check the build (once)

```bash
cd ~/Projects/ComputeSwap
```

```bash
forge test
```

All tests should pass. The first run compiles for a minute or so.

## 4. Run it

Use three Terminal tabs (⌘T), each in the project folder.

**Tab 1: the local chain.** Leave it running.

```bash
anvil
```

**Tab 2: deploy the contracts.** Run once each time you start a fresh anvil. Writes addresses to `frontend/deployments.json`.

```bash
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

**Tab 3: the page.** Leave it running.

```bash
cd frontend && npm install && npm run dev
```

Open **http://localhost:3000**. The deploy script creates the pool; add liquidity to get started. Alice, Bob, Carol, and Dave are in the wallet menu.

## Later sessions

- **anvil forgets everything when you stop it.** Next time, run tabs 1, 2, and 3 again.
- **Persist chain state** between sessions:

  ```bash
  anvil --state anvil-state.json
  ```

  Then skip tab 2 if contracts are already deployed.

- **If `frontend/deployments.json` points at Unichain Sepolia**, run tab 2 again to switch back to local anvil.
- **Testnet deploy:** [docs/DEPLOY_UNICHAIN.md](DEPLOY_UNICHAIN.md). Import your deployer key on this machine with `cast wallet import deployer --interactive`.

## If something goes wrong

| symptom | fix |
|---|---|
| `command not found: forge` | Open a new Terminal window after installing Foundry, or run `source ~/.zshenv`. |
| `Library not loaded: …libusb…` when running forge | Install Homebrew (brew.sh), then `brew install libusb`. |
| The page says it cannot reach the chain | Start tab 1, then reload. |
| The page loads but shows no pool, or calls fail | anvil was restarted after deploy: run tab 2 again and reload. |
| `Address already in use` | Close the other process, or `lsof -i :8545` / `lsof -i :3000`. |
| `npm: command not found` | `brew install node`, then open a new Terminal window. |
| The activity table stays empty on anvil | The server indexes in the background; wait a few seconds. After anvil restart, delete `frontend/.pglite/` and restart tab 3. |
