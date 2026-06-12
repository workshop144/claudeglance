# ClaudeGlance Roadmap

> Research-derived roadmap (June 2026). Built by deep-reading ~50 competitor
> repos in this space (macOS menu-bar apps, status-bar plugins, TUIs, browser
> extensions, analytics CLIs) plus mining their Issues & PRs and the App Store /
> Homebrew distribution landscape. Every idea below was seen working in real
> code, not invented.
>
> **Guiding principle:** stay *clean, elegant, simple*. ClaudeGlance is a glance,
> not a dashboard. Most items are **opt-in** so the default view stays minimal.
> The "Deliberately not doing" list at the bottom is as important as the rest.

---

## ✅ Shipped

**v1.6.4 — "Reach"** (June 2026): **Plan-fit nudge [28]** — a "Plan fit" card on the
dashboard's Usage tab that reads the utilization history we record to gauge
limit-pressure and reports it plainly ("often near your limits — a higher tier would
add headroom" / "comfortable headroom — a lower tier might do" / "good fit"), plus an
overage callout. Deliberately **plan-agnostic**: the API only exposes utilization %,
not the tier, so the copy never claims to know your plan — it speaks in headroom and
observed overage. Stays quiet until there's enough history to say something.

**v1.6.3 — "Reach"** (June 2026): **Shareable "Wrapped" card [26]** — a colorful,
social-friendly PNG of your month with Claude (total tokens, cache efficiency,
spend & caching savings, streak, top model/tool), rendered with SwiftUI's
`ImageRenderer` from the local logs. Reachable from a **menu item** and a **Share
Wrapped** button on the dashboard's Activity tab; the preview window offers Save,
Copy, and the macOS Share sheet. Computed locally — nothing leaves the machine
until you share it.

**v1.6.2 — "Reach"** (June 2026): **Service-status uptime history [29]** — an opt-in
30-day uptime bar under the menu's health row (one colored cell per day: green
operational → red critical, faint gray = no data), plus a trailing 30-day uptime %.
The bar is **self-recorded** (worst status per day, persisted like the usage history
store, rolling 90-day) and **seeded once from the incident feed** so it isn't empty
on day one; the % is **time-based from incidents** over the reliable 30-day window.
Menu-only by choice, to keep the footprint small.

**v1.6.1 — "Reach"** (June 2026): **Nix / home-manager packaging [30]** — a `flake.nix`
that packages the released app for `aarch64-darwin` / `x86_64-darwin` (fetches the
release DMG, installs `ClaudeGlance.app` + a `bin/claudeglance` launcher), so Nix
users can `nix run`/`nix profile install` or add it to a nix-darwin / home-manager
config. It tracks the latest *public* release; `scripts/update-flake.sh <version>`
re-pins it from a freshly released DMG, and a CI job `nix build`s the flake on every
push so the formula can't silently rot. App code is unchanged.

**v1.6.0 — "Reach"** (June 2026): the first of the v1.6 "get our data onto more
surfaces" pass. **Bundled Claude Code statusline [27]** — ClaudeGlance now writes
its live numbers to a small JSON sidecar each poll, and ships a shell script that
reads it to render a Claude Code statusline (`Opus 4.8  5h 35% · 7d 71%`) with no
extra API calls or log parsing. The default line is usage-only; the sidecar also
carries cost/tokens, reset countdowns, burn rate, and an on-pace ETA for custom
lines. **Settings › Claude Code statusline** installs the script and either copies
the `settings.json` snippet or wires it in for you (backing up `settings.json`
first).

