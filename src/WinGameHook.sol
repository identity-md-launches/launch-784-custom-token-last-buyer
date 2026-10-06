// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title WinGameHook — "last buyer wins" for the WIN/IMD pool
/// @notice Charges a trading fee in IMD on every buy and sell of WIN, banks 90% of it as the prize
/// pool and 10% for the team, and runs a round-based game: every qualifying buy makes the buyer
/// the leader and restarts a 10-minute timer; when the timer runs out the leader is paid a slice
/// of the bank.
///
/// Trust model: there is no owner. Nothing can be changed after deployment, nothing can leave the
/// bank except a round prize, and the team's share can only ever go to the fixed team wallet.
///
/// Fee custody: fees are minted to this contract as ERC-6909 claims on the PoolManager, which needs
/// no balance at the moment of the swap (the swapper's router has not settled yet when `afterSwap`
/// runs; on a pool seeded with WIN only the manager holds no IMD at all before the first buy).
/// Claims are burned and the underlying IMD taken out only when a prize or the team share is paid.
contract WinGameHook is IHooks, IUnlockCallback {
    using SafeCast for uint256;
    using SafeCast for int256;
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    // ---------------------------------------------------------------------------------------
    // Constants (the brief's parameters; nothing is adjustable after deployment)
    // ---------------------------------------------------------------------------------------

    /// @notice Receives 10% of every fee. Pull-based: see `claimTeamFees`.
    address public constant TEAM_WALLET = 0x611F08c7226591708B5F53F29BF53f3830D54511;

    uint256 public constant PIPS = 1_000_000;
    /// @notice Fee at the moment of launch: 50%.
    uint256 public constant LAUNCH_FEE_PIPS = 500_000;
    /// @notice Fee after the anti-snipe window: 3%.
    uint256 public constant BASE_FEE_PIPS = 30_000;
    /// @notice Length of the linear decay from the launch fee to the base fee.
    uint256 public constant FEE_DECAY_DURATION = 30 minutes;

    uint256 public constant BPS = 10_000;
    /// @notice Share of every fee that goes to the team wallet; the rest goes to the bank.
    uint256 public constant TEAM_SHARE_BPS = 1_000;

    /// @notice Timer restarted by every qualifying buy.
    uint256 public constant ROUND_DURATION = 10 minutes;
    /// @notice The first round cannot end before this much time has passed since launch.
    uint256 public constant FIRST_ROUND_MIN_DURATION = 3 hours;
    /// @notice Prize of the first round, as a share of the bank at settlement.
    uint256 public constant FIRST_ROUND_PRIZE_BPS = 2_000;
    /// @notice Prize of every later round, as a share of the bank at settlement.
    uint256 public constant PRIZE_BPS = 500;

    /// @notice Absolute floor of the minimum qualifying buy (gross IMD paid, fee included).
    uint256 public constant MIN_BUY_FLOOR = 8.5 ether;
    /// @notice The minimum qualifying buy is at least this share of the upcoming prize.
    uint256 public constant MIN_BUY_PRIZE_BPS = 2_000;
    /// @notice Each qualifying buy multiplies the round's minimum by this factor (1.05x).
    uint256 public constant ESCALATION_BPS = 10_500;
    uint256 internal constant WAD = 1e18;
    /// @notice Ceiling for the escalator (1e18 x): keeps `minimumBuy` from overflowing in a round
    /// that somehow sees hundreds of qualifying buys. Unreachable in practice (8.5 IMD * 1e18).
    uint256 public constant MAX_ESCALATOR = 1e36;

    // ---------------------------------------------------------------------------------------
    // Immutable configuration
    // ---------------------------------------------------------------------------------------

    IPoolManager public immutable poolManager;
    /// @notice The launch token. The pool's other currency is IMD.
    address public immutable winToken;

    // ---------------------------------------------------------------------------------------
    // Pool state (fixed at initialization)
    // ---------------------------------------------------------------------------------------

    PoolKey internal _poolKey;
    PoolId internal _poolId;
    Currency public imd;
    bool public poolInitialized;
    bool public winIsCurrency0;
    /// @notice Timestamp of pool initialization. Fee decay and the first round's floor count from here.
    uint64 public launchTime;

    // ---------------------------------------------------------------------------------------
    // Money (all denominated in IMD held as ERC-6909 claims on the PoolManager)
    // ---------------------------------------------------------------------------------------

    /// @notice IMD available as prize money.
    uint256 public bank;
    /// @notice IMD the team wallet may pull.
    uint256 public teamOwed;
    /// @notice Prizes decided but not yet transferred (rounds closed lazily by a later buy).
    mapping(address winner => uint256) public unclaimedPrize;
    uint256 public totalUnclaimedPrizes;

    // ---------------------------------------------------------------------------------------
    // Game state
    // ---------------------------------------------------------------------------------------

    struct Winner {
        uint64 round;
        uint64 settledAt;
        address winner;
        uint256 prize;
    }

    /// @notice Number of rounds that have started (the active round, if any, is the last one).
    uint64 public roundsStarted;
    bool public roundActive;
    address public leader;
    uint64 public deadline;
    uint32 public qualifyingBuysInRound;
    /// @notice Multiplier applied to the base minimum buy, WAD-scaled. Reset to 1 each round.
    uint256 public escalator = WAD;
    Winner[] internal _winners;

    // ---------------------------------------------------------------------------------------
    // Payout scratch (set only for the duration of `_payout`)
    // ---------------------------------------------------------------------------------------

    address internal _payoutTo;
    uint256 internal _payoutAmount;
    uint256 internal _entered = 1;

    // ---------------------------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------------------------

    event Launched(PoolId indexed poolId, address winToken, Currency imd, uint64 launchTime);
    event FeeCharged(address indexed trader, bool indexed isBuy, uint256 grossImd, uint256 fee, uint256 feePips);
    event RoundStarted(uint64 indexed round, address indexed leader, uint64 deadline);
    event QualifyingBuy(
        uint64 indexed round, address indexed buyer, uint256 grossImd, uint64 deadline, uint256 nextMinimumBuy
    );
    event RoundSettled(uint64 indexed round, address indexed winner, uint256 prize, uint256 bankAfter);
    event PrizePaid(address indexed winner, uint256 amount);
    event TeamFeesPaid(address indexed to, uint256 amount);

    // ---------------------------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------------------------

    error NotPoolManager();
    error HookNotImplemented();
    error ZeroAddress();
    error TokenHasNoCode();
    error PoolAlreadyInitialized();
    error PoolNotInitialized();
    error UnsupportedLPFee(uint24 fee);
    error PoolMustPairWinToken();
    error WrongPool();
    error PartialFillNotSupported();
    error NoActiveRound();
    error RoundNotOver(uint64 deadline);
    error NothingToClaim();
    error UnexpectedUnlock();
    error Reentrancy();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier nonReentrant() {
        if (_entered != 1) revert Reentrancy();
        _entered = 2;
        _;
        _entered = 1;
    }

    /// @param manager The chain's Uniswap v4 PoolManager (manifest: "$poolManager").
    /// @param token The WIN token deployed just before this hook (manifest: "$token").
    constructor(IPoolManager manager, address token) {
        if (address(manager) == address(0) || token == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert TokenHasNoCode();
        poolManager = manager;
        winToken = token;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
    }

    // ---------------------------------------------------------------------------------------
    // Permissions
    // ---------------------------------------------------------------------------------------

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------------------------
    // Pool initialization
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev Binds the hook to exactly one pool: WIN against one other currency, at one of the
    /// launch policy's LP fee tiers. Records the launch time that drives the fee decay and the
    /// first round's three-hour floor.
    function beforeInitialize(address, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (poolInitialized) revert PoolAlreadyInitialized();
        if (key.fee != 500 && key.fee != 3_000 && key.fee != 10_000) revert UnsupportedLPFee(key.fee);

        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 == winToken) {
            winIsCurrency0 = true;
            imd = key.currency1;
        } else if (c1 == winToken) {
            winIsCurrency0 = false;
            imd = key.currency0;
        } else {
            revert PoolMustPairWinToken();
        }

        _poolKey = key;
        _poolId = key.toId();
        poolInitialized = true;
        launchTime = uint64(block.timestamp);

        emit Launched(_poolId, winToken, imd, launchTime);
        return IHooks.beforeInitialize.selector;
    }

    // ---------------------------------------------------------------------------------------
    // Swaps
    // ---------------------------------------------------------------------------------------

    /// @inheritdoc IHooks
    /// @dev When IMD is the specified currency (exact-input buy, exact-output sell) the fee is
    /// diverted here, before the pool sees the amount. Otherwise the fee is taken in `afterSwap`
    /// from the unspecified side.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        (bool isBuy, bool exactInput) = _classify(params);
        bool imdIsSpecified = isBuy == exactInput;
        if (!imdIsSpecified) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 fee = _specifiedSideFee(params, isBuy, _feePipsAt(block.timestamp));
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
    }

    /// @inheritdoc IHooks
    function afterSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        _checkPool(key);
        (bool isBuy, bool exactInput) = _classify(params);
        uint256 feePips = _feePipsAt(block.timestamp);

        int128 imdDelta = winIsCurrency0 ? delta.amount1() : delta.amount0();
        uint256 fee;
        uint256 gross;
        int128 unspecifiedReturn;

        if (isBuy == exactInput) {
            // IMD was the specified currency and the fee was already diverted in beforeSwap.
            fee = _specifiedSideFee(params, isBuy, feePips);
            uint256 specified = _abs(params.amountSpecified);
            if (isBuy) {
                // exact-input buy: the pool must have consumed everything that was left after the fee.
                gross = specified;
                if (uint256(uint128(-imdDelta)) != gross - fee) revert PartialFillNotSupported();
            } else {
                // exact-output sell: the pool must have produced the requested amount plus the fee.
                gross = specified + fee;
                if (uint256(uint128(imdDelta)) != gross) revert PartialFillNotSupported();
            }
        } else if (isBuy) {
            // exact-output buy: IMD is the unspecified input. Charge on top so the fee is `feePips` of gross.
            uint256 poolIn = uint256(uint128(-imdDelta));
            fee = poolIn * feePips / (PIPS - feePips);
            gross = poolIn + fee;
            unspecifiedReturn = fee.toInt128();
        } else {
            // exact-input sell: IMD is the unspecified output. Take the fee out of it.
            uint256 poolOut = uint256(uint128(imdDelta));
            fee = poolOut * feePips / PIPS;
            gross = poolOut;
            unspecifiedReturn = fee.toInt128();
        }

        address trader = _resolveTrader(hookData);
        if (fee > 0) poolManager.mint(address(this), imd.toId(), fee);
        emit FeeCharged(trader, isBuy, gross, fee, feePips);

        if (isBuy) {
            // A buy that arrives after the deadline closes the previous round for its real leader
            // first; it can only ever start the next round. Then the minimum is read before this
            // buy's fee enters the bank, so it matches what the website displayed.
            _finalizeIfExpired();
            uint256 minimum = minimumBuy();
            _accrue(fee);
            if (gross >= minimum) _qualify(trader, gross);
        } else {
            _accrue(fee);
        }

        return (IHooks.afterSwap.selector, unspecifiedReturn);
    }

    // ---------------------------------------------------------------------------------------
    // Game: settlement and payouts
    // ---------------------------------------------------------------------------------------

    /// @notice Closes the active round once its timer has run out and pays the leader.
    /// Anyone may call it.
    function settle() external nonReentrant {
        if (!roundActive) revert NoActiveRound();
        if (block.timestamp < deadline) revert RoundNotOver(deadline);
        address winner = leader;
        _finalize();
        _payPrize(winner);
    }

    /// @notice Pays out a prize that was decided when a later buy closed the round lazily.
    /// Anyone may call it; the money only ever goes to `winner`.
    function claimPrize(address winner) external nonReentrant {
        _payPrize(winner);
    }

    /// @notice Transfers the team's accumulated 10% share to the fixed team wallet. Anyone may
    /// trigger it; the destination cannot be changed.
    function claimTeamFees() external nonReentrant {
        uint256 amount = teamOwed;
        if (amount == 0) revert NothingToClaim();
        teamOwed = 0;
        _payout(TEAM_WALLET, amount);
        emit TeamFeesPaid(TEAM_WALLET, amount);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only reachable through `_payout`: burns this contract's IMD claims and sends the
    /// underlying tokens to the recipient recorded in storage. Calldata is ignored on purpose.
    function unlockCallback(bytes calldata) external onlyPoolManager returns (bytes memory) {
        address to = _payoutTo;
        uint256 amount = _payoutAmount;
        if (to == address(0) || amount == 0) revert UnexpectedUnlock();
        poolManager.burn(address(this), imd.toId(), amount);
        poolManager.take(imd, to, amount);
        return "";
    }

    // ---------------------------------------------------------------------------------------
    // Views for the website
    // ---------------------------------------------------------------------------------------

    /// @notice IMD in the prize bank.
    function bankBalance() external view returns (uint256) {
        return bank;
    }

    /// @notice The prize the current (or, between rounds, the next) round would pay if it settled now.
    function nextPrize() public view returns (uint256) {
        return bank * _prizeBps() / BPS;
    }

    /// @notice Gross IMD (fee included) a buy must spend right now to become the leader.
    function minimumBuy() public view returns (uint256) {
        uint256 base = nextPrize() * MIN_BUY_PRIZE_BPS / BPS;
        if (base < MIN_BUY_FLOOR) base = MIN_BUY_FLOOR;
        return base * escalator / WAD;
    }

    /// @notice Seconds until the active round can be settled; zero when none is active or it has expired.
    function timeLeft() public view returns (uint256) {
        if (!roundActive || block.timestamp >= deadline) return 0;
        return deadline - block.timestamp;
    }

    /// @notice The active round's number, or the number the next round will get.
    function roundNumber() public view returns (uint64) {
        return roundActive ? roundsStarted : roundsStarted + 1;
    }

    /// @notice True when the active round's timer has run out but `settle()` has not run yet.
    function settleable() external view returns (bool) {
        return roundActive && block.timestamp >= deadline;
    }

    /// @notice Current total trading fee in pips (1e6 = 100%).
    function currentFeePips() external view returns (uint256) {
        return _feePipsAt(block.timestamp);
    }

    /// @notice Trading fee in pips at `timestamp`: 50% at launch, falling linearly to 3% over 30 minutes.
    function feePipsAt(uint256 timestamp) external view returns (uint256) {
        return _feePipsAt(timestamp);
    }

    function winnersCount() external view returns (uint256) {
        return _winners.length;
    }

    function winnerAt(uint256 index) external view returns (Winner memory) {
        return _winners[index];
    }

    /// @notice Every settled round, oldest first.
    function pastWinners() external view returns (Winner[] memory) {
        return _winners;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    function poolId() external view returns (PoolId) {
        return _poolId;
    }

    struct GameState {
        uint256 bank;
        uint256 nextPrize;
        uint256 minimumBuy;
        address leader;
        uint256 timeLeft;
        uint64 roundNumber;
        bool roundActive;
        uint64 deadline;
        uint32 qualifyingBuysInRound;
        uint256 feePips;
        uint256 teamOwed;
        uint256 winners;
    }

    /// @notice Everything the website shows, in one call.
    function gameState() external view returns (GameState memory s) {
        s.bank = bank;
        s.nextPrize = nextPrize();
        s.minimumBuy = minimumBuy();
        s.leader = leader;
        s.timeLeft = timeLeft();
        s.roundNumber = roundNumber();
        s.roundActive = roundActive;
        s.deadline = deadline;
        s.qualifyingBuysInRound = qualifyingBuysInRound;
        s.feePips = _feePipsAt(block.timestamp);
        s.teamOwed = teamOwed;
        s.winners = _winners.length;
    }

    // ---------------------------------------------------------------------------------------
    // Internals: fees
    // ---------------------------------------------------------------------------------------

    function _feePipsAt(uint256 timestamp) internal view returns (uint256) {
        uint256 start = launchTime;
        if (timestamp <= start) return LAUNCH_FEE_PIPS;
        uint256 elapsed = timestamp - start;
        if (elapsed >= FEE_DECAY_DURATION) return BASE_FEE_PIPS;
        return LAUNCH_FEE_PIPS - (LAUNCH_FEE_PIPS - BASE_FEE_PIPS) * elapsed / FEE_DECAY_DURATION;
    }

    /// @dev Fee when IMD is the specified currency. Exact-input buy: `feePips` of the IMD paid.
    /// Exact-output sell: charged on top of the requested IMD so it is `feePips` of the gross output.
    function _specifiedSideFee(SwapParams calldata params, bool isBuy, uint256 feePips)
        internal
        pure
        returns (uint256)
    {
        uint256 specified = _abs(params.amountSpecified);
        return isBuy ? specified * feePips / PIPS : specified * feePips / (PIPS - feePips);
    }

    /// @return isBuy True when IMD goes in and WIN comes out.
    /// @return exactInput True when `amountSpecified` is an input amount.
    function _classify(SwapParams calldata params) internal view returns (bool isBuy, bool exactInput) {
        // zeroForOne means currency0 is the input. The input is IMD when IMD is currency0.
        isBuy = params.zeroForOne != winIsCurrency0;
        exactInput = params.amountSpecified < 0;
    }

    function _accrue(uint256 fee) internal {
        if (fee == 0) return;
        uint256 team = fee * TEAM_SHARE_BPS / BPS;
        teamOwed += team;
        bank += fee - team;
    }

    // ---------------------------------------------------------------------------------------
    // Internals: game
    // ---------------------------------------------------------------------------------------

    function _prizeBps() internal view returns (uint256) {
        return roundNumber() == 1 ? FIRST_ROUND_PRIZE_BPS : PRIZE_BPS;
    }

    function _qualify(address buyer, uint256 gross) internal {
        uint64 newDeadline = uint64(block.timestamp + ROUND_DURATION);
        if (!roundActive) {
            roundsStarted += 1;
            roundActive = true;
            qualifyingBuysInRound = 0;
            escalator = WAD;
        }
        if (roundsStarted == 1) {
            uint64 floor_ = launchTime + uint64(FIRST_ROUND_MIN_DURATION);
            if (newDeadline < floor_) newDeadline = floor_;
        }
        if (qualifyingBuysInRound == 0) emit RoundStarted(roundsStarted, buyer, newDeadline);

        leader = buyer;
        deadline = newDeadline;
        qualifyingBuysInRound += 1;
        uint256 nextEscalator = escalator * ESCALATION_BPS / BPS;
        escalator = nextEscalator > MAX_ESCALATOR ? MAX_ESCALATOR : nextEscalator;

        emit QualifyingBuy(roundsStarted, buyer, gross, newDeadline, minimumBuy());
    }

    function _finalizeIfExpired() internal {
        if (roundActive && block.timestamp >= deadline) _finalize();
    }

    /// @dev Closes the active round: moves the prize out of the bank into the winner's claimable
    /// balance and resets the per-round state. Requires an active, expired round.
    function _finalize() internal {
        uint256 prize = bank * _prizeBps() / BPS;
        address winner = leader;
        uint64 round = roundsStarted;

        bank -= prize;
        unclaimedPrize[winner] += prize;
        totalUnclaimedPrizes += prize;
        _winners.push(Winner({round: round, settledAt: uint64(block.timestamp), winner: winner, prize: prize}));

        roundActive = false;
        leader = address(0);
        deadline = 0;
        qualifyingBuysInRound = 0;
        escalator = WAD;

        emit RoundSettled(round, winner, prize, bank);
    }

    function _payPrize(address winner) internal {
        uint256 amount = unclaimedPrize[winner];
        if (amount == 0) revert NothingToClaim();
        unclaimedPrize[winner] = 0;
        totalUnclaimedPrizes -= amount;
        _payout(winner, amount);
        emit PrizePaid(winner, amount);
    }

    /// @dev Burns `amount` of this contract's IMD claims and sends the tokens to `to`. Runs inside a
    /// PoolManager unlock, so it cannot be reached while any swap is in flight (the manager rejects
    /// nested unlocks), which is what keeps settlement out of a swap transaction's callback.
    function _payout(address to, uint256 amount) internal {
        _payoutTo = to;
        _payoutAmount = amount;
        poolManager.unlock("");
        _payoutTo = address(0);
        _payoutAmount = 0;
    }

    // ---------------------------------------------------------------------------------------
    // Internals: identity and misc
    // ---------------------------------------------------------------------------------------

    /// @dev Who is buying. The PoolManager hands the hook the router, never the user, so the
    /// router passes the user in `hookData` (32-byte ABI encoding or a packed 20-byte address).
    /// When it is absent or malformed, `tx.origin` is used: that is the account that signed the
    /// transaction, which for a plain wallet trade through any router is the buyer. See README for
    /// the trade-offs (smart-contract wallets and relayers must pass hookData).
    function _resolveTrader(bytes calldata hookData) internal view returns (address trader) {
        if (hookData.length == 32) {
            uint256 word = uint256(bytes32(hookData[:32]));
            if (word >> 160 == 0) trader = address(uint160(word));
        } else if (hookData.length == 20) {
            trader = address(bytes20(hookData[:20]));
        }
        if (trader == address(0)) trader = tx.origin;
    }

    function _checkPool(PoolKey calldata key) internal view {
        if (!poolInitialized) revert PoolNotInitialized();
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(_poolId)) revert WrongPool();
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    // ---------------------------------------------------------------------------------------
    // Callbacks this hook does not enable. The address carries no flag for them, so the
    // PoolManager never calls them; they revert if anyone else does.
    // ---------------------------------------------------------------------------------------

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }
}
