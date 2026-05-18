// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Ownable2Step } from "@openzeppelin/contracts/access/Ownable2Step.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Minimal SwapRouter02 interface (Base mainnet — no `deadline` field).
interface ISwapRouter02 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// @notice Minimal Uniswap V3 QuoterV2 interface.
/// @dev `quoteExactInput` is non-view (state-mutating revert pattern). Calls to it will mutate-then-revert internally
///      and return the quote via the QuoterV2 wrapper. We call it directly — gas cost is acceptable for this prototype.
interface IQuoterV2 {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList,
            uint32[] memory initializedTicksCrossedList,
            uint256 gasEstimate
        );
}

/**
 * @title CLAWDdca
 * @notice Permissionless dollar-cost-averaging engine: users park USDC, anyone (a "keeper") triggers
 *         the swap once a position is ripe, the contract pays the keeper and protocol fees, accrues a
 *         burn fee to `burnFeeBalance`, swaps the remainder for CLAWD via Uniswap V3, and credits CLAWD
 *         to the position. Owner withdraws CLAWD or closes the position at any time. Pausable; withdrawals
 *         stay open while paused.
 *
 * @dev v2 fee structure (v1 was keeper=39bps, protocol=30bps):
 *      - Keeper: 20 bps (paid immediately to msg.sender in USDC)
 *      - Protocol: 10 bps (accrues to protocolFeeBalance, owner collects)
 *      - Burn: 20 bps (accrues to burnFeeBalance, any caller triggers executeBurn() to swap→0xdead)
 *
 *      Hardcoded to Base mainnet token + router addresses listed below. Two keeper entrypoints:
 *      - `executeDCAWithMin(positionId, amountOutMinimum)` — production-safe path. The keeper computes
 *        `amountOutMinimum` off-chain (e.g. via a static QuoterV2 call from the keeper UI / RPC) and
 *        passes it in. The contract enforces it directly through SwapRouter02. This is sandwich-resistant
 *        because the minimum is fixed at quote time, not derived from same-block pool state.
 *      - `executeDCA(positionId)` — best-effort convenience. Calls QuoterV2 in the same transaction and
 *        applies `position.slippageBps`. NOTE: A same-block QuoterV2 quote does NOT protect against
 *        sandwich MEV — a sufficiently funded attacker can manipulate the pool between the quote and the
 *        swap in the same block. The keeper UI should default to `executeDCAWithMin`. Use `executeDCA`
 *        only as a fallback or for low-value testnet flows.
 *      For production deployment, prefer off-chain quoting (the keeper passes `amountOutMinimum`) or a
 *      TWAP oracle. The on-chain QuoterV2 quote is a documented best-effort limitation.
 */