**v1.5.6 — "Depth"** (June 2026): power features, all opt-in so the default stays
a glance. **Context-window monitor [11]** — per-active-session `usage / 200k` fill
with caution/compact alerts, as a menu glance and a dashboard **Context tab**.
**Prompt-cache freshness countdown [12]** — a live "cache warm 4m 23s / cold"
readout (5-min TTL) so you know if the next message hits a cheap cache read.
**"Where your tokens go" [17] + top tools / MCP [18]** — a new **Tokens tab**:
month-to-date token composition by type (cache-read/write, input, output) plus
tool and MCP-server call counts. **Session health grade A–F [16]** ("Today: B+")
from cache efficiency, limit headroom, and context headroom — shown transparently
with its contributing factors, not as a black box. **UX niceties [19][21][22]** —
used-vs-remaining toggle, hide-menu-bar-icon option, a configurable 1–30 min poll
interval, and `CLAUDE_CONFIG_DIR` + multi-path jsonl discovery. Plus two
**hardening** fixes the live build surfaced: OAuth token re-read on 401/expiry (no
more sticky auth errors) and a manual-Refresh throttle (no self-inflicted 429s).

**v1.4.5 — "Dashboard"** (June 2026): one tabbed window (Activity / Cost / Usage)
built with SwiftUI + Swift Charts, sharing the Settings window shell. **Usage
tab** — 5h/7d utilization history line chart [7] from the v1.3.4 store. **Cost
tab** — today/month/projection cards, **per-model breakdown [20]**, and a
daily-spend chart. **Activity tab** — GitHub-style contribution heatmap [15],
streak/active-day stats, and daily-token bars. Menu rows **deep-link** to the
matching tab (a bold-on-hover affordance, no blue highlight), and the menu's
"Today" block was **slimmed back to a two-line glance** now that the window holds
the detail. The menu + Settings version signatures darken/bold on hover.

**v1.3.4 — "Memory"** (June 2026): $ cost today/month + monthly projection
[10][20], "caching saved you $X" [8], in-menu streak + 14-day activity strip
[15], and a persisted **local history store [9]** of the OAuth 5h/7d % (the
foundation the v1.4 Dashboard charts).

**v1.2.2 — "Foresight"** (June 2026): pacemaker pace marker on the 5h ring [3],
reset-countdown notifications with anti-spam [14], and a dev/prod channel marker
on the menu version row. **Sparkle auto-update [13] deferred** — it pairs with
notarization (ad-hoc updates still hit Gatekeeper), so it's parked until the
Apple Developer account lands.

**v1.1.4 — "Sharper glance"** (June 2026): dual-ring usage gauge [1], burn rate
& run-out ETA [2][5], usage-credit overage in dollars [4], stale-data dimming
(part of [21]), and build version + git provenance (a dev-QoL extra, not in the
list below). Released as an unsigned DMG via the CI fallback + Homebrew cask.

Still open: **notarization [6]** (deferred — pending an Apple Developer account;
the release pipeline auto-upgrades once its secrets are added).

---

## Where we already lead

Before the wish-list, what v1.0.0 already does that most competitors don't:

- **Official OAuth numbers.** We read the Claude Code OAuth token from Keychain
  and call `/api/oauth/usage`. Most competitors scrape `claude.ai` web-session
  cookies through an embedded WebView — fragile, breaks on token rotation /
  sleep / Google sign-in (see the bug threads on the 2.7k★ leader). Our approach
  is the robust one. **Keep it, market it.**
- **No login flow.** Today's-activity comes from local `~/.claude/projects`
  jsonl — no auth, no network.
- **Granular text menu bar, service-health dot, threshold notifications,
  launch-at-login, Homebrew cask + DMG.** Already at or above par.

The honest gaps everyone else had and we didn't — as of v1.0.0: a graphical
icon, any $ figure, any prediction/pace, any history, and notarization. **v1.1.4
closed the icon, the $ figure, and prediction/pace.** Remaining: **history** and
**notarization** (the latter just pending the Apple account).

---

## The credit-balance question (the "$160 left")

The single most-asked-about feature. Status after auditing every repo:

