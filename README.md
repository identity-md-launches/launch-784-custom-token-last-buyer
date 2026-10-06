# WIN — "last buyer wins" on a Uniswap v4 hook

A fixed-supply token (WIN, `$WIN`) and a Uniswap v4 hook for the WIN/IMD pool. The hook charges a
trading fee in IMD on every buy and sell, banks 90% of it as prize money and 10% for the team, and
runs a round-based game: each qualifying buy makes the buyer the leader and restarts a 10-minute
timer; when the timer runs out the leader is paid a share of the bank.

| Component | File | Notes |
| --- | --- | --- |
| Token | `src/WinToken.sol` | 1,000,000,000 WIN, 18 decimals, minted to the deployer, nothing else |
| Hook | `src/WinGameHook.sol` | fee, bank, game, views; no owner, no upgrade path |
| Flag helpers | `src/HookFlags.sol` | permission bits and CREATE2 salt mining |
| Reference deploy | `script/DeployWin.s.sol` | `deploy(Config)` is what the tests call; `run()` only reads `POOL_MANAGER` |
| Tests | `test/` | 134 tests, both pool orientations, fuzz and reentrancy |
| Review | `docs/REVIEW.md` | adversarial review of the economics and the hook, with open items |

```
forge build
forge test
forge fmt --check
```

Compiler pinned in `foundry.toml`: `solc = "0.8.26"`, `evm_version = "cancun"`, `bytecode_hash = "none"`,
no `ffi`, no filesystem access. Dependencies are vendored as plain files under `lib/` (forge-std,
v4-core `src/` plus `test/utils/{CurrencySettler,LiquidityAmounts}.sol`, solmate `Owned.sol`); there are
no submodules and the build needs no network.

---

## 1. What the brief asked and what was built

| Brief | Built | Where |
| --- | --- | --- |
| WIN, 1e9 supply, 18 decimals, no owner/mint/upgrade | `WinToken`: plain ERC-20, constructor mints the whole supply to `msg.sender` | `src/WinToken.sol` |
| Pair WIN/IMD on the launch chain's DEX (Uniswap v4 hook) | `WinGameHook`, bound at pool initialization to exactly one pool: WIN against one other currency | `beforeInitialize` |
| Fee on every buy and sell, always in IMD | Taken from the IMD input on buys and the IMD output on sells, for all four swap shapes | `beforeSwap`, `afterSwap` |
| Anti-snipe: 50% → 3% linearly over 30 minutes | `feePipsAt(t)`; see §3 for why the curve was kept linear | `_feePipsAt` |
| Split 90% bank / 10% team, team pulls | `bank`, `teamOwed`, `claimTeamFees()` pays only the fixed team wallet | `_accrue`, `claimTeamFees` |
| Bank starts empty, filled only by fees | No seeding path exists; the only inflow is `_accrue` from `afterSwap` | — |
| Qualifying buy = gross IMD ≥ current minimum; becomes leader, timer → 10 min | `_qualify` | `afterSwap` |
| Minimum = max(8.5 IMD, 20% of upcoming prize) × 1.05 per qualifying buy, reset per round | `minimumBuy()`; escalator reset in `_finalize` | — |
| Sells never reset the timer or change the leader | Sell path only accrues the fee | `afterSwap` |
| `settle()` by anyone after expiry; prize to leader; rest stays | `settle()`; lazy close on the next buy; `claimPrize()` for lazily closed rounds | §4 |
| Round 1: not before 3 h after launch, prize 20%; later rounds 5% | `FIRST_ROUND_MIN_DURATION`, `FIRST_ROUND_PRIZE_BPS`, `PRIZE_BPS` | `_qualify`, `_prizeBps` |
| Bot defences | Lazy finalization, full-timer reset, escalation, no shrinking window; analysis in §5 | — |
| Robust buyer identity | `hookData` first, `tx.origin` fallback; trade-offs in §6 | `_resolveTrader` |
| Website views | `gameState()`, `bankBalance()`, `nextPrize()`, `minimumBuy()`, `leader()`, `timeLeft()`, `roundNumber()`, `pastWinners()` and friends | §8 |
| Launch: 90% of supply into the pool single-sided, 0% to requester, 2,500 IMD starting market cap | Launch-factory parameters, documented in §9; the token mints 100% to the factory and the factory splits | §9 |

