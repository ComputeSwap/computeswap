# Putting it on Unichain Sepolia (testnet)

Two things go online:

1. **The contracts.** A Foundry script deploys them to Unichain Sepolia (chain ID 1301). Uniswap already runs v4 there, so you don't deploy Uniswap itself. The script deploys:
   - your curve (`LogCurve`);
   - the hook, at an address whose last bits carry its permissions;
   - the position vault, which creates the weight token;
   - the Dutch auction;
   - a freely mintable test USDC (by default).

   It then creates the ETH/USDC pool on Uniswap's PoolManager.
2. **The web page.** `frontend/` is a Next.js app with a small server side: it indexes the pool's events into Postgres and serves the activity table and the shared pool state to every visitor from there. Host it on Vercel (step 6). Visitors connect their own browser wallet.

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

First run: leave **Broadcast** off to simulate only (no deployer secret needed). Turn **Broadcast** on for a live deploy; download `deployments-unichain-sepolia` from the run artifacts, copy `deployments.json` into `frontend/` and commit it: Vercel builds the app from the repository.

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

Before deploying, try it from your machine. It should show "Unichain Sepolia" and a **Connect wallet** button:

```bash
cd frontend && npm install && npm run dev
```

Without a `DATABASE_URL`, the server keeps its index in an embedded database under `frontend/.pglite/`. With the public Unichain RPC it backfills all activity since the deploy in a few seconds (set `INDEXER_LOG_CHUNK=5000` in `frontend/.env.local`; the public RPC allows up to 10,000 blocks per `eth_getLogs`).

### Vercel

1. **Import the repository** at vercel.com/new and set **Root Directory** to `frontend`. Vercel detects Next.js.
2. **Add a Postgres database:** in the project's **Storage** tab, create a **Neon** database (free tier). Vercel sets `DATABASE_URL` on the project. The tables are created on first use.
3. **Environment variables** (Settings → Environment Variables; see `frontend/.env.example`):

   | Variable | Purpose |
   |---|---|
   | `INDEXER_RPC_URL` | The RPC the server indexes and reads the pool state through. It is never sent to the browser, so a plain provider key (no domain allowlist) works. Leave unset to use `rpc` from `deployments.json`. |
   | `INDEXER_LOG_CHUNK` | Blocks per `eth_getLogs` call. **10** for an Alchemy free-tier key (its limit), up to `10000` for the public Unichain RPC. |
   | `CRON_SECRET` | Any random string. Vercel sends it with cron calls, and `/api/sync` rejects other callers. |
   | `ALCHEMY_WEBHOOK_SIGNING_KEY` | Optional, see below. |

4. **Deploy.** Then open `https://<your-app>/api/sync` once with `?key=<CRON_SECRET>` to start the backfill, or wait for the cron.

**How the index stays current.** There is no long-running process. `/api/sync` indexes a bounded number of blocks per call (40 seconds' worth at most, one `eth_getLogs` at a time with a pause between them, so a free-tier key is never rate-limited) and stores its cursor in the database. It is called three ways:

- **Cron.** `frontend/vercel.json` schedules `/api/sync` every minute. Vercel's Hobby plan only allows daily crons: change the schedule to `0 0 * * *` there, and rely on the next two.
- **The page itself.** When someone loads or watches the page and the index is more than a few seconds old, the history request triggers one sync step after it responds. A visited page keeps itself current on any plan.
- **Alchemy webhook (optional, push).** In the Alchemy dashboard, create an **Address Activity** webhook for the hook, vault and auction addresses on Unichain Sepolia, pointing at `https://<your-app>/api/webhook`, and set its signing key as `ALCHEMY_WEBHOOK_SIGNING_KEY`. The app then indexes each new transaction within seconds of it landing, without polling.

With an Alchemy free-tier key, the first backfill of the ~20k blocks since deploy takes about ten minutes of cron calls (10 blocks per call, 75 compute units each). Optional `historyStartBlock` in `deployments.json` skips older blocks if you do not need activity from deploy time.

**RPC use.** Each visitor's browser now only reads its own wallet's balances and weights and sends transactions. Positions, auctions and the price are read once per block by the server (`/api/state`, cached at the edge for two seconds) and shared by every visitor. The `rpc` in `deployments.json` is still what the browser uses for those wallet reads and for adding the network to the wallet, so a provider URL with a domain allowlist is still recommended there for public sites (`APP_RPC` at deploy time).

## 7. Using it

Testers need:
- Unichain Sepolia ETH from a faucet;
- a browser wallet such as MetaMask or Rabby. **Connect wallet** adds the network to the wallet if it's missing.

With the default test token, **+10,000 test USDC** mints USDC directly. With Circle's USDC, testers use Circle's faucet instead.

Differences from the local version:
- **Real time.** Auctions fall, the price oracle settles (about 30 minutes after a big move) and weights expire on the schedule you chose when splitting (15 minutes by default in the app).
- **Explorer links.** Every confirmed transaction's message has a **view** link to it on Uniscan.
- **Shared pool.** Everyone uses the same pool. Anyone can trade in it and create positions, but every pool of this hook runs the log curve.

## Not for mainnet

These contracts have not been audited. The license is BUSL-1.1 (see `LICENSE`): production use needs the licensor's permission until the change date.