- The OAuth endpoint we already call **cannot** see the prepaid Console dollar
  balance. It only carries `extra_usage` = pay-as-you-go *overage* (`used_credits`,
  `monthly_limit` in cents, `utilization`). **Showing `$used / $limit (Z%)` from
  that is essentially free** — it's in the payload we already decode.
  → ✅ **shipped in v1.1.2.**
- The real prepaid balance (your ~$160) lives on the **Anthropic Console** and
  needs a **separate auth** beyond Claude Code OAuth — two confirmed routes:
  - Capture the `sessionKey` cookie via a one-time embedded Console login, then
    `GET console.anthropic.com/api/organizations/{org}/prepaid/credits` +
    `/current_spend` (this is how the 2.7k★ leader does it).
  - An Admin API key (`x-api-key`, `sk-ant-admin…`) on the org cost endpoints.
- So our original instinct was right: **OAuth can't reach it**. It's only doable
  as an **opt-in "Console mode"** with a one-time login. Parked in **v1.6
  Exploratory** so the default app stays login-free.

---

## Master feature list — ranked by coolness

Deduped across all ~50 repos. The release buckets below draw from this list;
this is the "pure coolness" ordering you asked for.

| # | Feature | Seen in | Fits our aesthetic? |
|---|---------|---------|----------------------|
| 1 | ✅ **Graphical dual-ring menu-bar icon** (outer arc = 5h, inner disc = 7d, template for light/dark) — *shipped v1.1.0, monochrome; pulse/color intentionally skipped* | ac3charland, cctray, hamed, AgentLimits | ★★★ yes, the #1 gap & most-requested |
| 2 | ✅ **Run-out ETA as a clock time** + "on pace for 100% by 3:47 PM" — *shipped v1.1.3* | CCUM, par_cc_usage, ClaudePulse | ★★★ |
| 3 | ✅ **Pacemaker** — pace notch on the 5h ring (fill past it = ahead of pace) — *shipped v1.2.0* | AgentLimits, ac3 (`isAhead`), CCUM #216 | ★★★ |
| 4 | ✅ **`extra_usage` dollars** — `$X / $Y (Z%)` overage line — *shipped v1.1.2* | cfranci, elliot/ClaudeWatch | ★★★ |
| 5 | ✅ **Burn rate** (as %/hr, not tokens/min) — *shipped v1.1.3* | ccowl, cctray, Sapeet, CCUM | ★★★ |
| 6 | **Notarize the app** + drop the `xattr` step | saqoosha, hamed, ClaudeMeter | ★★★ table-stakes |
| 7 | ✅ **Sparklines + utilization history chart** — in-menu trend (1.3.4) + full line chart in the v1.4 Usage tab | cctray | ★★★ |
| 8 | ✅ **"Caching saved you $X"** — *shipped 1.3.2* | ccstory | ★★★ delightful |
| 9 | ✅ **Local history** persisted lightweight → trends over time — *shipped 1.3.4* | rjmon, hamed, cctray, vibepulse | ★★ |
| 10 | ✅ **$ cost** today/month + monthly projection — *shipped 1.3.0/1.3.1* | many | ★★ |
| 11 | ✅ **Context-window monitor** — last-msg `usage / 200k` per active session, caution/compact alerts — *shipped v1.5.0* | gosparq, leeguo | ★★ differentiated 2nd mode |
| 12 | ✅ **Prompt-cache freshness countdown** (`cache warm 4m23s` / cold re-caches; 5-min TTL) — *shipped v1.5.2* | leeguo | ★★ |
| 13 | **Sparkle EdDSA auto-update** | ClaudePulse, AgentLimits, vibepulse | ★★ |
| 14 | ✅ **Reset-countdown notifications** (5h + weekly) with anti-spam — *shipped v1.2.1* | hamed #243, lugia #48/#51 | ★★ |
| 15 | ✅ **streak + activity strip** (in-menu, 1.3.3) + **full GitHub-style heatmap grid** in the v1.4 Activity tab | cc-wrapped, AgentLimits, 658jjh | ★★ |
| 16 | ✅ **Session health grade A–F** ("Today: B+" from cache efficiency, limit & context headroom) — *shipped v1.5.5* | agentsview | ★★ novel |
| 17 | ✅ **"Where your tokens go"** — month-to-date split by type (cache-read/write, input, output) — *shipped v1.5.4* | jack21/ClaudeCodeUsage | ★★ actionable |
| 18 | ✅ **Top tools / MCP usage** ("most-used: Bash, Edit, …" + MCP servers) — *shipped v1.5.4* | par_cc_usage | ★ |
| 19 | ✅ **Used-vs-Remaining toggle** (menu bar + rows) — *shipped v1.5.6* | joachim, AgentLimits #10 | ★ |
| 20 | ✅ **Per-model cost breakdown** (Opus vs Sonnet; $5/$25 vs legacy $15/$75) — *shipped 1.4.2* | otel, viberank, 658jjh | ★ |
| 21 | ✅ **Hide-menu-bar-icon option** + **configurable poll interval** — *shipped v1.5.6* (✅ stale-data dimming v1.1.4); rotating metric skipped | AgentLimits, ClaudePulse, ac3, cctray | ★ |
| 22 | ✅ **`CLAUDE_CONFIG_DIR` + multiple data-path** support — *shipped v1.5.6* | masorange, CCUM | ★ cheap, expected |
| 23 | **Real prepaid $ balance** via opt-in Console login | hamed, mnapoli | ★★ but heavy (new auth) |
| 24 | **Multi-account** + "headroom" score (`100−max(5h%,7d%)`) + sortable table | rjmon, dsado, hamed | ★ scope-expanding |
| 25 | **WidgetKit / Notification Center widgets** (donut gauges + heatmap) | AgentLimits, theangeloumali | ★ |
| 26 | ✅ **Shareable "Wrapped" PNG card** — *shipped v1.6.3* | cc-wrapped | ★ fun/viral |
| 27 | ✅ **Bundled Claude Code statusline script** (reuse our data in the CLI) — *shipped v1.6.0* | AgentLimits, elliot | ★ |
| 28 | ✅ **Plan-recommendation nudge** ("often near your limits") — plan-agnostic — *shipped v1.6.4* | haasonsaas | ★ |
| 29 | ✅ **Service-status uptime history bar** — 30-day menu bar — *shipped v1.6.2* | elliot/ClaudeWatch | ★ |
| 30 | ✅ **Nix / home-manager** formula — *shipped v1.6.1* | hamed | ★ |
| 31 | Copy-usage-to-clipboard | cctray, joachim | ½ |
| 32 | Per-session status + approve/deny prompts + jump-to-terminal | wangsen, TwilightVoyager, theangeloumali | different product → decline |

