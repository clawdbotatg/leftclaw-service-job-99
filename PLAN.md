# Feature Job 190 — Fee Structure v2

## Scope
Client asked for a fee restructure on the CLAWDdca contract (job 99, live on Base):
- Keeper: 39 bps → 20 bps
- Protocol: 30 bps → 10 bps
- Burn (new): 20 bps — accrues to `burnFeeBalance`, permissionless `executeBurn()` swaps USDC→CLAWD→0xdead

Contract is NOT upgradeable; this requires a new v2 deployment.
Existing v1 positions (0x8c81...0088) wind down naturally.

## Changes

1. **CLAWDdca.sol** — update constants, add `burnFeeBalance`, update `_executeDCA`, add `executeBurn()`, update events
2. **CLAWDdca.t.sol** — update fee references, add burn tests
3. **DeployCLAWDdca.s.sol** — update comment for v2
4. **utils/dca.ts** — update fee constants, add BURN_FEE_BPS, update contract address + deploy block after deploy
5. **Keepers.tsx** — update fee description, add executeBurn card
6. **Stats.tsx** — add BurnExecuted event tracking, add CLAWD burned stat

## Deploy
`yarn deploy --file DeployCLAWDdca.s.sol --network base` with PRIVATE_KEY in env.
Owner = 0x8d6FB6C5f77155FEF58629325ad62E295329e22D (job client, same as v1).
