# Review: WIN game economics and `WinGameHook`

**Status of this document.** This is an adversarial review written by the same contributor who
wrote the code, from the brief, the `uniswap-v4-security` and `eth-security` checklists and the
v4-core source. It is structured so an independent reviewer can confirm or overturn each item. It
does **not** replace the separate independent review the brief and the launch policy require; see
"Open items" at the end.

Tools run: `forge build`, `forge test` (179 tests, fuzz at 256 runs), `forge fmt --check`, the
pinned IdentityMD floor suites against the attested creation code, the independent reviewer's
proof test. Slither/Mythril were not available in this environment.

Section E records the independent review's findings (received after the first acceptance), what
was reproduced, what changed and what was left as the requester's decision.

---

## A. Game economics

### A1. Is the game solvable by a bot? — Partially, by design; no free win

The round ends when nobody pays the minimum for 10 minutes. Every qualifying buy restarts the full
timer, so timing skill is worthless: the last-second buyer is simply the newest leader with 10
minutes on the clock. What decides a round is willingness to pay the escalating minimum, i.e. an
auction. Bots can bid; they cannot shorten the window (except by block stuffing, A3) and cannot
claim a round they did not lead (A2).

### A2. Post-expiry sniping — Fixed

Without lazy finalization a buy between `deadline` and `settle()` would overwrite `leader` and
steal the prize. The hook closes an expired round at the start of any buy's `afterSwap`, before
reading the minimum or the leader. Prize is computed on the bank *before* the closing buy's fee.
Confirmed by `test_snipe_buyAfterDeadlineCannotStealTheRound`, `..._buyExactlyAtDeadline...`,
`..._tinyBuyAfterDeadline...` and the snapshot comparison with `settle()`.

### A3. Block stuffing — Residual, quantified

Cost ≈ 10 minutes of full blocks. On a 2-second OP-stack chain with a ~100M+ gas block limit that is
≥ 3·10¹⁰ gas plus the EIP-1559 base-fee climb; the prize is 5% of the bank. Break-even needs a bank
of > 20× the stuffing cost. Mitigation is economic (small prize share, full reset, escalation), not
mechanical. Recommendation for the website: display the bank and prize prominently so that this
threshold is visible to everyone, which keeps the bank from quietly growing to an attack-worthy size
without the community noticing.

### A4. Escalation may stall the game — Expected (corrected by E7)

With prize 5% of the bank and minimum ≥ 20% of the prize = 1% of the bank, a round of *n*
qualifying buys costs the last buyer ≈ 1% · 1.05ⁿ of the bank *in swap volume* for a 5% prize.
Volume is recoverable: a buyer who sells straight back keeps only the fees and slippage, about
6.5% of the minimum after the decay (E7). Measured in that true cost, the minimum exceeds the
prize after ~89 overtakes rather than ~34; the cost is still exponential, so every round still
ends, which is the intent. The bank then grows only from ordinary trading until the next round.

### A5. Prize-linked minimum moves between qualifying buys — Accepted, with the "must lead" flag

`minimumBuy()` is tied to `nextPrize()`, which is tied to the live bank. Sells and sub-minimum
buys raise it slightly. The brief says "20% of the upcoming prize", which is live by definition.
A buy quoted at the displayed minimum can therefore fall short at execution and, under the
brief's literal rule, execute as an ordinary fee-paying buy. The website always sets the
"must lead" flag in `hookData`, which reverts such a buy entirely (E2). Snapshotting the
prize-linked base at round start / last qualifying buy, so that only visible 5% steps move the
minimum, would remove the drift altogether but changes "upcoming prize" from live to snapshot;
that is a requester decision and was not made here.

### A6. Round 1 incentive — Noted

Round 1 pays 20% and cannot end before 3 h. A single early qualifying buy with no competition
holds the lead until `launch + 3 h`. That is the brief's design: it lets the bank fill during the
anti-snipe window and gives the first wave of buyers a reason to compete. The first buyer at
launch pays the 50% fee, 90% of which is the prize they then compete for.

### A7. Leader can self-extend — Harmless