---

## Release plan (iterative passes)

Each release stays small and coherent. Nothing here changes the default minimal
look — new surfaces are toggles or dropdown rows.

### ✅ v1.1 — "Sharper glance" — SHIPPED (v1.1.4)
Dual-ring gauge [1], `extra_usage` dollar line [4], burn rate + run-out ETA
[2][5], stale-data dimming [21], README refresh, and build-version provenance.
**Deferred: [6] Notarize** — pending the Apple Developer account; the release
workflow auto-upgrades from the unsigned-DMG fallback to a notarized build the
moment the `APPLE_*` secrets are added (no code changes needed).

### ✅ v1.2 — "Foresight" — SHIPPED (v1.2.2)
Pacemaker pace notch on the 5h ring [3], reset-countdown notifications with
anti-spam [14], plus a dev/prod channel marker on the menu version row.
**Deferred: [13] Sparkle auto-update** — its value is *seamless* updates, which
an ad-hoc build can't deliver (the downloaded update is still Gatekeeper-
quarantined). Parked to land together with notarization, so it's set up once
cleanly. Updates meanwhile: `brew upgrade`.

### ✅ v1.3 — "Memory" — SHIPPED (v1.3.4)
- ✅ **[10][20] $ cost** today/month + monthly projection — *shipped 1.3.0 / 1.3.1*
- ✅ **[8] "Caching saved you $X"** (uncached − actual cost) — *shipped 1.3.2*
- ✅ **[15] streak + 14-day activity strip** (in-menu) — *shipped 1.3.3*
- ✅ **[9] local history store + [7] sparklines** — persist the OAuth 5h/7d % over
  time and sparkline the gauges in the menu — *shipped 1.3.4*. The store is the
  foundation the v1.4 Dashboard charts.

