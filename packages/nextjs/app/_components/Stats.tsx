"use client";

import { useMemo } from "react";
import { Address as AddressComp } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { base } from "viem/chains";
import { useScaffoldEventHistory } from "~~/hooks/scaffold-eth";
import { DEPLOYED_ON_BLOCK, formatClawd, formatUsdc } from "~~/utils/dca";

const StatsPage: NextPage = () => {
  const { data: createdEvents, isLoading: createdLoading } = useScaffoldEventHistory({
    contractName: "CLAWDdca",
    eventName: "PositionCreated",
    fromBlock: DEPLOYED_ON_BLOCK,
    watch: true,
  });
  const { data: executedEvents, isLoading: executedLoading } = useScaffoldEventHistory({
    contractName: "CLAWDdca",
    eventName: "DCAExecuted",
    fromBlock: DEPLOYED_ON_BLOCK,
    watch: true,
  });
  const { data: closedEvents } = useScaffoldEventHistory({
    contractName: "CLAWDdca",
    eventName: "PositionClosed",
    fromBlock: DEPLOYED_ON_BLOCK,
    watch: true,
  });

  const { data: burnEvents } = useScaffoldEventHistory({
    contractName: "CLAWDdca",
    eventName: "BurnExecuted",
    fromBlock: DEPLOYED_ON_BLOCK,
    watch: true,
  });

  const { totalUsdcSpent, totalClawdReceived, totalKeeperFees, totalProtocolFees, executionCount, keeperLeaderboard } =
    useMemo(() => {
      let totalUsdcSpent = 0n;
      let totalClawdReceived = 0n;
      let totalKeeperFees = 0n;
      let totalProtocolFees = 0n;
      const keeperCounts = new Map<string, number>();
      for (const log of executedEvents ?? []) {
        const a = (log as any).args ?? {};
        if (typeof a.usdcSpent === "bigint") totalUsdcSpent += a.usdcSpent;
        if (typeof a.clawdReceived === "bigint") totalClawdReceived += a.clawdReceived;
        if (typeof a.keeperFee === "bigint") totalKeeperFees += a.keeperFee;
        if (typeof a.protocolFee === "bigint") totalProtocolFees += a.protocolFee;
        const keeper = (a.keeper as string | undefined)?.toLowerCase();
        if (keeper) {
          keeperCounts.set(keeper, (keeperCounts.get(keeper) ?? 0) + 1);
        }
      }
      const keeperLeaderboard = Array.from(keeperCounts.entries())
        .sort((a, b) => b[1] - a[1])
        .slice(0, 10);
      return {
        totalUsdcSpent,
        totalClawdReceived,
        totalKeeperFees,
        totalProtocolFees,
        executionCount: executedEvents?.length ?? 0,
        keeperLeaderboard,
      };
    }, [executedEvents]);

  const { totalClawdBurned, totalUsdcBurned } = useMemo(() => {
    let totalClawdBurned = 0n;
    let totalUsdcBurned = 0n;
    for (const log of burnEvents ?? []) {
      const a = (log as any).args ?? {};
      if (typeof a.clawdBurned === "bigint") totalClawdBurned += a.clawdBurned;
      if (typeof a.usdcBurned === "bigint") totalUsdcBurned += a.usdcBurned;
    }
    return { totalClawdBurned, totalUsdcBurned };
  }, [burnEvents]);

  const positionsCreated = createdEvents?.length ?? 0;
  const positionsClosed = closedEvents?.length ?? 0;
  const activePositions = Math.max(0, positionsCreated - positionsClosed);

  const stillLoading = createdLoading || executedLoading;

  return (
    <div className="max-w-5xl w-full mx-auto px-4 py-8 flex flex-col gap-6">
      <header className="flex flex-col gap-1 text-center">
        <h1 className="text-3xl font-bold my-0">Engine Stats</h1>
        <p className="opacity-80 my-0">All-time activity, derived from on-chain events.</p>
      </header>

      <div className="grid grid-cols-2 sm:grid-cols-3 gap-4">
        <StatCard label="Total USDC swapped" value={`$${formatUsdc(totalUsdcSpent)}`} />
        <StatCard label="Total CLAWD acquired" value={formatClawd(totalClawdReceived)} />
        <StatCard label="Executions" value={executionCount.toString()} />
        <StatCard label="Active positions" value={activePositions.toString()} />
        <StatCard label="Positions created" value={positionsCreated.toString()} />
        <StatCard label="Keeper fees paid" value={`$${formatUsdc(totalKeeperFees)}`} />
        <StatCard label="Protocol fees" value={`$${formatUsdc(totalProtocolFees)}`} />
        <StatCard label="USDC burned (fees)" value={`$${formatUsdc(totalUsdcBurned)}`} />
        <StatCard label="CLAWD burned" value={formatClawd(totalClawdBurned)} />
      </div>

      <div className="card bg-base-100 shadow-sm border border-base-300">
        <div className="card-body gap-3">
          <h2 className="text-xl font-bold my-0">Top Keepers</h2>
          {stillLoading && (
            <div className="text-center opacity-70">
              <span className="loading loading-spinner loading-md" />
            </div>
          )}
          {!stillLoading && keeperLeaderboard.length === 0 && <p className="opacity-80 my-0">No executions yet.</p>}
          {keeperLeaderboard.length > 0 && (
            <div className="overflow-x-auto">
              <table className="table table-sm">
                <thead>
                  <tr>
                    <th>#</th>
                    <th>Keeper</th>
                    <th>Executions</th>
                  </tr>
                </thead>
                <tbody>
                  {keeperLeaderboard.map(([addr, count], i) => (
                    <tr key={addr}>
                      <td>{i + 1}</td>
                      <td>
                        <AddressComp address={addr as `0x${string}`} format="short" size="xs" chain={base} />
                      </td>
                      <td>{count}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>
    </div>
  );
};

const StatCard = ({ label, value }: { label: string; value: string }) => (
  <div className="card bg-base-100 shadow-sm border border-base-300">
    <div className="card-body py-3 px-4">
      <div className="text-xs opacity-70">{label}</div>
      <div className="text-lg font-bold">{value}</div>
    </div>
  </div>
);

export default StatsPage;
