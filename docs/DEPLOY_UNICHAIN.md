# Putting it on Unichain Sepolia (testnet)

Two things go online:

1. **The contracts.** A Foundry script deploys them to Unichain Sepolia (chain ID 1301). Uniswap already runs v4 there, so you don't deploy Uniswap itself. The script deploys:
   - your curve (`LogCurve`);
   - the hook, at an address whose last bits carry its permissions;
   - the position vault, which creates the weight token;
   - the Dutch auction;
   - a freely mintable test USDC (by default).

   It then creates the ETH/USDC pool on Uniswap's PoolManager.
2. **The web page.** `frontend/` is plain static files with no build step. Upload the folder to any static host. Visitors connect their own browser wallet.

Everything here was rehearsed on a local copy of Unichain Sepolia with Uniswap's real contracts:
- deploy;
- connect a wallet;
- mint test USDC;
- add liquidity 50/50;
- auction the ETH weight;
- buy and sell;
- buy the weight with a second wallet and exercise it;
- cancel, merge and withdraw.

## What is already on Unichain Sepolia

These addresses were checked on-chain.

| | |
|---|---|
| Chain ID | 1301 |
| Public RPC | `https://sepolia.unichain.org` (rate-limited, not for production) |
| Explorers | https://sepolia.uniscan.xyz and https://unichain-sepolia.blockscout.com |
| Uniswap v4 PoolManager | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| Uniswap PoolSwapTest router | `0x9140a78c1A137c7fF1c151EC8231272aF78a99A4` |
| Circle test USDC | `0x31d0220469e10c4E71834a79b1f276d740d3768F` (6 decimals) |
| CREATE2 deployer | `0x4e59b44847b379578588920cA78FbF26c0B4956C` |

