import { formatUnits } from "viem";

// Contract constants — must match CLAWDdca.sol on Base mainnet (v2 verified
// 0xa16095e72936aD6DAb012ec1b95222F6FCB5f5C2). Hardcoded here so we don't
// pay an extra eth_call to read immutables on every page mount; we re-derive
// human-readable times client-side from `EPOCH_DURATION` (3 hours).
export const EPOCH_DURATION_SECONDS = 3 * 60 * 60; // 3 hours
export const KEEPER_FEE_BPS = 20n; // 0.20% (v2)
export const PROTOCOL_FEE_BPS = 10n; // 0.10%
export const BURN_FEE_BPS = 20n; // 0.20% — accumulates for permissionless executeBurn()
export const BPS_DENOMINATOR = 10_000n;
export const DEFAULT_SLIPPAGE_BPS = 300n; // 3.00%
export const MAX_SLIPPAGE_BPS = 1_000n; // 10.00%

// v2 contract (feature job #190 — fee structure update with burn mechanism)
export const CLAWDDCA_ADDRESS = "0xa16095e72936aD6DAb012ec1b95222F6FCB5f5C2" as const;
export const USDC_ADDRESS = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as const;
export const CLAWD_ADDRESS = "0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07" as const;

export const USDC_DECIMALS = 6;
export const CLAWD_DECIMALS = 18;

// Block where CLAWDdca v2 was deployed on Base — used as `fromBlock` for event
// queries so we don't scan all of Base history every page load.
export const DEPLOYED_ON_BLOCK = 46170369n;

export type IntervalPreset = {
  key: "3h" | "daily" | "weekly" | "custom";
  label: string;
  description: string;
  intervalInEpochs: number; // 1 epoch = 3 hours
};

export const INTERVAL_PRESETS: IntervalPreset[] = [
  {
    key: "3h",
    label: "Every 3 Hours",
    description: "Aggressive — 8 swaps per day",
    intervalInEpochs: 1,
  },
  {
    key: "daily",
    label: "Daily DCA",
    description: "1 swap per day, the classic",
    intervalInEpochs: 8,
  },
  {
    key: "weekly",
    label: "Weekly Accumulation",
    description: "1 swap per week, slow & steady",
    intervalInEpochs: 56,
  },
  {
    key: "custom",
    label: "Custom",
    description: "Pick any cadence",
    intervalInEpochs: 1,
  },
];

export const intervalLabel = (intervalInEpochs: bigint | number): string => {
  const n = Number(intervalInEpochs);
  if (n === 1) return "Every 3 hrs";
  if (n === 8) return "Daily";
  if (n === 56) return "Weekly";
  const hours = n * 3;
  if (hours % 24 === 0) {
    return `Every ${hours / 24} days`;
  }
  return `Every ${n} epochs (${hours} hrs)`;
};

export const formatUsdc = (raw: bigint | undefined): string => {
  if (raw === undefined) return "—";
  const v = Number(formatUnits(raw, USDC_DECIMALS));
  // Use full 2-decimal display for clarity. Negative values can't happen on chain.
  return v.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
};

export const formatClawd = (raw: bigint | undefined): string => {
  if (raw === undefined) return "—";
  const v = Number(formatUnits(raw, CLAWD_DECIMALS));
  if (v === 0) return "0";
  if (v < 0.0001) return v.toExponential(2);
  if (v < 1) return v.toLocaleString(undefined, { minimumFractionDigits: 4, maximumFractionDigits: 6 });
  return v.toLocaleString(undefined, { minimumFractionDigits: 2, maximumFractionDigits: 4 });
};

export const formatBps = (bps: bigint | number | undefined): string => {
  if (bps === undefined) return "—";
  return `${(Number(bps) / 100).toFixed(2)}%`;
};

export const epochToDate = (currentEpoch: bigint, targetEpoch: bigint): Date => {
  const epochsAhead = Number(targetEpoch - currentEpoch);
  const ms = Date.now() + epochsAhead * EPOCH_DURATION_SECONDS * 1000;
  return new Date(ms);
};

export const formatCountdown = (seconds: number): string => {
  if (seconds <= 0) return "ready now";
  const d = Math.floor(seconds / 86400);
  const h = Math.floor((seconds % 86400) / 3600);
  const m = Math.floor((seconds % 3600) / 60);
  const s = Math.floor(seconds % 60);
  if (d > 0) return `${d}d ${h}h ${m}m`;
  if (h > 0) return `${h}h ${m}m ${s}s`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
};
