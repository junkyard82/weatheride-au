# weatheride-au

Good days to ride to work, next 1–7 days, from the Australian
[Bureau of Meteorology](https://weather.bom.gov.au) — the same data as the
BOM app, instead of Open-Meteo's or wttr.in's interpolated guess.

![The weatheride-au bar row and settings panel: five day dots for the coming week, with the panel's threshold, rainfall and commute-window sliders](preview.png)

One glyph per day in the bar answers the morning question at a glance: is
tomorrow — and the four days after it — a good day to ride? A day shown with
a **bike** is rideable; a dimmed **rain** glyph is a rain day; a dimmed dot
means no data has arrived yet. Hover for the raw per-day summary; click for
the settings panel.

> **Requires** Omarchy Quattro (`omarchy-shell`) and an Australian location —
> the Bureau forecasts nowhere else. No account, no API key. External
> dependencies are all part of a stock Omarchy install: `curl`, `jq` and
> `flock` (util-linux). No sudo, no packages to install, no changes to your
> configuration beyond the plugin's own entry in `shell.json` that
> `omarchy plugin enable` writes.

This is a fork of [weatheride](https://github.com/junkyard82/weatheride) that
swaps the data source to BOM whole-day rain data and keeps itself fully
independent of other weather plugins.

## Install

```bash
omarchy plugin add https://github.com/junkyard82/weatheride-au.git --enable
```

The widget lands in the center section of the bar. Move it with
`omarchy bar move`, or disable the built-in weather pill if it's not wanted:

```bash
omarchy plugin disable omarchy.weather
```

(`omarchy plugin enable omarchy.weather` puts the built-in back any time.)

## Setup

Tell it where you are — a suburb, town or postcode:

```bash
omarchy bar set io.github.junkyard82.weatheride-au location "Brighton VIC"
```

That's it. The name is resolved once against the Bureau's location search and
cached indefinitely — suburbs don't move. Four states have a Brighton, so add
the state ("Brighton VIC") or use the postcode ("3186") when a bare name is
ambiguous; the first match wins. Until a location is set, the bar shows the
dimmed no-data dots and the panel surfaces the setup hint.

## Using it

| Where | Action |
|---|---|
| Bar — left-click any dot | Open / close the settings panel |
| Bar — hover | Per-day tooltip: `WED 4.0mm 60%` (3-letter weekday, total mm, chance used), one day per line |
| Panel — drag a slider | Live preview re-renders the day row as you drag |
| Panel — drag the window sliders' two knobs | Set the commute window (start/end can't cross) |
| Panel — `Esc` / click outside | Close; settings are saved on close |

## What makes a day rideable

Days are judged from tomorrow (`today` is never shown) through
`today + dayCount` (default 5). A day is a **rain day** — the bike is lost —
iff **both** hold:

1. **Chance** — the chance of rain is at or above `rainProbabilityThreshold`, and
2. **Amount** — the day's total rainfall is at or above `rainAmountThreshold`.

Defaults: **5%** and **0.0 mm** — with amount at 0, the chance alone decides.
Missing data never blocks a ride: a day with no chance figure counts as *no*
chance, and a missing amount is treated as *not met*, so the widget never
fabricates rain.

### Two tiers of "chance" (commute window)

BOM's *hourly* forecast covers roughly the next 3 days, its *whole-day*
forecast the full week. weatheride-au uses whichever the data supports —
this is the payoff of the original "good day to ride to work" question:

- **Near days** (tomorrow, day after): every hour of the configured window
  (default **06:00–20:00**) is present, so the chance used is the **maximum
  hourly chance within the window** — "will it rain between 06:00 and
  20:00?", with morning/evening precision.
- **Far days**: BOM has no hourly data there, so the **whole-day** chance is
  used honestly.
- The **rainfall amount is always the whole-day total** (BOM's hourly amounts
  are too sparse and coarse to window reliably).
- A near day whose window hours are only partially covered (the boundary
  rolls through the data as the day progresses) falls back to whole-day for
  that fetch — no hardcoded "first two days", just data availability.
- You don't need to know which tier a day used: the tooltip's percentage is
  simply the chance that was actually applied, and it naturally gets sharper
  the closer the day is.

## Settings

Settings are edited in the panel (threshold, rainfall amount, commute window,
day count), written on close to the widget's own config file:

```
~/.local/state/omarchy/settings/weatheride-au.json
```

The bar watches that file, so saved changes recompute the dots immediately —
no refetch, no restart. Missing file or keys → defaults:

| Key | Default | Meaning |
|---|---|---|
| `rainProbabilityThreshold` | `5` | Chance of rain (%, 0–100) that makes a rain day, either within the window (near days) or whole-day (far days) |
| `rainAmountThreshold` | `0.0` | Day-total rainfall (mm, 0.0–50.0) that makes a rain day; `0.0` = amount rule off, chance alone decides |
| `windowStartHour` | `6` | Commute window start (0–23, inclusive) — window applies to a day iff every hour in `[start, end)` is present in the hourly data |
| `windowEndHour` | `20` | Commute window end (0–23, exclusive); an invalid/crossed pair resets to 06:00–20:00 |
| `dayCount` | `5` | Days shown after today (1–7) |

The window sliders in the panel form a single dual-thumb
[`RangeSlider`](RangeSlider.qml) — start and end can't cross, so a window is
always well-formed. The panel's live preview re-runs the full two-tier rule
against the last good data as any slider moves.

## Uninstall

```bash
omarchy plugin disable io.github.junkyard82.weatheride-au   # stop showing the row
omarchy plugin remove io.github.junkyard82.weatheride-au    # delete the checkout
```

That removes the plugin directory and its `shell.json` entry. The response
cache is yours and is left alone; clear it if you want a clean slate:

```bash
rm -rf ~/.local/state/omarchy/weatheride-au ~/.local/state/omarchy/settings/weatheride-au.json
```

## How it behaves

- **Cached, politely.** The last good response is cached in
  `~/.local/state/omarchy/weatheride-au/` (mode `0600`) by the bundled
  `bin/bom-api` bridge. If the network is down, the cached data stays on
  screen and a retry is armed.
- **No cached data on first load.** A cold start keeps the dimmed no-data
  dots until a **live** fetch succeeds — an outage cache is never presented
  as fresh. From then on, last-good survives outages.
- **Measured cadence.** First fetch 60 s after start (boot network race),
  then every 2 h. On failure: retry every 1 min while nothing is on screen,
  every 10 min once last-good exists, back to 2 h on success.
- **Several monitors, one round of requests.** Each monitor's bar hosts its
  own copy of the widget; the bridge serialises them with `flock`, so they
  share one fetch.
- **Independent of other plugins.** It reads no other plugin's files —
  location comes from its own `shell.json` entry, config from its own file,
  data from its own forked bridge. It keeps working if `omarchy.weather` or
  `io.github.zuccs.bom-weather` are uninstalled.
- **Theme-native.** Colours, fonts, spacing and corner radius come from the
  shell's theme tokens, so it matches whatever Omarchy theme you switch to.
- **Metric only.** It's the Bureau of Meteorology; it speaks Celsius,
  kilometres and millimetres, and so does this widget.

## Privacy & security

- The only network endpoint is `https://api.weather.bom.gov.au` — the public,
  keyless API behind the Bureau's own app and website. Nothing about you is
  sent beyond the location you configured; there is no IP geolocation. The
  only file written is the response cache above.
- That API is **unofficial**: undocumented, and its responses carry a BOM
  copyright notice reserving the data service. It has been stable for years
  and an ecosystem of open-source clients reads it, but the Bureau owes it to
  nobody — if it changes or goes away, this widget degrades to its cache and
  says so. The bridge sends an honest User-Agent and the refresh cadence
  keeps usage well below what the BOM app itself generates.
- Everything the API returns is treated as untrusted. Response bodies are
  capped at 1 MiB before anything parses them, tooltips are plain text, and
  every displayed string is bounded.
- The state directory sits at a predictable path, so the bridge treats it as
  hostile: it refuses to use it if `omarchy/` or `weatheride-au/` is a
  symlink, takes its cross-monitor lock on the directory itself (there is no
  lock file to plant), writes caches only via `rename(2)`, and reads them
  with a size cap and a timeout so a swapped-in FIFO or oversized file can't
  wedge the shell.
- `bin/bom-api` is ~400 lines of bash. Read it before you enable the plugin,
  as with any Omarchy plugin.

## Development

```bash
# Install the normal way — the result is a plain git checkout you can edit in place.
omarchy plugin add https://github.com/junkyard82/weatheride-au.git --enable
cd ~/.config/omarchy/plugins/io.github.junkyard82.weatheride-au

omarchy plugin validate .
qmllint -I "$OMARCHY_PATH/shell" *.qml   # note: qmllint 1.0 rejects `function x(): void`, as it does on first-party Weather
node test/model.test.js                  # Model.js is plain JS and unit-tested (43 tests)
bin/bom-api weather "brighton vic" --max-age 0 | jq   # the bridge works from any terminal
```

Saving files under `~/.config/omarchy/plugins/` hot-reloads most plugin kinds,
but bar-widget QML is currently cached until the shell restarts — run
`omarchy-restart-shell` after editing `BarWidget.qml` or `Panel.qml`, then
check the journal (`journalctl --user -u omarchy-shell`) for QML errors.

Layout:

```
manifest.json     plugin identity, settings schema and defaults
BarWidget.qml     bar entry point: the day-dot row + fetch lifecycle
Panel.qml         settings popup: sliders, dual-thumb window, live preview
RangeSlider.qml   self-contained dual-thumb slider component
Model.js          pure logic: two-tier rain rule, config parsing, tooltips
bin/bom-api       the only code that touches the network (forked from
                  io.github.zuccs.bom-weather, MIT)
test/             node:test suite for Model.js + BOM-shaped fixtures
```

## License

MIT — see [LICENSE](LICENSE). `bin/bom-api` is forked from the MIT-licensed
[`io.github.zuccs.bom-weather`](https://github.com/zuccs/omarchy-bom-weather)
plugin (© 2026 Daniel Zuccon, attributed in LICENSE); everything else is
original work by junkyard82 — the successor of his earlier unlicensed
`weatheride` prototype, of which this is a new version. Not affiliated with
the Bureau of Meteorology or Omarchy. Weather data © Commonwealth of
Australia, Bureau of Meteorology.