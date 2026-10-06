# WIN website validation — 2026-10-06

## Result and scope

**Website implementation and local validation complete; public IPFS hosting blocked.**
`imd site publish dist --name win-784` bundled the final export (162,971 bytes compressed),
then returned exit 1 / HTTP 503 / `member_sites_closed: this plane names no member sites`.
No live URL is asserted. `publication.json` records the refusal, export hashes and the
complete importable `win-site.car`. Packing and unpacking that CAR reproduced all five
files in `dist/` byte-for-byte. Its CID alone does not establish public hosting.

Scope: three hash-routed pages, live reads, wallet network switching, exact-input buy/sell,
approval flow, Settle, deferred Claim prize, history, contract links/copy, static export,
design documentation and IPFS package. Existing contracts, Foundry configuration and
dependencies were not modified. No onchain deployment or live transaction occurred.

Assumptions: a quiet light interface with a prominent dark timer, injected Ethereum wallets,
0.5% default slippage, no wallet requirement for reading, no external fonts/assets, English
only. Prices and game fields come from the contract, never seeded product fixtures.

## Actual checks

Dependencies were installed and subsequently verified with `npm ci` under `/tmp/win-build/web`
using the delivered manifest/lockfile. Source/config were copied there for validation; the
final export was copied back without changing content. Normal install/build commands are
documented in the root README. Final logs are included, not inferred from a verifier profile.

| Command or check | Actual outcome | Evidence |
| --- | --- | --- |
| `npm ci --cache /tmp/win-npm-cache --no-audit --no-fund` | Exit 0; 100 packages. npm's install-script notice was nonfatal; Vite/esbuild subsequently built successfully. | `install.log` |
| `npm run typecheck` | Exit 0, no TypeScript errors; includes application, scripts and tests. | `typecheck.log` |
| `npm test` | Exit 0; 7 tests passed, none skipped. | `unit-tests.log` |
| `npm run build` | Exit 0; Vite 7.1.10, no chunk-size warning after separating dependencies. | `build.log` |
| `npm run check:live` | Exit 0; chain 4663, block 81,579,167. `gameState` matched bank/minimum/timeLeft/pendingPrize getters at the same block. `pastWinners` was empty on this live first round. Live qualifying-buy quote returned positive WIN output. | `live-validation.log` |
| `npm run check:fork` | Initial standalone execution passed at fork block 81,571,380. The final combined check repeats these assertions. | final combined log below |
| `npm run check:ui` | Exit 0; fork block 81,579,175; production export under `/preview/`; all writes redirected to local Anvil, no live transactions. | `fork-and-browser.log`, `browser-validation.json` |
| ABI and runtime derivation | Both manifest ABI hashes matched. Token and hook runtime matched solc 0.8.26 output after masking immutable references. Network code hashes and pool bindings were checked live. | `web/scripts/generate-contracts.mjs`, `web/src/generated/verification.json` |
| Static export | `base: './'`; relative HTML/script/CSS/favicon references; direct hash navigation under subpaths; only five runtime files. | `dist/index.html`, production browser checks |
| IPFS archive | `ipfs-car@3.1.0 pack dist`, then unpack and SHA-256 comparison: all five files match; index is at archive root. | `publication.json`, `win-site.car` |

Unit coverage: 16-field gameState decoding and pending/next-round distinction; winner tuple
order; monotonic countdown and zero clamp; first-round 180-minute display; precise amount
validation; upward-rounded minimum; Settle/Claim calldata; pool ID; extended router tuple,
directions, actions, buyer data and output limits; bigint fee/slippage arithmetic.

Fork coverage: same deployed token/hook/router/Permit2/pool; actual buy output and credited
buyer; empty hookData router caller; sell output without changing leader/deadline; mustLead
rejection below threshold; expiry and pending winner; Settle pays the correct winner;
pastWinners; later-buy deferred payout; Claim transfers the claim and clears it. Test balances
were funded by editing storage only in Anvil. No mainnet account was funded or impersonated.

Production browser coverage: network add/switch, Settle and Claim buttons with inspected
calldata, approvals and buy, sell, wallet rejection and retry, invalid-input focus,
qualification and quotes, navigation, copy, native disclosure, keyboard skip link preserving
the page, reduced motion, 200% text enlargement at 1440px, RPC outage and retry. Chromium
154.0.8037.57. Automated reflow checked all three pages at **1440, 768, 390 and 320px**:
document width equaled viewport width in all 12 cases. Axe WCAG 2 A/AA + 2.1 AA scans on
each page at 320px reported **zero violations**. These scans are not accessibility certification.
The JSON field `consoleErrors` records uncaught page exceptions; the separate live-browser
console capture contains zero errors/warnings. Aborted RPC requests in the outage test were
intentional, and recovery was checked.

The assigned browser tool separately opened the live production export under `/dist/`,
read current mainnet state and quotes, inspected screenshots at desktop/mobile/intermediate
widths, and checked console and static resource responses (200). Final screenshots:
`game-desktop.png` (1440), `trade-mobile.png` (390), `trade-320.png` (320), and
`contracts-mobile.png` (320). Values can differ between screenshots because the game is live.

## Better Interface review

Read the pinned workflow and all six core-principle sections before implementation. Applied
the guidance while building, then reviewed the actual export and fixed applicable findings.
Documentation method applied after corrections; actual tokens/components are in root DESIGN.md.
Attribution and both supplied license texts are preserved in `docs/INTERFACE-LICENSE`.