contract CLAWDdca is Ownable2Step, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------------------------------
    // External token + protocol addresses (Base mainnet, chain 8453)
    // ---------------------------------------------------------------------------------------------

    /// @notice CLAWD ERC20 (18 decimals, assumed).
    address public constant CLAWD = 0x9f86dB9fc6f7c9408e8Fda3Ff8ce4e78ac7a6b07;

    /// @notice USDC bridged on Base (6 decimals).
    address public constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    /// @notice Uniswap V3 SwapRouter02 on Base.
    address public constant SWAP_ROUTER = 0x2626664c2603336E57B271c5C0b26F421741e481;

    /// @notice WETH on Base.
    address public constant WETH = 0x4200000000000000000000000000000000000006;

    /// @notice Uniswap V3 QuoterV2 on Base.
    address public constant QUOTER = 0x3d4e44Eb1374240CE5F1B871ab261CD16335B76a;

    // ---------------------------------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------------------------------

    /// @notice Standard dead-address burn destination. CLAWD tokens sent here are permanently removed from circulation.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    uint256 public constant EPOCH_DURATION = 3 hours;
    uint256 public constant KEEPER_FEE_BPS = 20; // 0.20%
    uint256 public constant PROTOCOL_FEE_BPS = 10; // 0.10%
    uint256 public constant BURN_FEE_BPS = 20; // 0.20% — accrues to burnFeeBalance for permissionless burn
    uint256 public constant DEFAULT_SLIPPAGE_BPS = 300; // 3%
    uint256 public constant MAX_SLIPPAGE_BPS = 1000; // 10%
    uint256 public constant BPS_DENOMINATOR = 10_000;

    // ---------------------------------------------------------------------------------------------
    // Storage
    // ---------------------------------------------------------------------------------------------

    struct Position {
        address owner;
        uint256 usdcBalance;
        uint256 clawdAccrued;
        uint256 amountPerSwap;
        uint256 intervalInEpochs;
        uint256 lastExecutedEpoch;
        uint256 slippageBps;
        bool active;
    }

    mapping(uint256 => Position) public positions;
    /// @notice Append-only list of position ids per owner. Closed positions are NOT removed; consumers
    ///         must filter by `positions[id].active` (or use `getRipePositions`) for the live set.
    mapping(address => uint256[]) public positionsByOwner;
    uint256 public nextPositionId; // monotonic, starts at 1
    uint256 public protocolFeeBalance; // USDC fee accrual, withdrawable by owner
    uint256 public burnFeeBalance; // USDC fee accrual, permissionlessly convertible to CLAWD burn via executeBurn()
    bytes public swapPath;

    // ---------------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------------

    event PositionCreated(
        uint256 indexed positionId, address indexed owner, uint256 amountPerSwap, uint256 intervalInEpochs
    );
    event PositionToppedUp(uint256 indexed positionId, uint256 amount);
    event DCAExecuted(
        uint256 indexed positionId,
        uint256 usdcSpent,
        uint256 clawdReceived,
        uint256 keeperFee,
        uint256 protocolFee,
        uint256 burnFee,
        address indexed keeper
    );
    event CLAWDWithdrawn(uint256 indexed positionId, address indexed owner, uint256 amount);
    event PositionClosed(uint256 indexed positionId);
    event SlippageUpdated(uint256 indexed positionId, uint256 bps);
    event ProtocolFeesCollected(uint256 amount);
    event BurnExecuted(uint256 usdcBurned, uint256 clawdBurned);
    event SwapPathUpdated(bytes path);

    // ---------------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------------

    error NotPositionOwner();
    error PositionInactive();
    error PositionNotFound();
    error ZeroAmount();
    error AmountExceedsBalance();
    error ZeroInterval();
    error NotRipe();
    error SlippageTooHigh();
    error InvalidPath();
    error ZeroAddress();
    error OwnershipCannotBeRenounced();

    // ---------------------------------------------------------------------------------------------
    // Constructor
    // ---------------------------------------------------------------------------------------------

    /// @param initialOwner The job client — receives ownership.
    constructor(address initialOwner) Ownable(initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        // USDC -> WETH (0.05%) -> CLAWD (1%). Two hops: 20 + 3 + 20 + 3 + 20 = 66 bytes.
        bytes memory path = abi.encodePacked(USDC, uint24(500), WETH, uint24(10_000), CLAWD);
        // Defense-in-depth: confirm the structural length check used by setSwapPath also passes here.
        // For a USDC-prefixed, CLAWD-suffixed path built from the constants above, this is always true.
        require(path.length >= 43 && (path.length - 20) % 23 == 0, "bad init path");
        swapPath = path;
        nextPositionId = 1;
        emit SwapPathUpdated(path);
    }

    // ---------------------------------------------------------------------------------------------
    // Position lifecycle — user-facing
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Open a new DCA position by depositing USDC.
     * @param totalUSDC Total USDC to deposit up front.
     * @param amountPerSwap Gross USDC per execution (fees deducted from this amount).
     * @param intervalInEpochs How many 3-hour epochs must pass between executions.
     * @return positionId Newly assigned position id.
     */
    function createPosition(uint256 totalUSDC, uint256 amountPerSwap, uint256 intervalInEpochs)
        external
        whenNotPaused
        returns (uint256 positionId)
    {
        if (totalUSDC == 0) revert ZeroAmount();
        if (amountPerSwap == 0) revert ZeroAmount();
        if (amountPerSwap > totalUSDC) revert AmountExceedsBalance();
        if (intervalInEpochs == 0) revert ZeroInterval();

        IERC20(USDC).safeTransferFrom(msg.sender, address(this), totalUSDC);

        positionId = nextPositionId++;

        // First execution should be immediately ripe — set lastExecutedEpoch so currentEpoch already satisfies the interval.
        uint256 ripeStart = currentEpoch();
        // Avoid underflow when block.timestamp is small (test environments / forks at genesis).
        uint256 lastExecutedEpoch_ = ripeStart >= intervalInEpochs ? ripeStart - intervalInEpochs : 0;

        positions[positionId] = Position({
            owner: msg.sender,
            usdcBalance: totalUSDC,
            clawdAccrued: 0,
            amountPerSwap: amountPerSwap,
            intervalInEpochs: intervalInEpochs,
            lastExecutedEpoch: lastExecutedEpoch_,
            slippageBps: DEFAULT_SLIPPAGE_BPS,
            active: true
        });
        positionsByOwner[msg.sender].push(positionId);

        emit PositionCreated(positionId, msg.sender, amountPerSwap, intervalInEpochs);
    }

    /// @notice Add USDC to an existing position.
    function topUpPosition(uint256 positionId, uint256 amount) external whenNotPaused {
        Position storage p = positions[positionId];
        if (p.owner == address(0)) revert PositionNotFound();
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (!p.active) revert PositionInactive();
        if (amount == 0) revert ZeroAmount();

        IERC20(USDC).safeTransferFrom(msg.sender, address(this), amount);
        p.usdcBalance += amount;

        emit PositionToppedUp(positionId, amount);
    }

    /// @notice Withdraw all accrued CLAWD from a position. Allowed even when paused.
    function withdrawCLAWD(uint256 positionId) external nonReentrant {
        Position storage p = positions[positionId];
        if (p.owner == address(0)) revert PositionNotFound();
        if (p.owner != msg.sender) revert NotPositionOwner();

        uint256 amount = p.clawdAccrued;
        if (amount == 0) revert ZeroAmount();

        // CEI
        p.clawdAccrued = 0;
        IERC20(CLAWD).safeTransfer(p.owner, amount);

        emit CLAWDWithdrawn(positionId, p.owner, amount);
    }

    /// @notice Close a position and return any remaining USDC + accrued CLAWD. Allowed even when paused.
    /// @dev Reverts if the position is already closed so indexers don't see a duplicate `PositionClosed`.
    function closePosition(uint256 positionId) external nonReentrant {
        Position storage p = positions[positionId];
        if (p.owner == address(0)) revert PositionNotFound();
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (!p.active) revert PositionInactive();

        uint256 usdcAmount = p.usdcBalance;
        uint256 clawdAmount = p.clawdAccrued;
        address ownerAddr = p.owner;

        // CEI
        p.usdcBalance = 0;
        p.clawdAccrued = 0;
        p.active = false;

        if (usdcAmount > 0) IERC20(USDC).safeTransfer(ownerAddr, usdcAmount);
        if (clawdAmount > 0) IERC20(CLAWD).safeTransfer(ownerAddr, clawdAmount);

        emit PositionClosed(positionId);
    }

    /// @notice Update the slippage tolerance (in bps) for a position.
    function setSlippageTolerance(uint256 positionId, uint256 bps) external {
        Position storage p = positions[positionId];
        if (p.owner == address(0)) revert PositionNotFound();
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (bps > MAX_SLIPPAGE_BPS) revert SlippageTooHigh();

        p.slippageBps = bps;
        emit SlippageUpdated(positionId, bps);
    }

    // ---------------------------------------------------------------------------------------------
    // Keeper-facing
    // ---------------------------------------------------------------------------------------------

    /**
     * @notice Trigger a DCA swap for a single ripe position using on-chain QuoterV2 for slippage. Best-effort
     *         only — does NOT protect against same-block sandwich MEV. Prefer `executeDCAWithMin` in production.
     * @dev CEI ordering: state updated (balance, epoch, fees) before any external call.
     */
    function executeDCA(uint256 positionId) external whenNotPaused nonReentrant {
        _executeDCA(positionId, 0, true);
    }

    /**
     * @notice Trigger a DCA swap with a keeper-supplied `amountOutMinimum`. This is the production-safe path:
     *         the keeper computes `amountOutMinimum` off-chain (e.g. by calling QuoterV2 from a static RPC
     *         provider or by reading a TWAP) and the contract enforces it directly. Sandwich-resistant
     *         because the minimum is fixed at the time the keeper builds the transaction.
     * @param positionId The position to execute.
     * @param amountOutMinimum The minimum CLAWD output the swap must produce, computed off-chain. The router
     *                        will revert if the actual output is below this. Set to 0 to disable on-chain
     *                        slippage protection (NOT recommended).
     */
    function executeDCAWithMin(uint256 positionId, uint256 amountOutMinimum) external whenNotPaused nonReentrant {
        _executeDCA(positionId, amountOutMinimum, false);
    }

    /**
     * @notice Trigger DCA across many positions using on-chain QuoterV2 for slippage. Skips silently if a
     *         position is inactive, has zero balance, or is not ripe. If the swap itself reverts (e.g.
     *         slippage), the whole batch reverts — caller should pre-filter via `getRipePositions`.
     * @dev Like `executeDCA`, this uses on-chain QuoterV2 and is NOT sandwich-resistant. For production
     *      keepers, batch by calling `executeDCAWithMin` per-position with off-chain quotes.
     */
    function executeBatch(uint256[] calldata positionIds) external whenNotPaused nonReentrant {
        uint256 currentEpoch_ = currentEpoch();
        for (uint256 i = 0; i < positionIds.length; ++i) {
            uint256 positionId = positionIds[i];
            Position storage p = positions[positionId];
            if (!p.active) continue;
            if (p.usdcBalance == 0) continue;
            if (currentEpoch_ < p.lastExecutedEpoch + p.intervalInEpochs) continue;
            _executeDCA(positionId, 0, true);
        }
    }

    /**
     * @dev Shared DCA execution body.
     * @param positionId The position to execute.
     * @param suppliedMin Keeper-supplied amountOutMinimum (only used when useQuoter == false).
     * @param useQuoter If true, fetch a same-block QuoterV2 quote and apply position.slippageBps; if false,
     *                  use `suppliedMin` directly as the router's `amountOutMinimum`.
     */
    function _executeDCA(uint256 positionId, uint256 suppliedMin, bool useQuoter) internal {
        Position storage p = positions[positionId];
        if (!p.active) revert PositionInactive();
        if (p.usdcBalance == 0) revert ZeroAmount();
        uint256 currentEpoch_ = currentEpoch();
        if (currentEpoch_ < p.lastExecutedEpoch + p.intervalInEpochs) revert NotRipe();

        uint256 swapAmount = p.amountPerSwap > p.usdcBalance ? p.usdcBalance : p.amountPerSwap;
        uint256 keeperFee = (swapAmount * KEEPER_FEE_BPS) / BPS_DENOMINATOR;
        uint256 protocolFee = (swapAmount * PROTOCOL_FEE_BPS) / BPS_DENOMINATOR;
        uint256 burnFee = (swapAmount * BURN_FEE_BPS) / BPS_DENOMINATOR;
        uint256 swapInput = swapAmount - keeperFee - protocolFee - burnFee;
        uint256 slippageBps_ = p.slippageBps;

        // ---- effects (CEI) ----
        p.usdcBalance -= swapAmount;
        p.lastExecutedEpoch = currentEpoch_;
        protocolFeeBalance += protocolFee;
        burnFeeBalance += burnFee;
        if (p.usdcBalance == 0) p.active = false;

        // ---- interactions ----
        // Pay keeper their fee in USDC.
        if (keeperFee > 0) IERC20(USDC).safeTransfer(msg.sender, keeperFee);

        uint256 amountOutMinimum;
        if (useQuoter) {
            // Best-effort same-block quote. NOT sandwich-resistant — see contract docstring.
            // QuoterV2.quoteExactInput is state-mutating-then-revert; calling from non-view costs gas.
            uint256 expectedOut;
            (expectedOut,,,) = IQuoterV2(QUOTER).quoteExactInput(swapPath, swapInput);
            amountOutMinimum = (expectedOut * (BPS_DENOMINATOR - slippageBps_)) / BPS_DENOMINATOR;
        } else {
            // Keeper-supplied minimum, fixed at quote time off-chain.
            amountOutMinimum = suppliedMin;
        }

        // Approve router for exactly swapInput.
        IERC20(USDC).forceApprove(SWAP_ROUTER, swapInput);

        uint256 clawdBefore = IERC20(CLAWD).balanceOf(address(this));

        ISwapRouter02.ExactInputParams memory params = ISwapRouter02.ExactInputParams({
            path: swapPath,
            recipient: address(this),
            amountIn: swapInput,
            amountOutMinimum: amountOutMinimum
        });
        ISwapRouter02(SWAP_ROUTER).exactInput(params);

        uint256 clawdReceived = IERC20(CLAWD).balanceOf(address(this)) - clawdBefore;
        p.clawdAccrued += clawdReceived;

        emit DCAExecuted(positionId, swapInput, clawdReceived, keeperFee, protocolFee, burnFee, msg.sender);
    }

    // ---------------------------------------------------------------------------------------------
    // Owner-only
    // ---------------------------------------------------------------------------------------------

    /// @notice Withdraw accumulated protocol fees (USDC) to the contract owner.
    function collectProtocolFees() external onlyOwner nonReentrant {
        uint256 amount = protocolFeeBalance;
        if (amount == 0) revert ZeroAmount();
        protocolFeeBalance = 0;
        IERC20(USDC).safeTransfer(owner(), amount);
        emit ProtocolFeesCollected(amount);
    }

    /**
     * @notice Swap all accumulated burn fees (USDC) for CLAWD and send to 0xdead. Permissionless —
     *         anyone can call this to trigger the burn. Uses the same `swapPath` as DCA executions.
     * @dev Routes CLAWD through this contract (balance-before/after) for accurate burn accounting,
     *      then transfers the received CLAWD to BURN_ADDRESS. Uses on-chain QuoterV2 for slippage
     *      (same MEV caveat as `executeDCA`). `burnFeeBalance` is zeroed before the swap (CEI).
     */
    function executeBurn() external nonReentrant {
        uint256 usdcAmount = burnFeeBalance;
        if (usdcAmount == 0) revert ZeroAmount();

        // CEI — zero state before external calls.
        burnFeeBalance = 0;

        // Same-block QuoterV2 quote, applying default slippage tolerance.
        uint256 expectedOut;
        (expectedOut,,,) = IQuoterV2(QUOTER).quoteExactInput(swapPath, usdcAmount);
        uint256 amountOutMinimum = (expectedOut * (BPS_DENOMINATOR - DEFAULT_SLIPPAGE_BPS)) / BPS_DENOMINATOR;

        IERC20(USDC).forceApprove(SWAP_ROUTER, usdcAmount);

        // Route to this contract so we can measure the actual CLAWD received.
        uint256 clawdBefore = IERC20(CLAWD).balanceOf(address(this));

        ISwapRouter02.ExactInputParams memory params = ISwapRouter02.ExactInputParams({
            path: swapPath,
            recipient: address(this),
            amountIn: usdcAmount,
            amountOutMinimum: amountOutMinimum
        });
        ISwapRouter02(SWAP_ROUTER).exactInput(params);

        uint256 clawdBurned = IERC20(CLAWD).balanceOf(address(this)) - clawdBefore;

        // Transfer all received CLAWD to the burn address.
        if (clawdBurned > 0) IERC20(CLAWD).safeTransfer(BURN_ADDRESS, clawdBurned);

        emit BurnExecuted(usdcAmount, clawdBurned);
    }

    /// @notice Update the Uniswap V3 swap path. Must start with USDC and end with CLAWD; intermediate
    ///         hops and fee tiers are flexible.
    /// @dev Single-hop is 43 bytes (20 + 3 + 20). Multi-hop adds 23 bytes per additional hop. The
    ///      length-structure check enforces `(length - 20) % 23 == 0`, which is equivalent to
    ///      `length ∈ {43, 66, 89, ...}`.
    function setSwapPath(bytes calldata newPath) external onlyOwner {
        _validateSwapPath(newPath);
        swapPath = newPath;
        emit SwapPathUpdated(newPath);
    }

    /// @notice `renounceOwnership` is permanently disabled to prevent the contract from being orphaned
    ///         in a state where `pause`, `setSwapPath`, and `collectProtocolFees` are bricked forever.
    ///         Use `transferOwnership` + `acceptOwnership` (Ownable2Step) to rotate ownership.
    function renounceOwnership() public view override onlyOwner {
        revert OwnershipCannotBeRenounced();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // ---------------------------------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------------------------------

    /// @dev Enforces that a Uniswap V3 swap path begins with `USDC` (input) and ends with `CLAWD` (output),
    ///      and that the byte length matches a valid hop pattern (`(length - 20) % 23 == 0`, with a
    ///      minimum of 43 for a single hop).
    function _validateSwapPath(bytes calldata newPath) internal pure {
        if (newPath.length < 43) revert InvalidPath();
        if ((newPath.length - 20) % 23 != 0) revert InvalidPath();
        address pathStart;
        address pathEnd;
        assembly {
            // First 20 bytes of calldata path = input token.
            pathStart := shr(96, calldataload(newPath.offset))
            // Last 20 bytes of calldata path = output token.
            pathEnd := shr(96, calldataload(add(newPath.offset, sub(newPath.length, 20))))
        }
        if (pathStart != USDC) revert InvalidPath();
        if (pathEnd != CLAWD) revert InvalidPath();
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    function currentEpoch() public view returns (uint256) {
        return block.timestamp / EPOCH_DURATION;
    }

    /// @notice Convenience check used by keeper UIs.
    function isRipe(uint256 positionId) external view returns (bool) {
        Position storage p = positions[positionId];
        if (!p.active) return false;
        if (p.usdcBalance == 0) return false;
        return currentEpoch() >= p.lastExecutedEpoch + p.intervalInEpochs;
    }

    function getPositionsByOwner(address owner_) external view returns (uint256[] memory) {
        return positionsByOwner[owner_];
    }

    /// @notice Filter a list of position ids down to those that are ripe right now.
    function getRipePositions(uint256[] calldata positionIds) external view returns (uint256[] memory) {
        uint256 currentEpoch_ = currentEpoch();
        uint256[] memory tmp = new uint256[](positionIds.length);
        uint256 count;
        for (uint256 i = 0; i < positionIds.length; ++i) {
            Position storage p = positions[positionIds[i]];
            if (!p.active) continue;
            if (p.usdcBalance == 0) continue;
            if (currentEpoch_ < p.lastExecutedEpoch + p.intervalInEpochs) continue;
            tmp[count++] = positionIds[i];
        }
        // Trim
        uint256[] memory out = new uint256[](count);
        for (uint256 j = 0; j < count; ++j) out[j] = tmp[j];
        return out;
    }
}
