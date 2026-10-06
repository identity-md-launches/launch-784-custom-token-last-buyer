# Review: WIN game economics and `WinGameHook`

**Status of this document.** This is an adversarial review written by the same contributor who
wrote the code, from the brief, the `uniswap-v4-security` and `eth-security` checklists and the
v4-core source. It is structured so an independent reviewer can confirm or overturn each item. It
does **not** replace the separate independent review the brief and the launch policy require; see
"Open items" at the end.

Tools run: `forge build`, `forge test` (134 tests, fuzz at 256 runs), `forge fmt --check`, the
pinned IdentityMD floor suites against the attested creation code. Slither/Mythril were not
available in this environment.

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

### A4. Escalation may stall the game — Expected

With prize 5% of the bank and minimum ≥ 20% of the prize = 1% of the bank, a round of *n*
qualifying buys costs the last buyer ≈ 1% · 1.05ⁿ of the bank for a 5% prize. After ~34 overtakes
the minimum exceeds the prize and rational play stops, which is the intent ("every round ends").
The bank then grows only from ordinary trading until the next round. No action.

### A5. Prize-linked minimum moves between qualifying buys — Accepted

`minimumBuy()` is tied to `nextPrize()`, which is tied to the live bank. Sells and sub-minimum
buys raise it slightly. The brief says "20% of the upcoming prize", which is live by definition.
The website should re-read `minimumBuy()` right before a swap and add a small margin.

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
| 2 | Router allowlisting | Not applicable (no owner); identity via `hookData` + `tx.origin` fallback, not used for authorization. |
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
| C4 | Medium | `tx.origin` fallback mis-attributes 4337 / relayed trades to the bundler or relayer. | Accepted with documentation; website always sets `hookData`. Alternative (router allowlist) needs an admin, which the brief forbids. |
| C5 | Low | `minimumBuy()` could overflow after ~2,700 qualifying buys in one round, blocking buys (not settlement) for the rest of that round. | Fixed: escalator capped at 1e18×; tested. |
| C6 | Low | `pastWinners()` is unbounded. | Accepted: view only; `winnerAt(i)`/`winnersCount()` provided for pagination. |
| C7 | Low | Anyone can push the team's fees or a winner's lazy prize at any time (tax-timing nuisance). | Accepted: funds only ever go to the entitled address. |
| C8 | Info | ERC-6909 claims or raw IMD sent to the hook by third parties are ignored and stuck. | Accepted; no admin exists to sweep them, which is the brief's choice. |
| C9 | Info | Native-currency pair: a contract winner that rejects ETH cannot receive its own prize. | Documented; the launch pair is the IMD ERC-20. |
| C10 | Info | Sells cannot execute until a buy has put IMD into the single-sided pool (pool-level revert). | Expected for a single-sided launch; tests buy first. |

---

## D. Open items for the independent reviewer / deployer

1. **Chain selection.** No `network.json` was pinned to this task. Confirm the selected chain, its
   PoolManager, the IMD token address, and that IMD is a plain ERC-20 there (no fee, no hooks, no
   blocklist). The hook must not launch against anything else.
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