| Domain | Coverage | Evidence and limits |
| --- | --- | --- |
| Accessibility — Checked | Native controls, headings/landmarks, labels, status/alert regions, timer semantics, skip link, route focus, target sizes, visible checkbox focus, reduced motion, automated scans. | Three scans clear; keyboard skip and checkbox focus inspected. No screen-reader session, physical-device accessibility test or complete native-wallet keyboard walkthrough. |
| Layout — Checked | Countdown hierarchy, shared alignment, spacing, stacked mobile form, long addresses, history scrolling, 12 viewport/page combinations. | Screenshots and measured document widths; no overflow in tested cases. RTL/localization not applicable to this English-only scope. |
| Writing — Checked | Fees distinguished, first-round floor, qualifying threshold, pending/next round, approvals, claim destination, retry errors, zero-history explanation, risk notice. | Source review and browser flows. Live RPC failures have a recovery action. |
| Typography — Checked | Numeric stability, threshold rounding, long outputs, heading hierarchy, prose measure, legible inputs and address wrapping. | Final screenshots, computed styles and text-enlargement check. System font stack; no claimed custom font loading. Browser-native zoom unperformed. |
| Colors — Checked | Role tokens, single primary-action fill, non-color status cues, rendered foreground/background measurements. | Ratios below; one theme only. Every possible wallet/OS forced-colors combination not verified. |
| UI — Checked | Loading, live, pending, stale, error, transaction, rejection, success and empty/history states; copy feedback, native disclosure, 120ms interaction transitions. | Live browser plus local-fork UI harness. No custom modals or page entrance animation; motion timeline slow-play not performed. |

Measured rendered WCAG contrast (computed browser foreground and nearest opaque background;
no translucent backgrounds in these samples):

| Pair | Ratio |
| --- | --- |
| Body text `#101713` / page `#f6f7f2` | 16.90:1 |
| Muted text `#60695f` / page `#f6f7f2` | 5.30:1 |
| Muted text `#60695f` / white panel | 5.70:1 |
| Muted text `#60695f` / input `#eef0e8` | 4.96:1 |
| Dark-panel supporting text `#b8c1b2` / `#101713` | 9.80:1 |
| Dark-panel timer `#f6f7f2` / `#101713` | 16.90:1 |
| Primary action `#101713` / `#d7fd74` | 15.76:1 |

## Findings, fixes and rechecks

All source references below point to the final implementation.

| Severity / domain | Source | Observed issue and correction | Recheck |
| --- | --- | --- | --- |
| High / writing | `web/src/format.ts:16` | Truncating a minimum could display an amount below the contract threshold. Added upward rounding and an explicit display note; exact bigint still drives eligibility and calldata. | Boundary unit assertion passes; live form uses exact current minimum. |
| Medium / writing | `web/src/App.tsx:142` | Generic ten-minute caption did not explain the observed >100-minute first round. First-round caption now states the three-hour launch floor. | Final live desktop screenshot. |
| Medium / layout + typography | `web/src/style.css:283` | A long WIN quote broke its final digits onto a separate line at 320px. Narrow output now has a full-width numeric row, a separate token row and 1.3rem type. | `trade-320.png`, 320px reflow and live long quote. |
| High / accessibility | `web/src/App.tsx:35` | Axe detected a paragraph outside a definition term/description inside the stats list. Moved the note into its description. | Final three-page axe run: zero violations. |
| Medium / typography | `web/src/style.css:104` | The semantic stats correction exposed inherited numeric letter spacing on small notes. Explicitly restored normal tracking and 1.5 line height. | Final computed tracking `normal`; final desktop screenshot. |
| Medium / accessibility | `web/src/App.tsx:102` | A raw `#main` link would replace the route. Skip now focuses/scrolls to main while preserving the current page. | Keyboard test enters from Trade and verifies `#trade` remains. |
| Medium / layout | `web/src/App.tsx:242`, `web/src/style.css:133` | Reversing visual mobile columns put context links before the visible form in DOM order. Form now comes first; desktop uses grid areas. | All three-page viewport checks and final trade screenshot. |
| Medium / UI | `web/src/App.tsx:180` | Explicit quote refresh could briefly retain the old quote identity. Included revision in the quote key to invalidate it immediately. | Browser refresh/retry and completed buy/sell flows. |
| Low / accessibility | `web/src/App.tsx:244` | Direction controls needed a named group rather than an unnamed generic container with aria-label. Added `role="group"`. | Final axe scan and snapshot. |
| Low / writing | `web/src/App.tsx:147` | One qualifying purchase displayed “1 buys”; hidden mobile line breaks could join sentences. Added singular text and spaces at the breaks. | Final export and fork browser checks. |

Harness corrections: aligned Playwright and axe's Playwright types; provided the serialized
tsx name helper inside the test fixture; enabled one-second local fork blocks so the stale
data guard was tested against a progressing chain; waited for quote loading to finish; used
a full navigation to test initial keyboard focus. These were test-environment issues, not
production wallet workarounds. The final tests passed after corrections.

## Remaining limitations

Public pinning/gateway availability remains **blocked** by the publishing service refusal.
The delivered CAR and documented import command make the remaining action concrete. No
attempt was made to bypass the service's closure or claim that the local CID is hosted.

Native wallet extensions, smart-wallet implementations, hardware wallets, physical mobile
devices, screen readers, native browser zoom and manual motion-timeline inspection remain
unperformed. Wallet requests were exercised with an injected test provider against a real
local fork. The site has no WalletConnect transport. The contract's unbounded `pastWinners()`
may eventually encounter public-RPC response limits; UI row pagination does not change that
contract call. Public RPC failures can temporarily stop reads, quotes and actions. The tests
are worker checks, not an audit and not independent authority.

## Delivery paths

The pre-existing `.git/info/exclude` excludes `artifacts/`. It was not changed. Durable
repository copies of this report, logs and screenshots are in `docs/website-validation/`;
the IPFS import archive is also retained as `web/ipfs/win-site.car`. The separate requested
output copies remain in `artifacts/`. No ignore files or Git metadata were modified.