### ✅ v1.4 — "Dashboard" — SHIPPED (v1.4.5)
A single window (same shell as the Settings window) with **tabs — Activity /
Cost / Usage**. Menu rows are **clickable and open this one window on the matching
tab** (deep-link, bold-on-hover) — no scattered per-feature windows. Built with
SwiftUI + **Swift Charts** (macOS 13+). This let us **slim the menu back to a true
glance** by moving the richer detail into the window.
- ✅ **Usage tab** (1.4.1) — 5h/7d utilization **history line chart** [7] from the
  v1.3.4 store.
- ✅ **Cost tab** (1.4.2) — today/month/projection cards, **per-model breakdown**
  [20], and a daily-spend chart.
- ✅ **Activity tab** (1.4.3) — GitHub-style contribution **heatmap grid** [15],
  streak/active-day stats, and daily-token bars.
- ✅ **Menu slimmed** (1.4.4) — "Today" block collapsed to a two-line glance;
  every row deep-links (Today/streak → Activity, cost → Cost, 5h/7d → Usage).
- ✅ **Hover affordances** (1.4.1/1.4.5) — deep-link rows bold on hover; the menu
  and Settings version signatures darken on hover.

### ✅ v1.5 — "Depth" — SHIPPED (v1.5.6)
Power features, all opt-in so the default stays a glance.
- ✅ **[11] Context-window monitor** + **[12] cache-freshness countdown** — a
  genuinely differentiated second glance, reusing jsonl we already read. Menu
  glance + a dashboard **Context tab** — *shipped 1.5.0 / 1.5.2*.
- ✅ **[17] "Where your tokens go"** + **[18] top tools/MCP** mini-breakdown — a new
  **Tokens tab** (token composition by type + tool/MCP counts) — *shipped 1.5.4*.
- ✅ **[16] Session health grade A–F** ("Today: B+"), from cache efficiency, limit
  headroom, and context headroom, shown with its factors — *shipped 1.5.5*.
- ✅ **[19][21][22] UX niceties:** used-vs-remaining toggle, hide-icon option,
  configurable 1–30 min interval, `CLAUDE_CONFIG_DIR` + multi-path — *shipped 1.5.6*.
- ✅ **Hardening:** OAuth token re-read on 401/expiry (1.5.1) and a manual-Refresh
  throttle (1.5.3) — both surfaced by the live build during the batch.

### v1.6 — "Reach" (in progress)
Getting our data onto more surfaces and out to more people. The cheap/light items
first; each ships as its own patch and is reviewed before the next begins. (This
batch deliberately stops at v1.6.5 — the heavier bets below wait for v1.7+.)
- ✅ **v1.6.0 — [27] Bundled statusline script** — *shipped*. Sidecar JSON +
  bundled shell script + Settings install/auto-wire.
- ✅ **v1.6.1 — [30] Nix / home-manager formula** — *shipped*. `flake.nix` (fetches
  the release DMG), `update-flake.sh`, and a CI `nix build` check.
- ✅ **v1.6.2 — [29] Service-status uptime history bar** — *shipped*. Opt-in 30-day
  menu bar (self-recorded + incident-seeded; time-based uptime %).
- ✅ **v1.6.3 — [26] Shareable "Wrapped" PNG card** — *shipped*. Colorful card via
  `ImageRenderer`; menu + Activity-tab entry; Save/Copy/Share.
