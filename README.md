# 🦞 CLAWD DCA Engine

Permissionless dollar-cost-averaging into [CLAWD](https://basescan.org/token/0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07) on Base. Deposit USDC, pick a cadence, and let community keepers run your swaps via Uniswap V3.

**Live URL:** https://bafybeigxl4zsyrgicg7qa3upcsmxg2tbyr4dn4sljxeantr6ebxqv2hsf4.ipfs.community.bgipfs.com/
- **Contract:** [`0x8c81CAeCA48f521Df24B65F1C22c11150830F088`](https://basescan.org/address/0x8c81CAeCA48f521Df24B65F1C22c11150830F088) (Base, verified)
- **Built with:** Scaffold-ETH 2 (Foundry flavor) — Next.js / RainbowKit / Wagmi / DaisyUI
- **Delivered by:** clawdbotatg via [LeftClaw Services](https://leftclaw.services) job #99

See [`DEPLOYMENT.md`](./DEPLOYMENT.md) for the full deployment manifest (CID, contract addresses, Uniswap V3 routing).

## How it works

1. **Create a position.** Approve USDC, deposit a total amount, and pick an interval (every 3 hours, daily, weekly, or custom).
2. **Keepers execute.** Anyone can call `executeDCA(positionId)` once a position is ripe. They earn 0.39% USDC per swap; the protocol takes 0.10%.
3. **Withdraw any time.** `withdrawCLAWD(positionId)` to pull accrued CLAWD; `closePosition(positionId)` to wind down completely.

The contract:
- Uses Uniswap V3 SwapRouter02 + a configurable USDC→CLAWD path
- Quotes via QuoterV2 with `MAX_SLIPPAGE_BPS = 10%` and a default 3% slippage tolerance per position (adjustable per position)
- Has a 2-step Ownable for admin (pause, fee collection, swap-path updates) and ReentrancyGuard on all writes
- Emits `PositionCreated`, `PositionToppedUp`, `DCAExecuted`, `CLAWDWithdrawn`, `PositionClosed`, `SlippageUpdated`

## Frontend

- `/` Dashboard — your positions, withdraw, top up, close
- `/create` Create a new position with USDC approval flow
- `/keepers` Permissionless execution view (per-position + batch)
- `/stats` All-time deposits, swaps, fees, top keepers (event-derived)

## Local development

```bash
yarn install
cd packages/nextjs && yarn dev
```

To build the static site for IPFS:

```bash
cd packages/nextjs
yarn build
# upload via bgipfs:
npx bgipfs upload config init --apiKey $BGIPFS_TOKEN --nodeUrl https://upload.bgipfs.com
npx bgipfs upload packages/nextjs/out
```

## Repo layout

- `packages/foundry/` — CLAWDdca.sol + tests + deploy script
- `packages/nextjs/` — Next.js dApp (`app/page.tsx`, `app/create`, `app/keepers`, `app/stats`)
- `audits/` — Stage 3 audit report

## Disclaimer

This project is community-built using LeftClaw Services (beta). Not affiliated with the CLAWD core team or Uniswap. Verify the contract on Basescan before sending USDC. **Do your own research.**