A leader may buy again and restart their own timer. It costs them the escalated minimum and fee
and only delays their own prize. No rule needed.

### A8. Team share — As specified

10% of every fee, pull-based, to a constant address. There is no way to redirect it. If the key
is lost, future team fees accumulate unclaimed in the hook forever; the bank is unaffected.

---

## B. Hook: v4 security checklist

| # | Check | Result |
| --- | --- | --- |
| 1 | Every callback verifies `msg.sender == poolManager` | Yes: `beforeInitialize`, `beforeSwap`, `afterSwap`, `unlockCallback`. Unused callbacks revert unconditionally. Tested. |
| 2 | Router allowlisting | Not applicable (no owner); identity via `hookData`, then the router's `msgSender()`, then `tx.origin`; never used for authorization. |
| 3 | Unbounded loops | None in callbacks. `pastWinners()` returns the whole array; it is a view for the website, paginate with `winnerAt` if it grows large. |
| 4 | Reentrancy guards | `settle`, `claimPrize`, `claimTeamFees` share a guard; payouts run in the hook's own `unlock`, which the manager refuses to nest. Tested with a callback token and a settle-in-callback router. |
| 5 | Delta accounting sums to zero | Fee minted in `afterSwap` (−fee for the hook) is offset by the hook delta the manager books after the callback (+fee). Payout: `burn` (+) then `take` (−). Fuzz + `assertAccounting` after every step. |
| 6 | Fee-on-transfer tokens | Not supported for IMD (assumption documented). WIN is plain. |
| 7 | Hardcoded addresses | Only `TEAM_WALLET`, which the brief dictates. PoolManager and token are constructor arguments; IMD is read from the pool. |
| 8 | Slippage respected | The hook adds to the user's debit (exact-output buy) or subtracts from the credit (exact-input sell) through the official return-delta path, so routers' min/max checks see the final numbers. Partial fills on the specified side revert instead of over-charging. |
| 9 | Sensitive data on-chain | None. |
| 10 | Upgrade mechanisms | None. No `DELEGATECALL`/`SELFDESTRUCT` in runtime (tested). |
| 11 | `beforeSwapReturnDelta` justified | Needed to take an IMD fee when IMD is the specified currency. Delta < amount always; never touches the unspecified side in `beforeSwap`. |
| 12 | Fuzz testing | Fee rate, decay bounds, exact-output sells, 24-step action sequences for conservation. |
| 13 | Invariant testing | Conservation invariant asserted inline; a standalone invariant campaign is an open item. |

Risk score (guide's rubric): permissions ≈ 10 (beforeSwapReturnDelta critical, afterSwapReturnDelta
high, beforeSwap high, afterSwap medium, beforeInitialize low), external calls 2 (manager only, plus
the token transfer inside `take`), state complexity 3, upgrade 0, token handling 2 → **≈ 17, High:
professional audit required before holding meaningful funds.**

---

## C. Specific findings

