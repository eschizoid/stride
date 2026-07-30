<p align="center">
  <img src="img/stride.png" alt="stride — CLI for your Strava data" width="640" />
</p>

# stride

A local-first training engine for endurance athletes, written in [Roc](https://www.roc-lang.org).

stride syncs your Strava history into a SQLite file you own, computes training
metrics deterministically, and provides an optional LLM coaching layer built on
structured evidence.

> **The engine does the math. The LLM does the judgment.**

```
$ stride summary

── stride report (as of 2026-07-28) ──────────────────

  fitness (CTL): 24   fatigue (ATL): 22   form (TSB): -1
  → ready — good day for intensity

  last 28 days:
    training load: 797 TSS
    time in HR zones: Z1 432m  Z2 240m  Z3 272m  Z4 2m  Z5 0m
    polarization: 71% easy (Z1-2) / 29% moderate (Z3) / 0% hard (Z4-5)
    ⚠ zone gap: 0 minutes in Z5 — no VO2max stimulus in 28 days

  FTP calibration (60d): best 20-min power 256W -> estimated FTP 243W (config: 243W)

  last 7 days: 193 TSS — 37% easy / 63% moderate / 0% hard
  last hard session (5+ min Z4/Z5): 2025-10-08
  open prescriptions: 4
```

Every number above was computed locally, from raw activity streams, by pure
functions with unit tests. No number came from a model.

## Why stride, if I already have Strava?

**Strava records activities. stride explains training.**

Strava is the system of record. stride answers the questions the record doesn't:
is my training polarized or all-moderate? Is my fitness actually climbing? When
was my last *real* hard session? Is my FTP stale? It solves different problems:

- **Deterministic metrics** — TSS, normalized power, intensity factor, CTL/ATL/TSB,
  time-in-zone, FTP calibration. Same inputs, same numbers, every time.
- **A database you own** — everything lives in `~/.stride/db.sqlite`. Query it with
  `sqlite3`, back it up with `cp`, inspect any computed value's inputs.
- **Reproducible recomputation** — change your FTP and the engine recomputes exactly
  the affected history. Edit a ride on Strava and the metrics self-heal.
- **Scriptable** — every command emits JSON for tools and agents, tables for humans.
- **An honest data model** — a session with no usable data shows `-`, not an
  invented number. Junk HR samples are filtered, and it says so.

## Installation

Everyone needs: `sqlite3`, and a free [Strava API application](https://www.strava.com/settings/api)
(client id + secret — takes two minutes).

### Prebuilt binary (recommended)

Grab the binary for your platform from the [latest release](https://github.com/eschizoid/stride/releases/latest)
and put it on your `PATH`. Pick one:

| Platform | Asset |
| --- | --- |
| Linux · x86_64 | `stride-linux-x86_64` |
| Linux · arm64 | `stride-linux-arm64` |
| macOS · Apple Silicon | `stride-macos-arm64` |
| macOS · Intel | `stride-macos-x86_64` |

```bash
# example: macOS Apple Silicon — adjust the asset for your platform
curl -fsSL -o stride https://github.com/eschizoid/stride/releases/latest/download/stride-macos-arm64
chmod +x stride
sudo mv stride /usr/local/bin/          # or anywhere on your PATH (e.g. ~/.local/bin)
stride --version
```

Verify the download against [`SHA256SUMS.txt`](https://github.com/eschizoid/stride/releases/latest)
if you like: `sha256sum -c SHA256SUMS.txt`. (No Windows build — Roc's toolchain doesn't
target it yet; on Windows, use WSL and the Linux binary.)

### Build from source

Needs the pinned Roc toolchain (see [Development](#development)) and `just`:

```bash
git clone https://github.com/eschizoid/stride.git && cd stride
just install        # builds the binary, symlinks it into ~/.local/bin
```

## Quick start

```bash
stride init                                   # create + migrate the db
STRAVA_CLIENT_ID=... STRAVA_CLIENT_SECRET=... stride auth   # one-time browser paste flow
stride config set ftp 250                     # your FTP (watts)
stride config set hr_z1_max 120               # your HR zone upper bounds...
stride config set hr_z2_max 150
stride config set hr_z3_max 165
stride config set hr_z4_max 180               # (z5 = everything above)
stride config set utc_offset_minutes -300     # optional: your offset from UTC so
                                              # "today" is your local day, not UTC's
                                              # (default 0; set seasonally for DST)
stride backfill                               # pull all activities + all stream history
stride analyze                                # compute everything
```

`backfill` is the whole first-time pull: it fetches your complete activity list,
then drains every activity's raw streams, pacing itself against Strava's rate
limits (fills each 15-min window, sleeps to the next, stops cleanly at the daily
cap). It's resumable — a multi-thousand-activity history spans a few days of
`stride backfill` re-runs, hands-off.

After `auth`, credentials live in the db — no env vars ever again. Day-to-day:

```bash
stride sync && stride analyze && stride summary   # the daily loop (repo: `just up`)
stride week                                       # everything needed to plan a week
```

## Commands

**Setup (once)**

| Command | What it does |
| --- | --- |
| `init` | Creates `~/.stride/db.sqlite` and runs migrations. Idempotent — safe to re-run anytime. |
| `auth` | One-time Strava OAuth: prints an authorize URL, you paste back the `code=` param. Stores tokens *and* client credentials in the db — no env vars needed afterward. |
| `config set <key> <val>` / `config get <key>` | Your numbers: `ftp` (watts), HR zone bounds `hr_z1_max`…`hr_z4_max`, and `utc_offset_minutes`. Changing `ftp` auto-recomputes all history on the next `analyze`. |

**Data (daily)**

| Command | What it does |
| --- | --- |
| `sync` | Pulls new activities + the next batch of HR/power streams. Re-pulls a rolling 30-day window so edits made on Strava self-heal. The fast daily command. |
| `backfill` | Re-pulls the **full** activity list, then drains **all** missing stream history — hands-off, resumable, paced on Strava's rate-limit headers. First-time imports and deep reconciles (~after bulk edits older than 30 days). |
| `analyze` | Computes metrics for new (or invalidated) activities — TSS, time-in-zone, normalized power — then rebuilds the daily fitness/fatigue/form series through today. Prints what it did plus a one-line form verdict. |

**Reading your training** (each answers a different question)

| Command | The question it answers |
| --- | --- |
| `summary` | *Where do I stand today?* Form (with verdict), 7-day and 28-day zone mix + polarization, FTP calibration (flags when your 20-min best says your FTP is stale), date of your last hard session, per-sport breakdown. |
| `activities [n] [sport]` | *What did each session actually contain?* Last *n* sessions (default 30), optionally filtered by sport (`activities 10 rowing`). Per session: load, intensity vs FTP, and minutes actually spent hard (Z4+Z5). |
| `top <metric> [n] [sport]` | *What were my best sessions?* Ranks activities (default top 10) by a metric — `hr`, `tss`, `power`, `intensity`, `distance`, `time`, or `output` (kJ) — optionally filtered by sport (`top tss 5 ride`). The leaderboard to `activities`' timeline. |
| `pz` | *What watts is each power zone for me?* The 7 Coggan/Peloton power zones as watt ranges derived from your FTP (they shift when FTP changes). The targets you'd set on a Power Zone ride. |
| `progress [date]` | *Am I improving on this workout?* Resolves that day's workout(s) — bare `progress` uses your latest — and shows every comparable instance chronologically, with **Efficiency Factor** (normalized power ÷ avg HR — watts per heartbeat) and a trend verdict. Climbing EF = fitter. Named classes match exactly; auto-named rides ("Morning Ride" = different routes) compare only rides within ±10% of the anchor's distance. |
| `load [days]` | *Is my training working over time?* Daily fitness/fatigue/form rows for windows ≤14 days; Monday-aligned **weekly rollups** (sessions, load, fitness trend) for longer windows (default 90). Ends with today's form verdict. |
| `week` | *What should this week look like?* One call bundling `summary` + open prescriptions + the last 14 days of activities — the complete planning context. |
| `prescriptions` | *What was planned, and did it happen?* The log (most recent 100) in calendar order with status: open / done / skipped. |
| `activity <id>` | *How did one session actually go?* Deep view of a single activity: load, intensity, zone minutes, hard time, and power bests (1/3/5/20 min) computed from its streams. The session-review tool. |
| `stats` | *What have I done, ever and this year?* Career and year-to-date totals per sport: sessions, hours, distance. |

**Coaching log** (the adaptation loop)

| Command | What it does |
| --- | --- |
| `prescribe <date> <type> <detail> <rationale>` | Records a planned session. `type` is the intensity intent (vo2max, threshold, endurance, recovery, strength, rest); the sport goes in `detail`. Refuses a date that already has an open prescription. |
| `complete <id> <activity_id>` | Marks a prescription done, linked to the activity that fulfilled it. Refuses ids that don't exist. |
| `skip <id> <reason>` | Marks a prescription skipped, with the reason — so adherence history stays honest. |

Every query command prints **human tables** in a terminal and **JSON** when
`STRIDE_FORMAT=json` (agent environments are detected automatically). Malformed
invocations print a targeted `usage:` line; `stride --help` is the full
one-screen manual.

An example of the honesty the tables are built for — `intensity 0.98` rides with
`0m` hard time is the all-moderate trap this tool exists to make undeniable:

```
$ stride activities 4
date        sport    name                          time  load (tss)  intensity (if)  hard
----------  -------  ----------------------------  ----  ----------  --------------  ----
2026-07-25  Workout  45 min Full Body Strength...  46m   -           -               0m
2026-07-24  Ride     45 min Power Zone Ride wi...  45m   72          0.98            0m
2026-07-23  Rowing   45 min Pop Row with Alex ...  45m   23          0.55            0m
2026-07-21  Ride     45 min 80s Ride with Hann...  45m   73          0.99            0m

intensity (if): vs your FTP — ~0.7 easy · 0.85-0.95 tempo · ~1.0 threshold · 1.05+ vo2max
hard:           minutes in HR Z4+Z5 — the column that shows if hard days were actually hard
```

## The coaching layer (optional)

The repo ships an agent skill at
[`.claude/skills/stride/`](.claude/skills/stride/SKILL.md) that compatible LLM
coding agents pick up automatically when run inside this repo. The LLM computes
**none** of the metrics — it reads the engine's JSON, reasons about it in natural
language, and writes its session prescriptions back through the coaching-log
commands:

1. `stride sync && stride analyze`
2. `stride week` → reason about polarization, zone gaps, form, sport balance
3. reconcile: match open prescriptions to completed activities → `stride complete`
4. plan: `stride prescribe` the coming week (the binary refuses double-booked dates)
5. sessions that didn't happen get `stride skip <id> "<reason>"` — adherence
   history stays honest

The prescriptions table is what makes _"next session adapts"_ real: the coach can
see what it asked for and what actually happened. Without an LLM, everything
still works — the human tables carry the same numbers, legends, and verdicts.

## Architecture

```
Strava REST v3 ──▶ auth/sync ──▶ SQLite (~/.stride/db.sqlite) ──▶ analyze ──▶ queries
                   OAuth paste     activities · streams ·          pure math    JSON | tables
                   flow, tokens    metrics · daily_load ·          in Roc
                   + creds in db   prescriptions · config          modules
                                                                        ▲
                                              the LLM coach ────────────┘
                                              reads summary/week, prescribes,
                                              marks sessions done/skipped
```

**What the engine computes** (all deterministic, all unit-tested):

- **TSS ladder** — best available data wins: stream normalized power → Strava weighted
  watts → average watts → zone-weighted hrTSS → `relative_effort` → honest zero.
- **Normalized power** — 30-second rolling average over 1 Hz-resampled streams.
- **CTL/ATL/TSB** — 42-day and 7-day exponential moving averages of daily load,
  extended through **today** so rest days decay fatigue and `form` is true as-of-now.
- **Zones are HR-based** (universal across sports); power feeds TSS/NP only.
- **FTP calibration** — 60-day best 20-min power × 0.95, flagged against config.

**Self-healing by construction:**

- Every metrics row stores the FTP it was computed with — change FTP and the next
  `analyze` recomputes exactly the stale rows.
- Stream arrival and Strava edits invalidate the affected metrics automatically.
- The schema versions itself — upgrading the binary against an existing db
  migrates on the next command.

## Local-first, by design

The database is the product. Everything stride knows lives in one SQLite file on
your machine:

- **Ownership** — your training history doesn't live in someone else's cloud state.
- **Inspectability** — `sqlite3 ~/.stride/db.sqlite` and look at any number's inputs.
- **Reproducibility** — delete `activity_metrics`, run `analyze`, get identical
  numbers back. The raw streams are stored, so recomputation is always possible.
- **Offline analysis** — after a sync, every query works with no network.
- **No hidden state** — the only remote calls are Strava's public API, and the
  rate-limit budget is reported, not hidden.

## Development

```bash
just test      # pure expects (Metrics, Render) -> fresh build -> e2e suite
just build     # release binary
just install   # build + symlink into ~/.local/bin
```

- **Toolchain (pinned):** roc `alpha4-rolling` (nightly 2025-09-09) ·
  [basic-cli 0.20.0](https://github.com/roc-lang/basic-cli) · roc-json 0.13.0.
  Do **not** bump basic-cli to 0.21.0-rc\* — those bundles target Roc's new compiler.
- **Layout:** `app.roc` (all effects — in Roc only the app module can use platform
  effects), `Metrics.roc` (pure math, tested), `Render.roc` (pure tables/formatting,
  tested), `Schema.roc` (pure DDL). Query strings live next to their row decoders on
  purpose — the compiler can't check SQL aliases against decoders, so cohesion is the
  safeguard.
- **Tests:** 54 pure `expect`s + an end-to-end suite (`just e2e`) that runs the real
  binary against a sandboxed `HOME` with seeded activities of known math (power TSS
  exactly 100, hrTSS exactly 55, FTP rescale 100→400, full prescription lifecycle,
  error contracts, corrupt-data resilience).
- **CI:** GitHub Actions on every push runs the same `just test` (Linux needs
  `--linker=legacy`, roc issue #3609; the toolchain tarball is checksum-pinned).

## Roadmap

Intentionally small — things get built when dogfooding demands them:

- Terminal UI for browsing the database
- `.zwo` workout export for smart-trainer owners
- Session-over-session progression views for repeated interval workouts

Personal daily-driver, built for one athlete and open to adopters who bring
their own Strava app credentials.