**What the brief asked that the token does not do.** Nothing; the brief asked for a plain token and
the launch policy requires one. All fee and game logic lives in the hook, which is the only place the
launch admits it.

---

## 2. Hook configuration (Wizard canonical record)

```json
{
  "hook": "BaseHook",
  "name": "WinGameHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": true,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterAddLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": true,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": true,
    "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "none (the brief forbids owner powers; no Ownable/roles/managed)",
  "info": { "license": "MIT" }
}
```

The hook is written against v4-core directly (no v4-periphery `BaseHook`): it implements `IHooks`
in full, reverts `HookNotImplemented` on the nine callbacks it does not enable, checks
`msg.sender == poolManager` on every enabled one, and validates its own address bits in the
constructor with `Hooks.validateHookPermissions`. Address flags: `0x20CC`
(`BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | BEFORE_SWAP_RETURN_DELTA | AFTER_SWAP_RETURN_DELTA`).
`CurrencySettler` is not used because the hook never settles a debt: it only mints claims, and burns
them against a `take` in its own unlock callback.

**Why `beforeSwapReturnDelta` (the CRITICAL flag) is enabled.** The fee must always be in IMD. When
IMD is the *specified* currency (exact-input buy, exact-output sell) the only place a hook can move
IMD is the specified delta in `beforeSwap`. The returned delta is always strictly smaller than the
swap amount (fee ≤ 50%) and the hook never returns a delta on the unspecified side from `beforeSwap`,
so it cannot "no-op" a swap and keep the input. `afterSwap` additionally verifies that the pool
filled the full amount (`PartialFillNotSupported` otherwise), so a fee is never charged on a trade
that did not happen.

Constructor: `(IPoolManager poolManager, address token)` → manifest `"$poolManager"`, `"$token"`.
The token must already have code (the factory deploys it first). The IMD address is **not** a
constructor argument: the hook reads "the currency that is not WIN" from the `PoolKey` in
`beforeInitialize`, which also records `launchTime`.

---

## 3. Fee

`fee(t) = 500_000 − 470_000 · min(t − launch, 1800) / 1800` pips (1e6 = 100%), i.e. 50% at launch,
26.5% after 15 minutes, 3% from 30 minutes on. `launch` is the pool initialization timestamp.

Per swap shape (f = fee rate, D = 1e6):

| Swap | Specified | Where the fee is taken | Formula |
| --- | --- | --- | --- |
| Buy, exact input (IMD in) | IMD | `beforeSwap` specified delta | `fee = in · f / D`; pool swaps `in − fee` |
| Buy, exact output (WIN out) | WIN | `afterSwap` unspecified delta | `fee = poolIn · f / (D − f)`, charged on top |
| Sell, exact input (WIN in) | WIN | `afterSwap` unspecified delta | `fee = poolOut · f / D`, taken from the output |
| Sell, exact output (IMD out) | IMD | `beforeSwap` specified delta | `fee = out · f / (D − f)`; pool pays `out + fee`, user gets `out` |

In every case the fee is exactly `f` of the gross IMD that the user pays or the pool pays out.
The *qualifying amount* of a buy is that gross IMD (fee included), which is also what the website
shows as the minimum.

**Why the curve stayed linear.** The brief invites a better curve. A convex (exponential) decay
front-loads the drop, which is exactly when snipers act, so it weakens the deterrent. A step or
cliff gives bots a precise instant to target. A concave curve (slow start) deters more but is
indistinguishable from "a longer window at a higher fee", which the brief could have asked for. The
linear ramp is predictable, has no cliff, and every IMD a sniper overpays lands in the bank, which
is the game's own prize. It was kept as specified. If the team wants a stronger deterrent, raising
`LAUNCH_FEE_PIPS` or `FEE_DECAY_DURATION` is a one-constant change with no other effect.

