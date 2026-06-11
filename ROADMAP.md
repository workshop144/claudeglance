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

**v1.1.4 — "Sharper glance"** (June 2026): dual-ring usage gauge [1], burn rate
& run-out ETA [2][5], usage-credit overage in dollars [4], stale-data dimming
(part of [21]), and build version + git provenance (a dev-QoL extra, not in the
list below). Released as an unsigned DMG via the CI fallback + Homebrew cask.

Still open from the original v1.1 plan: **notarization [6]** (deferred — pending
an Apple Developer account; the release pipeline auto-upgrades once its secrets
are added).

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
  as an **opt-in "Console mode"** with a one-time login. Parked in **v1.5
  Exploratory** so the default app stays login-free.

---

## Master feature list — ranked by coolness

Deduped across all ~50 repos. The release buckets below draw from this list;
this is the "pure coolness" ordering you asked for.

| # | Feature | Seen in | Fits our aesthetic? |
|---|---------|---------|----------------------|
| 1 | ✅ **Graphical dual-ring menu-bar icon** (outer arc = 5h, inner disc = 7d, template for light/dark) — *shipped v1.1.0, monochrome; pulse/color intentionally skipped* | ac3charland, cctray, hamed, AgentLimits | ★★★ yes, the #1 gap & most-requested |
| 2 | ✅ **Run-out ETA as a clock time** + "on pace for 100% by 3:47 PM" — *shipped v1.1.3* | CCUM, par_cc_usage, ClaudePulse | ★★★ |
| 3 | **Pacemaker** — % of window elapsed vs % used; over-pace arrow/color (render as the ring's inner state) | AgentLimits, ac3 (`isAhead`), CCUM #216 | ★★★ |
| 4 | ✅ **`extra_usage` dollars** — `$X / $Y (Z%)` overage line — *shipped v1.1.2* | cfranci, elliot/ClaudeWatch | ★★★ |
| 5 | ✅ **Burn rate** (as %/hr, not tokens/min) — *shipped v1.1.3* | ccowl, cctray, Sapeet, CCUM | ★★★ |
| 6 | **Notarize the app** + drop the `xattr` step | saqoosha, hamed, ClaudeMeter | ★★★ table-stakes |
| 7 | **Sparklines + trend arrows** (↗︎↘︎↔︎) in the dropdown | cctray | ★★★ |
| 8 | **"Caching saved you $X"** + "API-equivalent value $Y" | ccstory | ★★★ delightful |
| 9 | **Local history** persisted lightweight → trends over time | rjmon, hamed, cctray, vibepulse | ★★ |
| 10 | **$ cost** today/session/month (tokens × price) + monthly projection | many | ★★ |
| 11 | **Context-window monitor** — last-msg `usage / 200k` per active session, 75/90% alerts | gosparq, leeguo | ★★ differentiated 2nd mode |
| 12 | **Prompt-cache freshness countdown** (`cache 4m23s` / `COLD`; cold burns quota ~10×) | leeguo | ★★ |
| 13 | **Sparkle EdDSA auto-update** | ClaudePulse, AgentLimits, vibepulse | ★★ |
| 14 | **Reset-countdown notifications** (5h + weekly) with anti-spam throttle | hamed #243, lugia #48/#51 | ★★ |
| 15 | **Usage heatmap** (GitHub-style) + **streaks** (current/max) | cc-wrapped, AgentLimits, 658jjh | ★★ |
| 16 | **Session health grade A–F** (errors/abandons/retries/compactions) | agentsview | ★★ novel |
| 17 | **"Where your tokens go"** — your prompts vs tool-results vs thinking | jack21/ClaudeCodeUsage | ★★ actionable |
| 18 | **Top tools / MCP usage** ("most-used today: Bash, Edit, …") | par_cc_usage | ★ |
| 19 | **Used-vs-Remaining toggle** (flip every metric) | joachim, AgentLimits #10 | ★ |
| 20 | **Per-model cost breakdown** (Opus vs Sonnet; $5/$25 vs legacy $15/$75) | otel, viberank, 658jjh | ★ |
| 21 | **Hide-menu-bar-icon option**, configurable poll interval, rotating metric (✅ stale-data dimming shipped v1.1.4) | AgentLimits, ClaudePulse, ac3, cctray | ★ |
| 22 | **`CLAUDE_CONFIG_DIR` + multiple data-path** support | masorange, CCUM | ★ cheap, expected |
| 23 | **Real prepaid $ balance** via opt-in Console login | hamed, mnapoli | ★★ but heavy (new auth) |
| 24 | **Multi-account** + "headroom" score (`100−max(5h%,7d%)`) + sortable table | rjmon, dsado, hamed | ★ scope-expanding |
| 25 | **WidgetKit / Notification Center widgets** (donut gauges + heatmap) | AgentLimits, theangeloumali | ★ |
| 26 | **Shareable "Wrapped" PNG card** | cc-wrapped | ★ fun/viral |
| 27 | **Bundled Claude Code statusline script** (reuse our data in the CLI) | AgentLimits, elliot | ★ |
| 28 | **Plan-recommendation nudge** ("you'd be better on Max 20x") | haasonsaas | ★ |
| 29 | **Service-status uptime history bar** (30/60/90d) | elliot/ClaudeWatch | ★ |
| 30 | **Nix / home-manager** formula | hamed | ★ |
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

### v1.2 — "Foresight" (the rest of prediction/pace + auto-update)
- **[3] Pacemaker** indicator (window-elapsed vs used) — best rendered as the
  v1.1 ring's **inner state** (solid when ahead of pace, hollow when behind), or
  a small ↑/↓. The natural next step now that the ring and burn rate both ship.
- **[14] Reset-countdown notifications** with anti-spam (debounce/dedupe — the
  extension's #48/#51 spam complaints are the cautionary tale).
- **[13] Sparkle auto-update** (EdDSA-signed appcast) — fixes the unnotarized-
  download friction for good, and gives the dev/beta channel a delivery path.

### v1.3 — "Memory" (local history & money insight, still from local jsonl)
- **[9] Lightweight local history** store (snapshots; SQLite or flat file).
- **[7] Sparklines + trend arrows** in the dropdown.
- **[15] Usage heatmap + streaks** (opt-in / settings).
- **[8] "Caching saved you $X" + "API-equivalent value $Y this week"** — reframes
  cost as value on a flat Max plan; motivating, not anxiety-inducing.
- **[10][20] $ cost** today/session/month + monthly projection
  (`dailyAvg × daysInMonth`). Pricing: hardcoded snapshot with a **LiteLLM
  override fetch**; distinguish **Opus current $5/$25 vs legacy $15/$75** and the
  **>200k tiered** rate. Dedupe by message id before summing (every serious tool
  does this).

### v1.4 — "Depth" (power features, all opt-in so the default stays clean)
- **[11] Context-window monitor** mode + **[12] cache-freshness countdown** — a
  genuinely differentiated second glance, reusing jsonl we already read.
- **[17] "Where your tokens go"** + **[18] top tools/MCP** mini-breakdown.
- **[16] Session health grade A–F** ("Today: B+") — nobody in the menu-bar space
  has this.
- **[19][21][22] UX niceties:** used-vs-remaining toggle, hide-icon option,
  configurable interval, `CLAUDE_CONFIG_DIR` + multi-path support.

### v1.5+ — Exploratory (bigger bets; validate demand first)
- **[23] Real prepaid $ balance** via opt-in "Console mode" (one-time
  `sessionKey` capture or Admin key). The answer to "$160 left" — but it adds an
  auth surface, so it stays opt-in and off the default path.
- **[24] Multi-account** + headroom score + sortable table (store each account's
  creds in their *own* Keychain service so Claude Code's refreshes don't clobber
  them — dsado/rjmon pattern).
- **[25] WidgetKit widgets**, **[26] shareable Wrapped card**, **[27] bundled
  statusline script**, **[28] plan-recommendation nudge**, **[29] uptime history
  bar**, **[30] Nix formula**.

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