| ID | Severity | Finding | Status |
| --- | --- | --- | --- |
| C1 | High (design) | A buy after the deadline but before `settle()` could take the dead round. | Fixed: lazy finalization (A2). |
| C2 | High (ops) | Taking the fee with `take` during `afterSwap` reverts on a manager holding no IMD (fresh manager, WIN-only pool). | Fixed: fees are minted as ERC-6909 claims; test on a fresh manager. |
| C3 | Medium | Exact-output sells / exact-input buys with a price limit could be charged the full fee on a partial fill (user could even receive a negative IMD delta). | Fixed: `PartialFillNotSupported` revert; tests for both. |
| C4 | Medium | `tx.origin` fallback mis-attributes 4337 / relayed trades to the bundler or relayer. | Reduced (E3): the router's `msgSender()` is consulted before `tx.origin`, which attributes Universal Router / v4-periphery trades to the paying account. Residual: routers without `msgSender()` and without `hookData` credit the signer; documented in README §6. |
| C5 | Low | `minimumBuy()` could overflow after ~2,700 qualifying buys in one round, blocking buys (not settlement) for the rest of that round. | Fixed: escalator capped at 1e18×; tested. |
| C6 | Low | `pastWinners()` is unbounded. | Accepted: view only; `winnerAt(i)`/`winnersCount()` provided for pagination. |
| C7 | Low | Anyone can push the team's fees or a winner's lazy prize at any time (tax-timing nuisance). | Accepted: funds only ever go to the entitled address (see E9). |
| C8 | Info | ERC-6909 claims or raw IMD sent to the hook by third parties are ignored and stuck. | Accepted; no admin exists to sweep them, which is the brief's choice. |
| C9 | Info | Native-currency pair: a contract winner that rejects ETH cannot receive its own prize. | `settle()` now closes the round and defers the prize (E4); only that winner's own claim fails. The launch pair is the IMD ERC-20. |
| C10 | Info | Sells cannot execute until a buy has put IMD into the single-sided pool (pool-level revert). | Expected for a single-sided launch; tests buy first. |
| C11 | High | `beforeInitialize` accepted any starting price, so the manifest's single `initialPrice` (right only when WIN is currency0) would open an unusable pool when WIN sorts above IMD. | Fixed (E1): the hook derives the expected tick from the ordering it observes and reverts `WrongStartingPrice` outside ±300 ticks. |
| C12 | Low | The 8.5 IMD floor is a raw 8.5e18 and the paired currency's decimals were never checked. | Fixed (E7): `beforeInitialize` requires `decimals() == 18` (native counts as 18). |

---

## D. Open items for the independent reviewer / deployer

1. **Chain selection.** No `network.json` was pinned to this task. Confirm the selected chain, its
   PoolManager, the IMD token address, and that IMD is a plain 18-decimal ERC-20 there (no fee, no
   hooks). The hook checks the decimals and the starting price at initialization and refuses
   otherwise; a blocklist no longer blocks settlement (E4). The hook must not launch against
   anything else.
1a. **Manifest price vs. ordering.** `pool.initialPrice` must be `125262255113908064987203232`
   when the deployed WIN address sorts below IMD and `50111677533496076234078224273595` when it
   sorts above (README §9). The hook reverts a mismatch, so a wrong manifest fails loudly at launch
   instead of opening a dead pool; the manifest node must either write the price after the token
   address is known or pin the token's CREATE2 salt so WIN sorts below IMD.
2. **Fork rehearsal.** Run `forge test --fork-url <rpc>` on the selected chain; the suite is
   chain-agnostic and needs no changes. Then rehearse the factory's own initialize-and-seed
   transaction against the real PoolManager with the mined hook address and check that the first buy
   (50% fee, zero IMD in the manager) succeeds, as `test_firstBuyWorksWhenManagerHoldsNoImd` does
   locally.
3. **Sequencer behaviour.** Confirm ordering policy (FCFS vs priority fee) and block gas limit on
   the selected chain to refine the block-stuffing break-even in A3 and decide whether the prize
   share should be lowered further for that chain.
4. **External audit** of the hook (risk ≈ High per the rubric) before the bank is allowed to hold
   funds that would hurt to lose.
5. **Monitoring.** Watch `RoundSettled` vs `PrizePaid`/`claimPrize` for lazily closed rounds whose
   winners have not pulled, and the `teamOwed` balance.

---

## E. Independent review: findings, reproduction and disposition

Each finding was re-run on the accepted tree before anything was changed. "Fixed" means the
behaviour changed and a regression test was added; "requester decision" means the behaviour is the
brief's rule as written and the alternative changes that rule.

### E1. Starting price not checked against the ordering — High — Fixed

Reproduced with the reviewer's proof (WIN deployed at an address above IMD, the manifest's
`currency0` price passed as written): the hook bound itself to a pool whose first WIN sold at a
403,672,527,210,761 IMD market cap. `beforeInitialize` now converts the supplied `sqrtPriceX96` to
a tick and requires it within ±300 ticks of −129,000 (WIN is currency0) or +129,000 (WIN is
currency1); otherwise `WrongStartingPrice(sqrtPriceX96, tick, expectedTick)`. `launchTick(bool)`
and `launchSqrtPriceX96(bool)` expose the expected values. The proof passes; new tests:
`test_initialize_refusesThePriceOfTheOtherOrdering`, `test_initialize_refusesPricesOutsideTheTolerance`,
`test_initialize_acceptsPricesInsideTheTolerance`, `test_launchPriceConstantsMatchTheManifest`.
The README's "≈ 1.2536e26" misquote is replaced by both exact numbers (§9), and open item D.1a
tells the manifest node what to do.