**Fee custody.** Fees are minted to the hook as ERC-6909 claims on the PoolManager
(`poolManager.mint`). At the time `afterSwap` runs the swapper's router has not settled, so a
`take` would be paid from whatever IMD the manager already holds, and on a pool seeded with WIN
only that is zero for the first buy. Claims need no balance. They are redeemed only on payout:
`settle()`, `claimPrize()` and `claimTeamFees()` unlock the manager, burn claims and `take` the
tokens to the recipient. The manager's token balance always covers outstanding claims, so this
cannot fail for a standard ERC-20. `test_firstBuyWorksWhenManagerHoldsNoImd` covers the fresh-
manager case.

**Split.** `team = fee / 10`, `bank += fee − team`. The team's share can only be sent to
`TEAM_WALLET = 0x611F08c7226591708B5F53F29BF53f3830D54511`, a compile-time constant. Anyone may
trigger `claimTeamFees()`; the destination cannot change. If the team wallet were a contract that
rejects IMD transfers (impossible for a standard ERC-20; relevant only if the pair were native),
only the team's own claim would revert; swaps are unaffected because swaps never transfer.

---

## 4. Game

State: `roundsStarted`, `roundActive`, `leader`, `deadline`, `qualifyingBuysInRound`, `escalator`,
`bank`, `teamOwed`, `unclaimedPrize[winner]`, `pastWinners`.

- **Qualifying buy.** A buy (IMD → WIN) whose gross IMD ≥ `minimumBuy()` evaluated *before* this
  buy's fee enters the bank (what the website displayed). It sets `leader`, restarts the timer
  (`deadline = now + 10 min`, round 1: `max(that, launch + 3 h)`), increments the count and
  multiplies the escalator by 1.05. If no round is active, it starts one.
- **Minimum.** `max(8.5 IMD, 20% · nextPrize()) · escalator`. `nextPrize()` is 20% of the bank
  for round 1, 5% afterwards, so the prize-linked part moves with the bank even between qualifying
  buys (sells and small buys raise it slightly; that is by design, the brief ties it to the
  *upcoming* prize). The escalator is reset to 1 whenever a round closes and capped at 1e18× so
  the arithmetic can never overflow.
- **Settlement.** `settle()` (anyone) requires an active round whose deadline has passed. It moves
  the prize out of the bank, records the winner, resets the round and pays the winner in the same
  transaction. **Lazy close:** a *buy* that arrives at or after the deadline first closes the
  expired round for its real leader (prize credited to `unclaimedPrize[leader]`, payable by anyone
  via `claimPrize(leader)`), and only then is judged against the fresh minimum of the next round.
  Sells never close a round; the brief says sells do not touch the game, and `settle()` is open to
  anyone anyway.
- **Prize.** `bank · 20% / 5%` *at the moment the round closes*, before the closing buy's fee is
  accrued. The rest of the bank stays. `test_snipe_settleAndLazyCloseAgreeOnThePrize` shows both
  paths pay the same amount.
- **Round 1.** Starts with the first qualifying buy, whenever that is. Its deadline is never
  earlier than `launch + 3 h`; once past that point, the ordinary 10-minute rule applies.
- **No admin.** There is no function that moves IMD anywhere except `settle`/`claimPrize` (to a
  recorded winner) and `claimTeamFees` (to the constant wallet). Nothing is pausable or upgradable;
  the runtime contains no `DELEGATECALL`/`SELFDESTRUCT` (tested).

Conservation invariant (asserted after every step of the fuzz test):
`claims(hook) == bank + teamOwed + Σ unclaimedPrize`, and over a whole run
`Σ fees == bank + Σ payouts`.

---

## 5. Bots: what works, what does not, and the defences