Sources:
- [Uniswap v4 deployments](https://docs.uniswap.org/contracts/v4/deployments)
- [Unichain network information](https://developers.uniswap.org/docs/unichain/technical-information/network-information)

## 1. A deployer wallet

Use a **fresh** key for deploying, never one of Anvil's well-known test keys. On Unichain Sepolia, the addresses of those public keys carry delegated "sweeper" code (EIP-7702), so any ETH they receive is taken. The rehearsal lost a test balance exactly that way.

Create a key and store it encrypted in Foundry's keystore. The second command asks for the private key and a password:

```bash
cast wallet new
```

```bash
cast wallet import deployer --interactive
```

Print the deployer's address:

```bash
cast wallet address --account deployer
```

## 2. Test ETH

Send Unichain Sepolia ETH to that address. The [faucets listed by Unichain](https://developers.uniswap.org/docs/unichain/tools/faucets) are:
- **Superchain:** 0.05 ETH per day.
- **QuickNode:** every 12 hours.
- **thirdweb:** every 24 hours.
- **Circle:** test USDC only.

The whole deployment costs less than 0.0001 ETH. It's about 15 million gas at roughly 0.0015 gwei, plus an L1 data fee under 0.00001 ETH. The rest is left for testing.

## 3. Deploy

### GitHub Actions (optional)

Workflow **Deploy Unichain Sepolia** (`.github/workflows/deploy-unichain-sepolia.yml`) runs manually from the Actions tab. Secrets never live in the repo; add them under **Settings → Secrets and variables → Actions** (and optionally gate live deploys with an **Environment** named `unichain-sepolia`):

| Secret | Required when broadcasting | Purpose |
|---|---|---|
| `UNICHAIN_DEPLOYER_PRIVATE_KEY` | yes | Deployer key (`forge script --private-key`) |
| `UNICHAIN_RPC_URL` | no | RPC for simulation and broadcast (defaults to the public Unichain Sepolia URL) |
| `UNICHAIN_APP_RPC` | no | RPC written into `frontend/deployments.json` as `APP_RPC` (use a provider URL with domain allowlisting for the hosted app) |

First run: leave **Broadcast** off to simulate only (no deployer secret needed). Turn **Broadcast** on for a live deploy; download `deployments-unichain-sepolia` from the run artifacts and copy `deployments.json` into `frontend/` before publishing the static site.

### Local deploy

From the project folder, do a dry run first. It simulates everything and sends nothing:

```bash
forge script script/DeployUnichainSepolia.s.sol --rpc-url https://sepolia.unichain.org --account deployer
```

Then deploy for real:

```bash
forge script script/DeployUnichainSepolia.s.sol --rpc-url https://sepolia.unichain.org --account deployer --broadcast
```

The script:
- deploys the contracts;
- creates the pool at **$2,500 per ETH**;
- prints the addresses;
- writes them to `frontend/deployments.json`, replacing the local anvil addresses. Run `script/DeployLocal.s.sol` again to switch back to local.

Optional settings, as environment variables:

| variable | default | meaning |
|---|---|---|
| `INIT_PRICE` | `2500` | starting ETH price in USDC, in whole dollars |
| `USDC` | (deploy test USDC) | e.g. Circle's `0x31d0220469e10c4E71834a79b1f276d740d3768F`. Circle's faucet drips only a few dollars an hour, so the mintable test token is easier for demos. |
| `APP_RPC` | `https://sepolia.unichain.org` | the RPC the web page reads through (see step 6) |

In Git Bash, put them before the command, e.g. `INIT_PRICE=3000 forge script …`. In PowerShell, set them first with `$env:INIT_PRICE="3000"`.

**The starting price matters on a testnet.** Test ETH is scarce, and at $1 per ETH a $100 position would need 50 ETH. At $2,500 it needs about 0.02 ETH plus 50 USDC.

## 4. Check it on the explorer

Open `https://sepolia.uniscan.xyz/address/<hook address>` with the hook address from the script's output. Its transactions include the pool creation.

## 5. Publish the source (optional, recommended)

Verification lets anyone read the contracts on the explorer. Blockscout needs no API key. Take the addresses from `frontend/deployments.json` and run the command for each contract. The hook needs its two constructor arguments, the PoolManager and the curve:

```bash
forge verify-contract <hook> src/ConcentratedCurveHook.sol:ConcentratedCurveHook --chain 1301 --verifier blockscout --verifier-url https://unichain-sepolia.blockscout.com/api/ --constructor-args $(cast abi-encode "constructor(address,address)" 0x00B036B58a818B1BC34d502D3fE730Db729e62AC <curve>)
```

The others follow the same pattern:

| contract | source | constructor arguments |
|---|---|---|
| `<curve>` | `src/curves/LogCurve.sol:LogCurve` | none |
| `<vault>` | `src/weights/WeightVault.sol:WeightVault` | `constructor(address,uint24)` with `<hook> 100` |
| `<weights>` | `src/weights/WeightToken.sol:WeightToken` | none |
| `<auction>` | `src/weights/WeightAuction.sol:WeightAuction` | `constructor(address weights, address treasury)` — treasury receives the 5% seller premium fee |
| `<usdc>` | `script/TestUSDC.sol:TestUSDC` | none |

These are Foundry's standard verification commands. Unlike the deployment, they couldn't be rehearsed, because they need the live explorer.

## 6. Put the web page online

Before uploading, try it from your machine. It should show "Unichain Sepolia" and a **Connect wallet** button:

```bash
python frontend/serve.py
```

Then upload the `frontend/` folder: `index.html`, `app.js`, `chain.js`, `curve.js`, `charts.js`, `style.css` and `deployments.json`. `serve.py` isn't needed online. Any static host works:
- **Netlify or Cloudflare Pages:** create a site and drag the `frontend` folder onto the upload area.
- **Vercel:** run `npx vercel frontend` and follow the prompts.
- **GitHub Pages:** it serves the repository root or `/docs` only, so publish `frontend/` with a small Pages workflow, or copy its files to a branch's root.
- **IPFS:** upload the folder to a pinning service. The page is fully static and uses relative paths, so it works from a gateway.

The page loads ethers.js from the jsdelivr CDN and talks to the chain from the visitor's browser. There's no server to run.

**RPC limits.** The public RPC is rate-limited, and the page polls it every few seconds per visitor. For more than a handful of testers:
1. Create a free Unichain Sepolia endpoint at a provider such as Alchemy or QuickNode.
2. Redeploy with `APP_RPC=<that URL>`, or edit `rpc` in `deployments.json`.
3. Restrict the key to your site's domain. It's visible in the page.

## 7. Using it

Testers need:
- Unichain Sepolia ETH from a faucet;
- a browser wallet such as MetaMask or Rabby. **Connect wallet** adds the network to the wallet if it's missing.

With the default test token, **+10,000 test USDC** mints USDC directly. With Circle's USDC, testers use Circle's faucet instead.

Differences from the local version:
- **Real time.** There are no clock buttons. Auctions fall, the price oracle settles (about 30 minutes after a big move) and weights expire (5 days) in real time.
- **Explorer links.** Every confirmed transaction's message has a **view** link to it on Uniscan.
- **Shared pool.** Everyone uses the same pool. Anyone can trade in it and create positions, but every pool of this hook runs the log curve.

## Not for mainnet

These contracts have not been audited. The license is BUSL-1.1 (see `LICENSE`): production use needs the licensor's permission until the change date.