### E2. A buy aimed at the lead that falls short at execution still pays the fee — Medium — Fixed

Reproduced in all three triggers (dust buy raising the prize-linked minimum by a few wei; the
leader re-qualifying and selling back in the floor regime; an exact-output buy undercut by a sell
in front). `hookData` now accepts a third form, `abi.encode(buyer, mustLead)` (64 bytes). A flagged
buy that does not take the lead reverts with `NotQualifying(minimum, gross)`, so the challenger
pays gas and no fee and the leader gains nothing from the front-run; a malformed 64-byte payload
reverts with `MalformedHookData` so the flag can never be dropped silently; the flag on a sell
reverts with `MustLeadOnlyOnBuys`. Unflagged buys keep the brief's literal rule (execute, pay the
fee, change nothing else). The website always sets the flag (README §10). Tests: `test_mustLead_*`
(all three reviewer cases, flag on a sell, flag after expiry, happy path). Snapshotting the
prize-linked base so that only qualifying buys move the minimum is left as the requester's decision
(A5).

### E3. Identity fallback to `tx.origin` credits the bundler / relayer — Medium — Fixed (reduced)

Reproduced: a buy with empty `hookData` from an account whose transaction was signed by another
address made the signer the leader and paid it the prize. `_resolveTrader` now consults the
router (`sender` of `afterSwap`) before `tx.origin`: a gas-capped `staticcall` of `msgSender()`,
the function the Universal Router and the v4-periphery routers expose for exactly this purpose,
accepted only when it returns one clean 32-byte word. For a 4337 account, a sponsored 7702
account or a Safe trading through such a router the paying account is credited. A router that
lies can only gift the lead. Residual, documented in README §6 and tested
(`test_identity_routerWithoutMsgSenderCreditsTheSigner`): a router that neither forwards
`hookData` nor implements `msgSender()` still credits the signer. The alternative of no fallback
at all (buys without `hookData` can never lead) was considered and rejected: it would make a
plain-wallet buy through any third-party interface unable to play while still paying the fee.
Tests: `test_identity_routerMsgSenderIsUsedBeforeTxOrigin`, `..._hookDataBeatsRouterMsgSender`,
`..._routerThatRevertsOrReturnsGarbageFallsBackToTxOrigin`, `..._lyingRouterCanOnlyGiftTheLead`.

### E4. `settle()` reverts for everyone when the winner cannot be paid — Low — Fixed

Reproduced with a blocklisting IMD mock: `settle()` reverted inside `take`, the round stayed open
and only a later buy closed it. `settle()` now finalizes first and pushes the prize best-effort
(`try poolManager.unlock`): on failure the prize stays in `unclaimedPrize[winner]`,
`PrizeDeferred` is emitted and the next round can start. `claimPrize` and `claimTeamFees` keep
reverting on failure (their caller wants to know). A payout attempted while the manager is already
unlocked (a router settling from its own callback) is refused up front with `ManagerUnlocked`, so
that case is never mistaken for a transfer failure. Tests: `WinGameHookUnpayableWinnerTest`,
`test_settleInsideAManagerLockRevertsWithTheHooksOwnError`.

### E5. Anyone can initialize the hook's pool in a non-atomic deployment — Low — Disputed (documented)

Reproduced: a hook left deployed but uninitialized can be bound by a stranger to WIN/<junk>
(with the launch price, after E1) or to the real pair early. Not changed in the hook, because both
proposed fixes risk a dead launch under the factory's own flow, which this tree cannot observe:
(a) `initializer == constructor msg.sender` fails if the factory creates the hook through a
CREATE2 helper (the repository's own broadcast path does: Foundry routes salted creates through
the deterministic deployer) and then calls `initialize` itself; (b) a paired-currency constructor
argument needs a manifest placeholder the launch does not define (only `$poolManager` and
`$token` exist). A "holds the WIN supply" rule fails if the factory initializes through a position
manager. The launch factory deploys and initializes in one transaction, which closes the window.
What changed: the reference script's `deploy(Config)` initializes the pool in the same call when
`initializePool` is set (`test_deployCanInitializeThePoolInTheSameCall`), and README §7 states the
atomicity requirement and the consequences of ignoring it.