- ✅ **v1.6.4 — [28] Plan-recommendation nudge** — *shipped*. Plan-agnostic "Plan
  fit" card on the Usage tab (limit-pressure + overage; no tier assumed).
- **v1.6.5 — [25] WidgetKit / Notification Center widgets** — a new target reusing
  the history store (donut gauges + heatmap).

### v1.7+ — Exploratory (bigger bets; validate demand first)
- **[23] Real prepaid $ balance** via opt-in "Console mode" (one-time
  `sessionKey` capture or Admin key). The answer to "$160 left" — but it adds an
  auth surface, so it stays opt-in and off the default path.
- **[24] Multi-account** + headroom score + sortable table (store each account's
  creds in their *own* Keychain service so Claude Code's refreshes don't clobber
  them — dsado/rjmon pattern).
- **[6] Notarize + [13] Sparkle auto-update** — the deferred pair, gated on the
  Apple Developer account and designed to land together; moved to the tail so the
  rest of v1.6 ships regardless of when the account arrives.

### Hardening (ongoing, every release)
Pulled from competitors' recurring bug threads — get these right since we parse
local jsonl and live in the menu bar:
- **Timezone correctness** (pervasive complaint everywhere).
- **Menu-bar icon persistence** (the leader has 5+ "icon disappeared/reverted"
  bugs).
- **Multi-monitor popover placement** (don't pop on the wrong screen).
- **Big-jsonl streaming** — incrementally parse, don't load 500MB files into
  memory (ccusage #1151).
- **Pricing freshness** — stale tables show $0 for new models; keep the LiteLLM
  override.
- Keep a **`curl` fallback** in mind if we ever see intermittent 403s (Anthropic
  edge JA3-fingerprints Node's fetch; `curl` is accepted).

---

## Deliberately NOT doing (protecting the aesthetic)

These are popular elsewhere but would bloat a glance app or dilute the Claude
focus. Listed so the choice is explicit, not accidental:

- **Multi-tool aggregation** (Codex / Copilot / OpenCode / Gemini). The single
  biggest *universal* request across all repos — and exactly why ccusage and
  agentsview feel sprawling. Staying **Claude-only is a deliberate
  differentiator.** Revisit only if the audience clearly demands it.
- **Leaderboard / social submission** (viberank) — fun, off-brand for a quiet
  utility.
- **Agent approve/deny + jump-to-terminal** (wangsen, TwilightVoyager) — a
  different product (session orchestration), not usage glancing.
- **Context-compression proxy** (headroom's "2x usage") — a separate product
  that rewrites your traffic.
- **OpenTelemetry / Grafana stack** (otel) — enterprise observability, wrong
  form factor.
- **Mac App Store build** — the store is nearly empty here (only "Usage for
  Claude"), so it's a differentiation *opportunity*, but sandbox entitlements for
  Keychain + `~/.claude` jsonl access make it a separate track, not a v1.x line
  item.

---

*Sources: ~50 repos including ccusage, Maciek-roboblog/Claude-Code-Usage-Monitor,
hamed-elfayome/Claude-Usage-Tracker, Iamshankhadeep/ccseva, masorange,
betoxf/Usagebar, mnapoli, leeguoooo, sivchari/ccowl, goniszewski/cctray,
Sapeet, ac3charland, rjwalters, DSado88, Nihondo/AgentLimits, kenn-io/agentsview,
numman-ali/cc-wrapped, atomchung/ccstory, par_cc_usage, jack21/ClaudeCodeUsage,
gosparq, sergey-zhuravel & tzangms/ClaudePulse, elliotykim & JohnDimou/ClaudeWatch,
658jjh, cfranci, gglucass/headroom, ColeMurray/otel, sculptdotfun/viberank,
wesm/vibepulse, lugia19/Claude-Usage-Extension, HermannBjorgvin/Clawdmeter, and
more, plus their Issues/PRs.*