| Strategy | Does it win reliably? | Defence |
| --- | --- | --- |
| **Post-expiry snipe**: buy after the deadline but before anyone calls `settle()`, becoming "leader" of a dead round | Would, naively | **Lazy finalization.** Any buy at `t ≥ deadline` closes the round for the existing leader first. The sniper can only open the next round. Tested in `test_snipe_*`. |
| **Last-second snipe**: buy at `deadline − 1 s` | No | The timer always restarts to a **full 10 minutes**. There is no shrinking window, so a fast reaction buys nothing but the right to be overtaken. The sniper also pays the escalated minimum and the fee. |
| **Block stuffing**: after taking the lead, fill every block so nobody can answer | Only if ~10 minutes of full blocks cost less than the prize | The full reset makes this a 10-minute effort, not a few-block one, every time. On an OP-stack L2 at a 2 s block time that is ~300 consecutive full blocks with the base fee climbing the whole way; on mainnet ~50 blocks at ~30M gas each. The prize is only 5% of the bank (20% in round 1), so the bank would have to be more than 20× the stuffing cost. This residual risk is documented, not eliminated: no contract rule can see a stuffed block. The escalating minimum makes a failed attempt expensive to repeat. |
| **Sequencer ordering / same-block race**: several qualifying buys land in the final seconds; the sequencer decides who is last | The ordering is decided off-chain | Not solvable in the hook. Both FCFS and priority-fee ordering give the same answer to everyone; what the hook guarantees is that the loser of the race gets a full 10 minutes to answer and that the price of each further overtake rises 5%. On a chain with a private mempool there is no public view of the competing buy. |
| **Sandwiching the leader**: front-run or back-run a qualifying buy | No benefit | Qualification is measured in gross IMD, not in WIN received, so price manipulation cannot disqualify a buy. Back-running with one's own qualifying buy is just another buy (pays the higher minimum, restarts the timer, can be answered). Front-running leaves the victim as leader. |
| **Flash-loan buy** | No | Leading pays nothing immediately; the prize needs 10 quiet minutes. Buying and selling back in one transaction pays the fee twice (≥ 6%) and gains nothing. |
| **Fake identity via hookData** | No gain | Naming someone else in `hookData` only gifts them the lead. `address(0)` and malformed data fall back to `tx.origin`. |
| **Griefing with tiny buys** | No | Buys below the minimum change nothing except the bank. |
| **Settle inside a swap / re-enter payouts** | No | Payouts run inside the hook's own `unlock`, which the manager refuses while another unlock is open (`AlreadyUnlocked`), and `settle`/`claimPrize`/`claimTeamFees` share a reentrancy guard. Tested with a router that settles from its callback and with a token that calls back into the recipient. |
| **Sequencer censorship** | The operator can | Out of scope for any contract; stated as a trust assumption of the selected chain. |

**Net:** a round ends only when nobody at all is willing to pay the current minimum for 10 minutes.
That is an auction, and bots can bid in auctions; what they cannot do is end a round on their own
terms or claim a round they did not lead.

---

## 6. Who is the buyer?

The PoolManager hands the hook `sender` = the router (Universal Router, an aggregator, a custom
contract), never the user. Options considered:

| Source | Pros | Cons |
| --- | --- | --- |
| `sender` (router) | Always correct as an address | Is the router: the prize would land in the Universal Router and be swept by anyone. Rejected. |
| `hookData` (router forwards user-supplied bytes) | Exact, works for smart-contract wallets, relayers, 4337 bundlers | Only present when the front end sets it; user-controlled, so it can name anyone (harmless: it only gifts the lead) |
| `tx.origin` | Present on every transaction; for a plain wallet trade through any router it *is* the buyer | For a 4337 smart account the bundler becomes leader; for a relayed/meta transaction the relayer does. Explicitly not used for authorization anywhere. |
| Router allowlist | Could force a trusted router that always sets hookData | Requires an admin to maintain the list; the brief forbids owner powers. Rejected. |

**Chosen:** `hookData` when it is a 32-byte ABI-encoded address with clean upper bits or a packed
20-byte address and non-zero; otherwise `tx.origin`. The website must always pass
`abi.encode(buyer)` as the swap's `hookData` (the Universal Router's `V4_SWAP` actions carry it per
swap). Smart-account users and anyone trading through a relayer **must** use the website or set
`hookData` themselves; a direct trade from a plain wallet through any router still attributes
correctly through the fallback. All six cases are tested (`test_identity_*`).

---

## 7. Assumptions

- **Chain and addresses.** No `network.json` was pinned to this task, so the selected chain, its
  PoolManager and the IMD token are **deployment parameters**, not source constants. The hook takes
  the PoolManager in the constructor and discovers IMD from the pool. The tests deploy their own
  PoolManager and a mock IMD; nothing in them depends on chain state, so the same suite runs
  unchanged against a fork with `forge test --fork-url <rpc>` once an RPC is available (the
  verifier runs offline, which is why no test requires one).
