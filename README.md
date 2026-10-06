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
| Reference deploy | `script/DeployWin.s.sol` | `deploy(Config)` is what the tests call; `run()` only reads the environment |
| Tests | `test/` | 179 tests, both pool orientations, fuzz and reentrancy |
| Review | `docs/REVIEW.md` | adversarial review of the economics and the hook, the independent review's findings and their disposition, open items |

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
| Pair WIN/IMD on the launch chain's DEX (Uniswap v4 hook) | `WinGameHook`, bound at pool initialization to exactly one pool: WIN against one 18-decimal currency, started at the briefed 2,500 IMD market cap for the ordering the pool has | `beforeInitialize` |
| Fee on every buy and sell, always in IMD | Taken from the IMD input on buys and the IMD output on sells, for all four swap shapes | `beforeSwap`, `afterSwap` |
| Anti-snipe: 50% → 3% linearly over 30 minutes | `feePipsAt(t)`; see §3 for why the curve was kept linear | `_feePipsAt` |
| Split 90% bank / 10% team, team pulls | `bank`, `teamOwed`, `claimTeamFees()` pays only the fixed team wallet | `_accrue`, `claimTeamFees` |
| Bank starts empty, filled only by fees | No seeding path exists; the only inflow is `_accrue` from `afterSwap` | — |
| Qualifying buy = gross IMD ≥ current minimum; becomes leader, timer → 10 min | `_qualify` | `afterSwap` |
| Minimum = max(8.5 IMD, 20% of upcoming prize) × 1.05 per qualifying buy, reset per round | `minimumBuy()`; escalator reset in `_finalize` | — |
| Sells never reset the timer or change the leader | Sell path only accrues the fee | `afterSwap` |
| `settle()` by anyone after expiry; prize to leader; rest stays | `settle()` always closes the round; the prize is pushed, or left claimable (`claimPrize()`) if the token refuses the winner; lazy close on the next buy | §4 |
| Round 1: not before 3 h after launch, prize 20%; later rounds 5% | `FIRST_ROUND_MIN_DURATION`, `FIRST_ROUND_PRIZE_BPS`, `PRIZE_BPS` | `_qualify`, `_prizeBpsFor` |
| Bot defences | Lazy finalization, full-timer reset, escalation, no shrinking window, "must lead" flag against voided challenges; analysis in §5 | — |
| Robust buyer identity | `hookData` first, then the router's `msgSender()`, then `tx.origin`; trade-offs in §6 | `_resolveTrader` |
| Website views | `gameState()`, `bankBalance()`, `nextPrize()`, `minimumBuy()`, `leader()`, `timeLeft()`, `roundNumber()`, `pastWinners()`, `pendingPrize()` and friends; all consistent with what `afterSwap` enforces, including while an expired round waits for `settle()` | §8 |
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
`beforeInitialize`, which also records `launchTime`. `beforeInitialize` refuses the pool unless
the paired currency reports 18 decimals (or is native) and the starting price is the briefed
market cap for the ordering the pool actually has (§9); a mispriced or mis-paired initialization
reverts instead of binding the hook to an unusable pool.

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
- **"Must lead" flag.** Because the minimum can move between the quote and execution (another
  fee grows the bank, a qualifying buy lands first, a sell shifts the pool price under an
  exact-output buy), a buy that falls short at execution time would otherwise go through as an
  ordinary fee-paying buy with no lead. A buyer who passes `abi.encode(buyer, true)` as `hookData`
  has the whole swap reverted (`NotQualifying(minimum, gross)`) in that case: a voided challenge
  then costs gas, not a fee. The website always sets the flag. Without it the brief's literal rule
  applies (the buy executes, the fee is banked, nothing else happens). The flag on a sell reverts.
- **Settlement.** `settle()` (anyone) requires an active round whose deadline has passed. It moves
  the prize out of the bank, records the winner, resets the round and pushes the prize to the
  winner in the same transaction. If the IMD transfer to the winner fails (a token blocklist, a
  recipient that rejects it) the round still closes: the prize stays in `unclaimedPrize[winner]`,
  `PrizeDeferred` is emitted, and the winner (or anyone for them) pulls it later with
  `claimPrize(winner)`. One unpayable leader can therefore never freeze settlement.
  **Lazy close:** a *buy* that arrives at or after the deadline first closes the
  expired round for its real leader (prize credited to `unclaimedPrize[leader]`, payable by anyone
  via `claimPrize(leader)`), and only then is judged against the fresh minimum of the next round.
  Sells never close a round; the brief says sells do not touch the game, and `settle()` is open to
  anyone anyway.
