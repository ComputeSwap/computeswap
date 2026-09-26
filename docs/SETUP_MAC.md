# Running the project on a Mac

The same local setup as on Windows: a local chain (anvil), the contracts deployed on it, and the page at http://localhost:3000.

## 1. Copy the project folder

Put the whole `Uniswap_hook` folder at **`~/Documents/Uniswap_hook`**, which is Documents in your home folder.

Two ways to move it:
- **Zip it.** On Windows, right-click `Documents\Uniswap_hook` and choose *Send to → Compressed (zipped) folder*. Copy the zip to the Mac by AirDrop, a USB stick or the cloud. Double-click it to unzip, then drag the `Uniswap_hook` folder into Documents.
- **OneDrive.** On the Mac it's under `~/Library/CloudStorage/OneDrive-…/Documents/Uniswap_hook`. Copy it out of OneDrive into `~/Documents` rather than working inside it. Building writes thousands of small files, and OneDrive would try to sync every one.

Check that these are all inside `~/Documents/Uniswap_hook`:

```
LICENSE  README.md  foundry.toml  remappings.txt
docs/  frontend/  lib/  license-mit/  python/  reports/  script/  src/  test/
```

`lib/` matters: it holds the Uniswap v4, solady, forge-std and solmate sources the contracts compile against. The Mac doesn't need `.claude/`, `out/`, `cache/` or `broadcast/`. Foundry recreates the last three.

## 2. Install the tools (once)

Open **Terminal** (Applications → Utilities).

**Foundry** provides `forge`, `anvil` and `cast`. Install it, open a **new** Terminal window, then run `foundryup`:

```bash
curl -L https://foundry.paradigm.xyz | bash
```

```bash
foundryup
```

```bash
forge --version
```

The project was tested with Foundry 1.8.3. Any 1.x version should work.

**Python 3** runs the page's small web server. Check it:

```bash
python3 --version
```

If macOS offers to install the "command line developer tools", accept. That installs Python 3.

Optionally, install `mpmath` for the precision checks in `python/`:

```bash
python3 -m pip install --user mpmath
```

You also need a browser (Chrome or Safari) and internet access, because the page loads ethers.js from a CDN.

## 3. Check the build (once)

```bash
cd ~/Documents/Uniswap_hook
```

```bash
forge test
```

All 43 tests should pass. The first run compiles for a minute or so.

## 4. Run it

Use three Terminal tabs (⌘T), each in the project folder: `cd ~/Documents/Uniswap_hook`.

**Tab 1: the local chain.** Leave it running.

```bash
anvil
```

**Tab 2: deploy the contracts.** Run it once each time you start anvil. It writes the addresses to `frontend/deployments.json`.

```bash
forge script script/DeployLocal.s.sol --rpc-url http://127.0.0.1:8545 --broadcast --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
```

**Tab 3: the page.** Leave it running. The first time, `npm install` downloads the page's dependencies (you need Node.js ≥ 20: `brew install node`).

```bash
cd frontend && npm install && npm run dev
```

Then open **http://localhost:3000**. The deploy script already created the pool; add liquidity to get started. Alice, Bob, Carol and Dave are in the wallet menu.

## Later sessions

- **anvil forgets everything when you stop it** (Ctrl+C or closing the tab). Next time, run tabs 1, 2 and 3 again.
- **To keep the chain between sessions**, start it with a state file instead. anvil saves the chain there when stopped and loads it on the next start. Then skip tab 2, since the contracts are already there:

  ```bash
  anvil --state anvil-state.json
  ```

- **If you deployed to Unichain Sepolia from this folder**, `frontend/deployments.json` points at the testnet. Run tab 2 again to point it back at anvil.
- **For testnet deployment**, follow `docs/DEPLOY_UNICHAIN.md`. Foundry's keystore is per machine, so import your deployer key on the Mac with `cast wallet import deployer --interactive`.

## If something goes wrong

| symptom | fix |
|---|---|
| `command not found: forge` | Open a new Terminal window after installing Foundry, or run `source ~/.zshenv`. |
| `Library not loaded: …libusb…` when running forge | Install Homebrew (brew.sh), then run `brew install libusb`. |
| The page says "Cannot reach the chain … is anvil running?" | Start tab 1, then reload. |
| The page loads but shows no pool, or calls fail | anvil was restarted after deploying: run tab 2 again and reload. |
| `Address already in use` | Another anvil or server is still running. Close it, or find it with `lsof -i :8545` / `lsof -i :3000`. |
| `npm: command not found` | Install Node.js: `brew install node`, then open a new Terminal window. |
| The activity table stays empty on anvil | The page's server indexes anvil in the background; it catches up within a few seconds. If anvil was restarted, delete `frontend/.pglite/` and restart tab 3 so the index starts over. |
