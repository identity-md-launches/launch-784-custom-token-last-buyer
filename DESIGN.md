# WIN website design

## Overview

WIN is a live game interface for people watching a round or trading WIN / IMD. It uses a warm, pale background, dark green-black countdown panel, large stable numerals, and one lime primary action per view. Reading needs no wallet. Game, Trade, and How it works share the header, network strip, notices, and footer.

Source: `web/src/style.css`, `web/src/App.tsx`. The site uses native HTML and CSS, React, and an inline SVG brand mark. No image service, remote fonts, or external runtime artwork is required.

## Colors

The canonical palette is hex, declared in `:root`. Components use semantic roles:

| Role | Value | Use |
| --- | --- | --- |
| `--bg` | `#f6f7f2` | Page |
| `--surface` | `#ffffff` | Prize and swap panels |
| `--surface-muted` | `#eef0e8` | Inputs, notes, selected navigation |
| `--text`, `--dark-surface` | `#101713` | Main text, countdown and diagram backgrounds |
| `--text-muted` | `#60695f` | Supporting text |
| `--border` | `#d8ded2` | Dividers and control boundaries |
| `--on-dark`, `--on-dark-muted` | `#f6f7f2`, `#b8c1b2` | Text on dark surfaces |
| `--accent`, `--accent-hover` | `#d7fd74`, `#c2eb5b` | Primary action fill |
| `--focus` | `#416414` | 3px keyboard focus perimeter, 4px offset |
| `--success`, `--success-bg` | `#274934`, `#e7f5bd` | Qualification and claim notices |
| `--warning`, `--warning-bg` | `#714407`, `#fff0d4` | Delayed-data notices |
| `--error`, `--error-bg` | `#902e20`, `#ffeae5` | Actionable errors |

Dark-panel focus uses lime; forced-colors focus uses `Highlight`. Status always has text, not color alone. This is one light theme with deliberate dark panels, not an automatic dark theme. Measured contrast pairs and their scope are in `docs/website-validation/validation.md`.

## Typography

The body stack is `Helvetica Neue, Arial, sans-serif`, using installed system faces. There are no downloadable fonts. Addresses and the countdown use `SFMono-Regular, Consolas, Liberation Mono, monospace` (addresses omit Liberation Mono). Changing values use tabular numerals.

Body is 16px with 1.55 line height; prose is capped around 68 characters. Label and caption tokens are 14px and 13px. Compact metadata and uppercase eyebrows are 11px, weight 600 for eyebrows, with 0.12em tracking. H1 is `clamp(2.5rem, 5.4vw, 4.5rem)`, 1.12 line height and -0.055em tracking. H2 is `clamp(1.6rem, 3vw, 2.1rem)`. Headings use weight 600 and balanced wrapping; explanatory text uses pretty wrapping. The timer is `clamp(4rem, 8.3vw, 7rem)` on desktop. Mobile forms always exceed 16px text size.

Minimum-buy displays round upward to four decimal places; transaction amounts retain all 18 decimals. Full addresses remain available in accessible link names, titles and the contract list. There is no global selection suppression.

## Layout

`.shell` caps content at 1184px with 24px gutters, reduced to 16px below 45rem. Spacing tokens use 4, 8, 12, 16, 24, 32, 48 and 64px steps. Main groups have more space than their internal rows.

The game uses a 1.65:1 countdown/prize grid, then three equal stats. Trade uses a context column and swap form, with the form first in DOM order. The rules diagram is three steps on desktop. Breakpoints are 60rem, 45rem and 23rem: gutters and panel padding tighten, navigation moves to a second header row, panels and stats stack, and the diagram becomes vertical. At the narrowest breakpoint, large quote outputs and token labels use separate rows. Tables scroll inside a labeled, keyboard-focusable region. Long addresses wrap. Actions stay in document flow.

Rendered checks cover 1440, 768, 390 and 320px; see validation for results. Desktop columns are not a requirement for future mobile layouts.

## Elevation & Depth

Most panels are flat, separated by spacing, tone and 1px structural borders. `.swap-card` uses two light shadows (`0 2px 6px #10171308`, `0 12px 40px #10171308`). The header is not sticky. Only the skip link uses elevated positioning. There are no custom dialogs or floating transaction controls.

## Shapes

Large panels use `--radius: 1.5rem`; smaller controls and input surfaces use `--radius-small: .75rem`. The swap panel's 24px radius encloses 12px input corners with padding. Badges are pills; token marks are circles. Borders remain structural, and SVG icons inherit the text color.

## Components

- `Mark`, `AddressLink`, `CopyButton`, `Tag`, and `Stat` in `App.tsx` are the shared visual components. Copy buttons keep feedback in a stable status region.
- `.button` is the neutral action; `.button.primary` is the lime main action. Disabled actions have adjacent reasons. Wallet activity, transaction confirmation, rejection and explorer links appear in shared notices.
- `GamePage` combines countdown, leader, pending settlement, prize, bank, minimum, and history. It distinguishes loading, no active round, live, awaiting the next block, pending settlement, and delayed data. `WinnersTable` shows ten rows at a time.
- `TradePage` uses real labels, a decimal input, pressed-state direction buttons, a native checkbox and select, quote expiry, and field errors. Controls disable during transactions. The quote is invalidated when its inputs or refresh revision change.
- `RulesPage` uses an HTML diagram, articles, an address list and native `details` disclosure.
- `useGame.ts` polls every five seconds, derives the timer from elapsed monotonic time, and stops actions on stale or unverified data. `role="timer"` avoids announcing every second. Important action results have status/alert regions.

Native links and buttons provide keyboard operation. Route changes focus the main landmark. The skip link preserves the current route. Interactive transitions last 120ms and only run under `prefers-reduced-motion: no-preference`; press scale is 0.96. There is no animated page entrance.

## Do's and Don'ts

Use `.shell`, the existing text roles, shared address/notice components, and one primary action when adding a page. Keep amounts as bigint until formatting; never show sample values as live state. Preserve labels and qualification explanations beside the trade. Keep static assets relative and use hash routes. Do not add a second palette, remote font dependency, changing timer widths, or a hover-only explanation for an unavailable financial action.

Guidance attribution: Jakub Krehel’s Better Interface (MIT) and Paul Bakaus’s Impeccable documentation method (Apache-2.0), at the pinned revisions used for this assignment. Retained notices and license texts: `docs/INTERFACE-LICENSE`.