### E6. Views describe the expired round while it is unsettled — Low — Fixed

Reproduced: after the deadline, `minimumBuy()` kept the dead round's escalator and prize share
while `afterSwap` judged the next buy against the next round's fresh minimum. `minimumBuy()`,
`nextPrize()` and `roundNumber()` now project the post-close state whenever
`roundActive && block.timestamp >= deadline` (bank minus the pending prize, the next round's prize
share and number, escalator reset), which is the order `afterSwap` uses. `pendingPrize()` and the
`settleable` / `pendingRound` / `pendingWinner` / `pendingPrize` fields of `gameState()` describe
the closing round; raw getters are unchanged. Tests: `test_views_*`.

### E7. The 8.5 IMD floor assumes 18 decimals — Low — Fixed

Reproduced: a 6-decimal paired currency was accepted and the floor became 8.5e12 whole units.
`beforeInitialize` now requires the paired ERC-20 to answer `decimals() == 18` (native currency
counts as 18) and reverts `PairedCurrencyDecimals` otherwise, so a wrong pair fails at launch
instead of locking 90% of every fee forever. Test:
`test_initialize_refusesAPairedCurrencyWithoutEighteenDecimals`.

### E8. The lead can be bought for ~6.5% of the minimum by selling straight back — Low — Requester decision

Reproduced: after the decay, a buy of the 8.5 IMD minimum sold back in the next transaction left
the buyer as leader with a full timer, holding no WIN, 0.550177922494261455 IMD poorer (6.47% of
the minimum). The README claimed such a trade "gains nothing"; that was wrong and is corrected
(§5), as is A4's overtake count. The behaviour is the brief's rule as written ("a buy whose IMD
amount is at least the current minimum"). Two mechanical alternatives change that rule and are
left to the requester: void the lead if the leader's address sells during the round (cheap to
implement in `afterSwap`'s sell path, but a leader can sell from another address), or make part
of a qualifying buy non-recoverable (for example count only the fee, or require the WIN to be
held until settlement). Either would also raise the true cost of the unattended-hours reset
(open a round for ~0.065% of the bank, collect 5% if nobody answers in 10 minutes).

### E9. `claimTeamFees()` is open to any caller — Info — Disputed

Reproduced (by design). "Pull-based" is satisfied: nothing is pushed during swaps and the money
can only ever reach the fixed team wallet. Restricting the caller to the team wallet would strand
the share if that address cannot originate calls (an exchange deposit address, a custodial
wallet) and buys nothing in return, because an open claim cannot redirect a wei. The one
consequence (fees can be pushed to a not-yet-deployed contract wallet's address) is the same on
every chain for every token and is recoverable by deploying the wallet at that address. Left open;
documented in README §10.

### E10. Block stuffing has no mechanical defence — Info — Requester decision

Correct as a description: the contract's defences against stuffing are economic (5% prize share,
full 10-minute reset, escalation) and the break-even is bank > 20× the cost of ten minutes of
full blocks. A base-fee or block-count rule cannot see a stuffed block or is gameable by waiting.
The mechanical options all change numbers the brief fixes: an absolute cap on the prize (bounds the
attacker's upside), a cap as a multiple of the leader's qualifying buy, or a timer that lengthens
as the bank grows. They are listed here for the requester with the recommendation to set an
absolute prize cap once the launch chain's block gas limit and block time are known (D.3).

### Not in the review but changed alongside

- `afterSwap` was split into `_chargeAndPlay`, `_feeAndGross` and `_onBuy` to stay under the
  stack limit once the router and the flag became inputs; the fee arithmetic is byte-for-byte the
  same and the fee suites are unchanged.
- The test fixture and the deploy test now initialize at the launch price for the ordering they
  get, since any other price is refused.