- **IMD is a standard ERC-20**: no fee on transfer, no rebasing, no blocklist, no transfer hooks. A
  fee-on-transfer IMD would make `take` deliver less than the recorded prize; a blocklisted winner
  could not be paid (their own `claimPrize` would revert; nothing else would). The pair may also be
  the native currency (tested at initialization); then a contract winner that rejects ETH cannot
  receive its own prize and nothing else is affected.
- **Time.** All logic uses `block.timestamp`, which is correct on Arbitrum-style chains where
  `block.number` is not. The L2's timestamp granularity (1–2 s) is far below the 10-minute timer.
- **One pool.** The hook binds to the first pool initialized with it and refuses a second. The LP
  fee must be 500, 3000 or 10000 (the launch policy's tiers); the dynamic-fee flag and 0 are refused.
  The tick spacing is whatever the manifest sets (60 for the 0.3% tier).
- **Exact-output sells and exact-input buys that cannot be fully filled revert** rather than charging
  the full fee on a partial trade (`PartialFillNotSupported`). Routers that set the usual
  min/max price limits never hit this.
- **No randomness** is used anywhere; the winner is deterministic (last qualifying buyer).

---

## 8. Views for the website

| View | Meaning |
| --- | --- |
| `gameState()` | Everything below in one call |
| `bankBalance()` / `bank()` | IMD available as prize money |
| `nextPrize()` | What the current (or next) round would pay now: 20% of bank in round 1, 5% after |
| `minimumBuy()` | Gross IMD (fee included) a buy must spend now to take the lead |
| `leader()` | Current leader, `address(0)` between rounds |
| `timeLeft()` | Seconds until `settle()` is possible; 0 between rounds and once expired |
| `settleable()` | True when a round is over but not yet settled (show a "settle" button) |
| `roundNumber()` | The active round, or the number the next round will get |
| `roundActive()`, `deadline()`, `qualifyingBuysInRound()`, `escalator()` | Raw round state |
| `pastWinners()`, `winnersCount()`, `winnerAt(i)` | `(round, settledAt, winner, prize)` per settled round |
| `unclaimedPrize(addr)` | Prize decided by a lazy close and not yet picked up (`claimPrize(addr)`) |
| `currentFeePips()`, `feePipsAt(t)` | Trading fee now / at a time (1e6 = 100%) |
| `teamOwed()` | Team share waiting in the hook |
| `poolKey()`, `poolId()`, `imd()`, `winToken()`, `winIsCurrency0()`, `launchTime()` | Pool binding |

Events: `Launched`, `FeeCharged`, `RoundStarted`, `QualifyingBuy`, `RoundSettled`, `PrizePaid`,
`TeamFeesPaid`.

---

## 9. Launch and deployment parameters

The IdentityMD launch factory performs the launch; this repository does not broadcast anything.
What the manifest node needs:

| Parameter | Value |
| --- | --- |
| Token | `WinToken`, no constructor arguments, mints 10^27 to the factory |
| Hook constructor | `(IPoolManager "$poolManager", address "$token")` |
| Hook address flags | `0x20CC` (mine the salt with `HookFlags.mineSalt`) |
| Pool fee tier | `3000` (0.3%), tick spacing `60` |
| Pair | the chain's IMD token |
| Supply split | 90% (900,000,000 WIN) to the pool, 0% to the requester, remainder per launch policy |
| Liquidity | single-sided WIN only, no IMD, no ETH |
| Starting market cap | 2,500 IMD ⇒ 2.5 × 10⁻⁶ IMD per WIN |

Starting price: `price = 2500 / 1e9 = 2.5e-6` IMD per WIN. If WIN is `currency0`
(`address(WIN) < address(IMD)`) the pool price is `IMD/WIN = 2.5e-6`, tick ≈ −128,999, rounded to
spacing **−129,000**, `sqrtPriceX96 = sqrt(2.5e-6) · 2^96 ≈ 1.2536e26`, and the WIN-only position
sits in `[−128,940, 887,220]`. If WIN is `currency1` the price is `WIN/IMD = 400,000`, tick
**+129,000**, position `[−887,220, 128,940]`. The test fixture does exactly this for both orderings.
The address ordering is only known once the token address is known, so the factory computes it.

Reference script: `script/DeployWin.s.sol`. `deploy(Config)` deploys the token and then the hook at
a mined address; `run()` reads `POOL_MANAGER` from the environment and, because Foundry routes
salted creates through the deterministic deployer while broadcasting, mines against that address.
It is for rehearsals on a local node; the launch itself goes through the factory.

---

## 10. Operational responsibilities

| Who | What |
| --- | --- |
| Launch factory / deployer | Supply `$poolManager` and `$token`; mine the salt; initialize the pool at the price above at fee tier 3000; seed 90% single-sided. Initialization timestamp is the launch time for the fee decay and the 3-hour floor, so initialize and seed in one transaction. |
| Website | Pass `abi.encode(buyer)` as `hookData` on every swap. Show `minimumBuy()` as the amount to spend *including* the fee. Offer `settle()` when `settleable()`; offer `claimPrize(addr)` when `unclaimedPrize(addr) > 0`. |
| Team | Call `claimTeamFees()` when desired (anyone can). The wallet is fixed; losing its key loses future team fees, not the bank. |
| Anyone / keeper | `settle()` after expiry so winners are paid promptly; otherwise the next buy closes the round and the winner pulls with `claimPrize`. |
| Independent reviewer | Read `docs/REVIEW.md`; the open items there (chain-specific IMD behaviour, fork rehearsal, external audit) must be closed before funds are at stake. |

There is nothing to pause, upgrade, or rescue. If the IMD token on the selected chain turns out
not to be a standard ERC-20, do not launch with this hook.

---

## 11. Tests

`forge test` runs 134 tests in about a second: token (10), fees (16 × 2 orientations), game
(36 × 2 orientations), security and initialization (15), reentrancy (3), deploy script (2). Every
hook suite runs with WIN as `currency0` and again as `currency1`. The brief's list maps to:

| Requirement | Tests |
| --- | --- |
| Anti-snipe decay | `test_feeDecay_*`, `testFuzz_feeDecay_neverOutsideBounds` |
| Fee always in IMD, both sides, all shapes | `test_buyExactIn_*`, `test_buyExactOut_*`, `test_sellExactIn_*`, `test_sellExactOut_*`, `test_feesAtLaunchRateOnBothSides`, fuzz variants |
| 90/10 split and team pull | `test_feeSplit_*`, `test_teamFees_arePullBasedToFixedWallet` |
| First round 3 h floor and 20% | `test_firstRound_*` |
| 10-minute reset | `test_laterRounds_tenMinuteTimerAndResets` |
| 8.5 IMD floor, rising, resetting | `test_minimumBuy_*` |
| Settle before/after expiry | `test_firstRound_cannotSettleBeforeThreeHours`, `test_settle_*` |
| 5% later prizes | `test_laterRounds_prizeIsFivePercent`, `test_multipleRoundsAccumulateWinners` |
| Sells don't affect the game | `test_sells*` |
| Reentrancy | `WinGameHookReentrancyTest`, `test_settleCannotRunInsideAManagerLock` |
| End-of-round sniping | `test_snipe_*` |
| Buyer identity | `test_identity_*` |
| Pool initialization and unauthorized callbacks | `test_initialize_*`, `test_enabledCallbacksRefuse*`, `test_disabledCallbacksRevert` |
| Fresh manager, token-only pool | `test_firstBuyWorksWhenManagerHoldsNoImd` |
| Conservation | `testFuzz_fundsAreConserved`, `assertAccounting()` throughout |

Tests pass in any order and in parallel, read no environment variables and set none. The pinned
IdentityMD floor suites (`Hook.protected.t.sol`, `Token.protected.t.sol`) were run locally against
this exact creation code and pass; they expect `src/HookFlags.sol` and `test/mocks/MockERC20.sol`
at those paths, which is why both exist.

Tests are not an audit. See `docs/REVIEW.md`.