- **Views while a round waits for `settle()`.** Between the deadline and `settle()` (or the next
  buy), `minimumBuy()`, `nextPrize()` and `roundNumber()` already describe the *next* round, which
  is exactly what the next buy is judged against: bank minus the pending prize, the next round's
  prize share, escalator reset. `pendingPrize()`, `settleable()` and the `pending*` fields of
  `gameState()` describe the round that is closing. The raw getters (`leader()`, `deadline()`,
  `roundActive()`, `escalator()`) keep reporting storage as is.
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
| **Block stuffing**: after taking the lead, fill every block so nobody can answer | Only if ~10 minutes of full blocks cost less than the prize | The full reset makes this a 10-minute effort, not a few-block one, every time. On an OP-stack L2 at a 2 s block time that is ~300 consecutive full blocks with the base fee climbing the whole way; on mainnet ~50 blocks at ~30M gas each. The prize is only 5% of the bank (20% in round 1), so the bank would have to be more than 20× the stuffing cost. This residual risk is documented, not eliminated: no contract rule can see a stuffed block, and the brief fixes the prize at 5% of the bank and the timer at 10 minutes. Mechanical options that change those numbers (an absolute prize cap, a prize cap as a multiple of the leader's buy, a timer that lengthens with the bank) are listed for the requester in `docs/REVIEW.md` E10. The escalating minimum makes a failed attempt expensive to repeat. |
| **Sequencer ordering / same-block race**: several qualifying buys land in the final seconds; the sequencer decides who is last | The ordering is decided off-chain | Not solvable in the hook. Both FCFS and priority-fee ordering give the same answer to everyone; what the hook guarantees is that the loser of the race gets a full 10 minutes to answer and that the price of each further overtake rises 5%. On a chain with a private mempool there is no public view of the competing buy. |
| **Voiding a challenger**: land any fee-paying trade (a dust buy, a sell, a re-qualifying buy) just before a challenger's buy so the minimum has moved and the challenger falls short | Would convert the challenger's buy into a fee-paying non-qualifying buy | The **"must lead" flag** (§4): a flagged buy that does not take the lead reverts entirely, so the challenger pays gas and nothing else, and the leader gains nothing from the front-run. The website always sets the flag. |
| **Sandwiching the leader**: front-run or back-run a qualifying buy | No benefit | Qualification is measured in gross IMD, not in WIN received, so a worse price never disqualifies an exact-input buy; an exact-output buy's gross *can* be pushed under the minimum by a sell in front, and the flag turns that into a revert instead of a lost fee. Back-running with one's own qualifying buy is just another buy (pays the higher minimum, restarts the timer, can be answered). |
| **Buy and sell back** (also with a flash loan) | Takes the lead, does not win | A qualifying buy sold straight back costs about 6.5% of the minimum after the decay (two 3% hook fees, two 0.3% LP fees, slippage: 0.55 IMD on the 8.5 IMD floor, measured in `docs/REVIEW.md` E8) and leaves the buyer as leader with a full 10-minute timer. That is the brief's rule as written: the lead is bought with swap volume, not with a held position. Winning still needs 10 quiet minutes, 90% of what the resetter pays lands in the bank they are competing for, and the escalation still ends every round. Two mechanical alternatives (void the lead when the leader sells during the round; make part of the qualifying amount non-recoverable) change the brief's rule and are listed for the requester in `docs/REVIEW.md` E8. |
| **Fake identity via hookData** | No gain | Naming someone else in `hookData` only gifts them the lead. `address(0)` and malformed short payloads fall through to the router's `msgSender()`, then `tx.origin`; a malformed 64-byte payload reverts. |
| **Griefing with tiny buys** | No | Buys below the minimum change nothing except the bank, and through the bank the prize-linked minimum by the same tiny proportion (by the brief's definition of "20% of the upcoming prize"). The flag keeps that from costing a challenger anything but gas. |
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
| `sender` (router) as the buyer | Always correct as an address | Is the router: the prize would land in the Universal Router and be swept by anyone. Rejected. |
| `hookData` (router forwards user-supplied bytes) | Exact, works for smart-contract wallets, relayers, 4337 bundlers; carries the "must lead" flag | Only present when the front end sets it; user-controlled, so it can name anyone (harmless: it only gifts the lead) |
| `sender.msgSender()` (the router reports who called it) | The Universal Router and the v4-periphery routers expose it exactly for hooks; returns the *paying account* (the smart account behind a 4337 bundler, the sponsored 7702 account, the Safe, the vault), not the signer; needs no owner and no list | Only routers that implement it; a router can lie (harmless: it only gifts the lead); a meta-transaction forwarder that calls the router is reported as the forwarder |
| `tx.origin` | Present on every transaction; for a plain wallet trade through any router it *is* the buyer | For a 4337 smart account through a router without `msgSender()` the bundler is credited; for a relayed/meta transaction the relayer is. Explicitly not used for authorization anywhere. |
| Router allowlist | Could force a trusted router that always sets hookData | Requires an admin to maintain the list; the brief forbids owner powers. Rejected. |
| No fallback at all | Nobody is ever mis-credited | A plain-wallet buy through any third-party interface could never lead, although it pays the fee; the game would exist only on the website. Rejected in favour of the layered order below. |

**Chosen order:** (1) `hookData`: `abi.encode(buyer, mustLead)` (64 bytes; malformed payloads
revert so the flag can never be dropped silently), `abi.encode(buyer)` (32 bytes, clean upper bits)
or a packed 20-byte address, non-zero; (2) a gas-capped `staticcall` of `msgSender()` on the router
the PoolManager reports as `sender`, accepted only if it returns one clean 32-byte word (a router
that reverts, has no such function or answers with dirty bits falls through); (3) `tx.origin`.
The website must always pass `abi.encode(buyer, true)` as the swap's `hookData` (the Universal
Router's `V4_SWAP` actions carry it per swap). A smart account trading through the Universal Router
without the website is still credited correctly via (2). **Residual:** a smart account, relayed or
keeper-driven buy through a router that neither forwards `hookData` nor implements `msgSender()` is
credited to the transaction signer. Such users must use the website or a router that reports its
caller. All cases are tested (`test_identity_*`, including a 4337-style trade through a
`msgSender()` router, a lying router, a reverting router and the documented residual).

---

## 7. Assumptions

- **Chain and addresses.** No `network.json` was pinned to this task, so the selected chain, its
  PoolManager and the IMD token are **deployment parameters**, not source constants. The hook takes
  the PoolManager in the constructor and discovers IMD from the pool. The tests deploy their own
  PoolManager and a mock IMD; nothing in them depends on chain state, so the same suite runs
  unchanged against a fork with `forge test --fork-url <rpc>` once an RPC is available (the
  verifier runs offline, which is why no test requires one).
- **IMD is a standard 18-decimal ERC-20**: no fee on transfer, no rebasing, no transfer hooks.
  `beforeInitialize` verifies `decimals() == 18` (the 8.5 IMD floor is a raw `8.5e18`) and refuses
  the pool otherwise, so a non-18-decimal pair fails at launch instead of locking fees forever. A
  fee-on-transfer IMD would make `take` deliver less than the recorded prize. A winner the token
  refuses to credit (blocklist) does not block anything: `settle()` closes the round and leaves
  their prize claimable; only their own `claimPrize` reverts until the token allows the transfer.
  The pair may also be the native currency (tested at initialization; 18 decimals by definition);
  then a contract winner that rejects ETH has its prize deferred the same way.
- **Time.** All logic uses `block.timestamp`, which is correct on Arbitrum-style chains where
  `block.number` is not. The L2's timestamp granularity (1–2 s) is far below the 10-minute timer.
- **One pool, at the briefed price.** The hook binds to the first pool initialized with it and
  refuses a second. The LP fee must be 500, 3000 or 10000 (the launch policy's tiers); the
  dynamic-fee flag and 0 are refused. The tick spacing is whatever the manifest sets (60 for the
  0.3% tier). The starting price must be within ±300 ticks (about ±3%) of the 2,500 IMD market cap
  for the ordering the pool has (§9); any other price, including the right number for the other
  ordering, reverts with `WrongStartingPrice`.
- **Deploy and initialize atomically.** `beforeInitialize` cannot tell the factory from a stranger:
  it has no owner, the manifest can fill only `$poolManager` and `$token`, and the factory may
  create the hook through a CREATE2 helper (so the constructor's `msg.sender` is not the account
  that later calls `initialize`) or initialize through a position manager (which holds no WIN), so
  neither an "initializer == deployer" rule nor a "holds the WIN supply" rule can be relied on
  without risking a dead launch. The launch factory deploys the hook and initializes the pool in
  one transaction, which leaves no window. Any other deployment must do the same: the reference
  script's `deploy(Config)` initializes in the same call when `initializePool` is set, and a hook
  left deployed but uninitialized could be bound by anyone to a WIN/<anything> pool at the launch
  price (making this hook unusable for the real pair) or to the real pair early (starting the fee
  decay and the 3-hour floor before liquidity exists).
- **Exact-output sells and exact-input buys that cannot be fully filled revert** rather than charging
  the full fee on a partial trade (`PartialFillNotSupported`). Routers that set the usual
  min/max price limits never hit this.
- **No randomness** is used anywhere; the winner is deterministic (last qualifying buyer).

---

## 8. Views for the website

| View | Meaning |
| --- | --- |
| `gameState()` | Everything below in one call; while an expired round waits for `settle()` the round fields are the next round's and `settleable`, `pendingRound`, `pendingWinner`, `pendingPrize` describe the closing one |
| `bankBalance()` / `bank()` | IMD available as prize money (including a pending, unsettled prize) |
| `nextPrize()` | What the round a buy would join now would pay: 20% of bank in round 1, 5% after; once the active round has expired, the next round's prize from the bank minus the pending prize |
| `minimumBuy()` | Gross IMD (fee included) a buy must spend now to take the lead; exactly what `afterSwap` enforces, also after the deadline |
| `pendingPrize()` | The prize the expired, unsettled round will pay its leader; 0 otherwise |
| `leader()` | Current leader (raw storage), `address(0)` between rounds; after the deadline it is the pending winner |
| `timeLeft()` | Seconds until `settle()` is possible; 0 between rounds and once expired |
| `settleable()` | True when a round is over but not yet settled (show a "settle" button) |
| `roundNumber()` | The round a buy would join now: the active round while its timer runs, otherwise the next round's number |
| `launchTick(bool)`, `launchSqrtPriceX96(bool)` | The starting tick / price the hook requires for a given ordering (`true` = WIN is currency0) |
| `roundActive()`, `deadline()`, `qualifyingBuysInRound()`, `escalator()` | Raw round state |
| `pastWinners()`, `winnersCount()`, `winnerAt(i)` | `(round, settledAt, winner, prize)` per settled round |
| `unclaimedPrize(addr)` | Prize decided by a lazy close and not yet picked up (`claimPrize(addr)`) |
| `currentFeePips()`, `feePipsAt(t)` | Trading fee now / at a time (1e6 = 100%) |
| `teamOwed()` | Team share waiting in the hook |
| `poolKey()`, `poolId()`, `imd()`, `winToken()`, `winIsCurrency0()`, `launchTime()` | Pool binding |

Events: `Launched`, `FeeCharged`, `RoundStarted`, `QualifyingBuy`, `RoundSettled`, `PrizePaid`,
`PrizeDeferred`, `TeamFeesPaid`.

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

Starting price: `price = 2500 / 1e9 = 2.5e-6` IMD per WIN, tick `log_1.0001(2.5e-6) = −128,992.6`,
rounded to **±129,000**, which every launch tier's spacing (10, 60, 200) divides. A v4 price is
`currency1 / currency0`, so the number depends on the ordering, which is only known once the token
address is known (the factory deploys the token first):

| Ordering | Condition | Pool price | Tick | `sqrtPriceX96` to pass to `initialize` | WIN-only position (spacing 60) |
| --- | --- | --- | --- | --- | --- |
| WIN is `currency0` | `address(WIN) < address(IMD)` | `IMD/WIN = 2.5e-6` | **−129,000** | **`125262255113908064987203232`** | `[−128,940, 887,220]` |
| WIN is `currency1` | `address(WIN) > address(IMD)` | `WIN/IMD = 400,000` | **+129,000** | **`50111677533496076234078224273595`** | `[−887,220, 128,940]` |

`launchSqrtPriceX96(address(WIN) < address(IMD))` on the hook returns the right value, and
**`beforeInitialize` enforces it**: it reads the ordering from the `PoolKey`, converts the supplied
price to a tick and reverts with `WrongStartingPrice` unless that tick is within ±300 of the
expected one. Passing the `currency0` number to a pool where WIN sorts above IMD (about 63% of
random token addresses) would otherwise have opened the pool at a 403,672,527,210,761 IMD market
cap, unusable and unfixable; now it reverts at initialization and the deployer flips the value. A
manifest that can only carry one `initialPrice` must therefore either be written after the token
address is known, or the factory must choose the token's CREATE2 salt so that WIN sorts below IMD.
`test_initialize_refusesThePriceOfTheOtherOrdering` and `test_launchPriceConstantsMatchTheManifest`
cover both numbers; the test fixture launches both orderings.

Reference script: `script/DeployWin.s.sol`. `deploy(Config)` deploys the token, then the hook at a
mined address, and with `initializePool` set also initializes the WIN/`pairedCurrency` pool at the
right price for the ordering in the same call. `run()` reads `POOL_MANAGER`, `IMD_TOKEN` and
`INITIALIZE_POOL` from the environment and, because Foundry routes salted creates through the
deterministic deployer while broadcasting, mines against that address. It is for rehearsals on a
local node; the launch itself goes through the factory. Note that a broadcast sends each call as its
own transaction, so a rehearsal on a public chain still has a window between the hook's creation
and `initialize` (§7, "Deploy and initialize atomically"); the factory has none.

---

## 10. Operational responsibilities

| Who | What |
| --- | --- |
| Launch factory / deployer | Supply `$poolManager` and `$token`; mine the salt; deploy the hook, initialize the pool at the price for the actual ordering (§9) at fee tier 3000 and seed 90% single-sided, **all in one transaction**. Initialization timestamp is the launch time for the fee decay and the 3-hour floor. Confirm the chain's IMD reports 18 decimals (the hook checks it and reverts otherwise). |
| Website | Pass `abi.encode(buyer, true)` as `hookData` on every buy (the flag reverts a buy that would not take the lead) and `abi.encode(buyer)` or nothing on sells. Show `minimumBuy()` as the amount to spend *including* the fee. Offer `settle()` when `settleable()`; show the `pending*` fields of `gameState()` as "round N ended, waiting for settle"; offer `claimPrize(addr)` when `unclaimedPrize(addr) > 0` (also after a `PrizeDeferred` event). |
| Team | Call `claimTeamFees()` when desired (anyone can; see `docs/REVIEW.md` E9 for why it is left open). The wallet is fixed; losing its key loses future team fees, not the bank. |
| Anyone / keeper | `settle()` after expiry so winners are paid promptly; otherwise the next buy closes the round and the winner pulls with `claimPrize`. Watch `PrizeDeferred`. |
| Independent reviewer | Read `docs/REVIEW.md`; the open items there (chain-specific IMD behaviour, fork rehearsal, external audit) must be closed before funds are at stake. |

There is nothing to pause, upgrade, or rescue. If the IMD token on the selected chain turns out
not to be a standard ERC-20, do not launch with this hook.

---

## 11. Tests

`forge test` runs 179 tests in a few seconds: token (10), fees (16 × 2 orientations), game
(53 × 2 orientations), security and initialization (22), reentrancy (3), unpayable winner (3),
deploy script (3). Every hook suite runs with WIN as `currency0` and again as `currency1`. The
brief's list maps to:

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
| Voided challenges and the "must lead" flag | `test_mustLead_*` (dust buy, leader re-qualifying, exact-output buy undercut by a sell, flag on a sell, flag after expiry) |
| Buyer identity | `test_identity_*` (hookData forms, router `msgSender()` for a 4337-style trade, lying/reverting/garbage routers, the `tx.origin` residual) |
| Views while a round waits for `settle()` | `test_views_*` |
| Settlement with an unpayable winner | `WinGameHookUnpayableWinnerTest` |
| Pool initialization, price and decimals checks, unauthorized callbacks | `test_initialize_*`, `test_launchPriceConstantsMatchTheManifest`, `test_enabledCallbacksRefuse*`, `test_disabledCallbacksRevert` |
| Fresh manager, token-only pool | `test_firstBuyWorksWhenManagerHoldsNoImd` |
| Conservation | `testFuzz_fundsAreConserved`, `assertAccounting()` throughout |

Tests pass in any order and in parallel, read no environment variables and set none. The pinned
IdentityMD floor suites (`Hook.protected.t.sol`, `Token.protected.t.sol`) were run locally against
this exact creation code and pass; they expect `src/HookFlags.sol` and `test/mocks/MockERC20.sol`
at those paths, which is why both exist.

Tests are not an audit. See `docs/REVIEW.md`.
