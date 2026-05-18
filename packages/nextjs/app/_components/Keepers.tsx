"use client";

import { useEffect, useMemo, useState } from "react";
import { Address as AddressComp } from "@scaffold-ui/components";
import type { NextPage } from "next";
import { base } from "viem/chains";
import { useAccount, usePublicClient, useSwitchChain } from "wagmi";
import { WalletStrip } from "~~/components/dca/WalletStrip";
import { useScaffoldEventHistory, useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { useWriteAndOpen } from "~~/hooks/scaffold-eth/useWriteAndOpen";
import {
  BPS_DENOMINATOR,
  CLAWDDCA_ADDRESS,
  DEPLOYED_ON_BLOCK,
  KEEPER_FEE_BPS,
  formatUsdc,
  intervalLabel,
} from "~~/utils/dca";
import { notification } from "~~/utils/scaffold-eth";
import { getParsedErrorWithAllAbis } from "~~/utils/scaffold-eth/contract";

type RipePosition = {
  positionId: bigint;
  owner: `0x${string}`;
  amountPerSwap: bigint;
  intervalInEpochs: bigint;
  lastExecutedEpoch: bigint;
  active: boolean;
};

const KeepersPage: NextPage = () => {
  const { isConnected, chainId } = useAccount();
  const { switchChain, isPending: isSwitching } = useSwitchChain();
  const wrongNetwork = isConnected && chainId !== base.id;
  const publicClient = usePublicClient({ chainId: base.id });
  const { writeAndOpen } = useWriteAndOpen();

  const { writeContractAsync: writeDca } = useScaffoldWriteContract({
    contractName: "CLAWDdca",
  });

  // Get all PositionCreated events ever emitted to enumerate every position.
  // For an L2 with 2s blocks this is a lot of getLogs hits; we anchor at the
  // deploy block to keep it bounded.
  const { data: createdEvents, isLoading: eventsLoading } = useScaffoldEventHistory({
    contractName: "CLAWDdca",
    eventName: "PositionCreated",
    fromBlock: DEPLOYED_ON_BLOCK,
    watch: true,
  });

  const allIds = useMemo<bigint[]>(() => {
    if (!createdEvents) return [];
    const ids = new Set<string>();
    for (const log of createdEvents) {
      const id = (log as any).args?.positionId as bigint | undefined;
      if (id !== undefined) ids.add(id.toString());
    }
    return Array.from(ids).map(s => BigInt(s));
  }, [createdEvents]);

  const { data: currentEpoch } = useScaffoldReadContract({
    contractName: "CLAWDdca",
    functionName: "currentEpoch",
    watch: true,
  });

  const { data: burnFeeBalance } = useScaffoldReadContract({
    contractName: "CLAWDdca",
    functionName: "burnFeeBalance",
    watch: true,
  });

  const [positionRows, setPositionRows] = useState<RipePosition[]>([]);
  const [posLoading, setPosLoading] = useState(false);

  useEffect(() => {
    if (!publicClient || allIds.length === 0) {
      setPositionRows([]);
      return;
    }
    let cancelled = false;
    setPosLoading(true);
    (async () => {
      const dcaAbi = [
        {
          type: "function",
          name: "positions",
          inputs: [{ type: "uint256" }],
          outputs: [
            { type: "address" },
            { type: "uint256" },
            { type: "uint256" },
            { type: "uint256" },
            { type: "uint256" },
            { type: "uint256" },
            { type: "uint256" },
            { type: "bool" },
          ],
          stateMutability: "view",
        },
      ] as const;

      try {
        const results = await Promise.all(
          allIds.map(id =>
            publicClient.readContract({
              address: CLAWDDCA_ADDRESS,
              abi: dcaAbi,
              functionName: "positions",
              args: [id],
            }),
          ),
        );
        if (cancelled) return;
        const rows: RipePosition[] = results
          .map((r: any, i): RipePosition | null => {
            const [owner, , , amountPerSwap, intervalInEpochs, lastExecutedEpoch, , active] = r as readonly [
              `0x${string}`,
              bigint,
              bigint,
              bigint,
              bigint,
              bigint,
              bigint,
              boolean,
            ];
            if (!active) return null;
            return {
              positionId: allIds[i],
              owner,
              amountPerSwap,
              intervalInEpochs,
              lastExecutedEpoch,
              active,
            };
          })
          .filter((x): x is RipePosition => x !== null);
        setPositionRows(rows);
      } catch (e) {
        console.error("Failed to fetch positions for keepers view", e);
      } finally {
        if (!cancelled) setPosLoading(false);
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [publicClient, allIds]);

  const ripePositions = useMemo(() => {
    if (currentEpoch === undefined) return [];
    return positionRows.filter(p => (currentEpoch as bigint) >= p.lastExecutedEpoch + p.intervalInEpochs);
  }, [positionRows, currentEpoch]);

  const totalKeeperReward = useMemo(() => {
    let sum = 0n;
    for (const p of ripePositions) {
      sum += (p.amountPerSwap * KEEPER_FEE_BPS) / BPS_DENOMINATOR;
    }
    return sum;
  }, [ripePositions]);

  const [busyId, setBusyId] = useState<string | null>(null);
  const [batchBusy, setBatchBusy] = useState(false);
  const [burnBusy, setBurnBusy] = useState(false);

  const handleExecuteBurn = async () => {
    setBurnBusy(true);
    try {
      await writeAndOpen(() =>
        writeDca({
          functionName: "executeBurn",
        }),
      );
      notification.success("CLAWD burn executed!");
    } catch (e) {
      const msg = getParsedErrorWithAllAbis(e, base.id);
      notification.error(msg);
    } finally {
      setBurnBusy(false);
    }
  };

  const handleExecute = async (positionId: bigint) => {
    setBusyId(positionId.toString());
    try {
      await writeAndOpen(() =>
        writeDca({
          functionName: "executeDCA",
          args: [positionId],
        }),
      );
      notification.success(`Executed position #${positionId.toString()}`);
    } catch (e) {
      const msg = getParsedErrorWithAllAbis(e, base.id);
      notification.error(msg);
    } finally {
      setBusyId(null);
    }
  };

  const handleExecuteAll = async () => {
    if (ripePositions.length === 0) return;
    setBatchBusy(true);
    try {
      const ids = ripePositions.map(p => p.positionId);
      await writeAndOpen(() =>
        writeDca({
          functionName: "executeBatch",
          args: [ids],
        }),
      );
      notification.success(`Executed ${ids.length} ripe positions`);
    } catch (e) {
      const msg = getParsedErrorWithAllAbis(e, base.id);
      notification.error(msg);
    } finally {
      setBatchBusy(false);
    }
  };

  return (
    <div className="max-w-5xl w-full mx-auto px-4 py-8 flex flex-col gap-6">
      <header className="flex flex-col gap-1 text-center">
        <h1 className="text-3xl font-bold my-0">Keeper Network</h1>
        <p className="opacity-80 my-0">
          Permissionless keepers earn 0.2% USDC per swap. An additional 0.2% accrues for CLAWD burns — trigger it below.
          Anyone can run executions — including you.
        </p>
      </header>

      <WalletStrip />

      <div className="card bg-base-100 shadow-sm border border-base-300">
        <div className="card-body gap-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <div>
              <h2 className="text-xl font-bold my-0">CLAWD Burn</h2>
              <p className="text-sm opacity-70 my-0">
                Accrued burn fees:{" "}
                <span className="font-semibold">${formatUsdc(burnFeeBalance as bigint | undefined)} USDC</span>
              </p>
            </div>
            {isConnected && wrongNetwork ? (
              <button
                className="btn btn-warning btn-sm"
                disabled={isSwitching}
                onClick={() => switchChain({ chainId: base.id })}
              >
                {isSwitching ? <span className="loading loading-spinner loading-xs" /> : null}
                Switch to Base
              </button>
            ) : (
              <button
                className="btn btn-secondary btn-sm"
                disabled={!isConnected || !burnFeeBalance || (burnFeeBalance as bigint) === 0n || burnBusy}
                onClick={handleExecuteBurn}
              >
                {burnBusy ? <span className="loading loading-spinner loading-xs" /> : null}
                Execute Burn
              </button>
            )}
          </div>
          <p className="text-xs opacity-60 my-0">
            Swaps all accrued USDC burn fees for CLAWD via Uniswap V3 and sends to{" "}
            <a
              href={`https://basescan.org/address/0x000000000000000000000000000000000000dEaD`}
              target="_blank"
              rel="noopener noreferrer"
              className="link"
            >
              0xdead
            </a>
            .
          </p>
        </div>
      </div>

      <div className="card bg-base-100 shadow-sm border border-base-300">
        <div className="card-body gap-3">
          <div className="flex flex-wrap items-center justify-between gap-2">
            <h2 className="text-xl font-bold my-0">Ripe Positions ({ripePositions.length})</h2>
            {isConnected && wrongNetwork ? (
              <button
                className="btn btn-warning btn-sm"
                disabled={isSwitching}
                onClick={() => switchChain({ chainId: base.id })}
              >
                {isSwitching ? <span className="loading loading-spinner loading-xs" /> : null}
                Switch to Base
              </button>
            ) : (
              <button
                className="btn btn-primary btn-sm"
                disabled={!isConnected || ripePositions.length === 0 || batchBusy}
                onClick={handleExecuteAll}
              >
                {batchBusy ? <span className="loading loading-spinner loading-xs" /> : null}
                Execute All Ripe (≈ ${formatUsdc(totalKeeperReward)} reward)
              </button>
            )}
          </div>

          {(eventsLoading || posLoading) && (
            <div className="text-center opacity-70">
              <span className="loading loading-spinner loading-md" />
            </div>
          )}

          {!eventsLoading && !posLoading && ripePositions.length === 0 && (
            <p className="opacity-80 my-0">No ripe positions — check back in a few minutes.</p>
          )}

          {ripePositions.length > 0 && (
            <div className="overflow-x-auto">
              <table className="table table-sm">
                <thead>
                  <tr>
                    <th>ID</th>
                    <th>Owner</th>
                    <th>Per swap</th>
                    <th>Cadence</th>
                    <th>Reward</th>
                    <th></th>
                  </tr>
                </thead>
                <tbody>
                  {ripePositions.map(p => {
                    const reward = (p.amountPerSwap * KEEPER_FEE_BPS) / BPS_DENOMINATOR;
                    return (
                      <tr key={p.positionId.toString()}>
                        <td>#{p.positionId.toString()}</td>
                        <td>
                          <AddressComp address={p.owner} format="short" size="xs" chain={base} />
                        </td>
                        <td>${formatUsdc(p.amountPerSwap)}</td>
                        <td>{intervalLabel(p.intervalInEpochs)}</td>
                        <td>${formatUsdc(reward)}</td>
                        <td>
                          <button
                            className="btn btn-xs btn-primary"
                            disabled={!isConnected || wrongNetwork || busyId === p.positionId.toString()}
                            onClick={() => handleExecute(p.positionId)}
                          >
                            {busyId === p.positionId.toString() ? (
                              <span className="loading loading-spinner loading-xs" />
                            ) : null}
                            Execute
                          </button>
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              </table>
            </div>
          )}
        </div>
      </div>
    </div>
  );
};

export default KeepersPage;
