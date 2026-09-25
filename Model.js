// weatheride-au — pure logic. Imported via `import "Model.js" as Model`
// (BarWidget.qml + Panel.qml). No QML state, no root.*, no side effects —
// every function is a pure function of its arguments so the whole module
// can be unit-tested in plain node (tests: /home/user/Projects/weatheride-au/test/).
//
// FORK of weatheride's Model.js, converted 2026-09-06 to consume the BOM
// bridge output (bin/bom-api) instead of Open-Meteo. Two-tier rain rule
// (decided 2026-09-06): a configurable commute window (default 06:00–20:00)
// applies where BOM's HOURLY data fully covers the window; elsewhere the
// WHOLE-DAY daily aggregates are used. The whole-day-only conversion is
// extended, not reverted — see the rain-rules comment below.
//
// Config shape (all keys optional; missing/invalid → defaults):
//   { "rainProbabilityThreshold": <number, %>,
//     "rainAmountThreshold": <number 0–50, mm>,
//     "windowStartHour": <number 0–23, inclusive>,
//     "windowEndHour": <number 0–23, exclusive>,
//     "dayCount": <number 1–7, days shown after today> }

// Rain-day rules (two-tier, see AGENTS.md "Active plan"). A day is a RAIN
// day iff BOTH hold (AND):
//  1. CHANCE rule — the chance actually used is TIERED:
//       window tier: if every hour in [windowStartHour, windowEndHour) of
//         that local day is PRESENT in the hourly data, chance = MAX hourly
//         rain.chance over those window hours (old weatheride semantics).
//       whole-day tier: otherwise chance = daily[].rain.chance. (BOM's
//         hourly forecast only reaches ~3 days, so far days always use this.)
//     missing/null chance counts as NO chance — never a fake ride-block.
//  2. AMOUNT rule — always WHOLE-DAY for every day: daily[].rain.amount.max
//     >= rainAmountThreshold. The window affects only the chance side. A
//     missing/null amount is NOT met (never fabricates rain).
//  - index 1..dayCount of daily[] = tomorrow .. today+dayCount; today
//    (daily[0]) is ignored, exactly as in weatheride.
//  - no "always at least one ride" rule (removed in weatheride step E).

function defaultConfig() {
  return { rainProbabilityThreshold: 5, rainAmountThreshold: 0, windowStartHour: 6, windowEndHour: 20, dayCount: 5 }
}

// Merge a raw config (JSON string or object) over the defaults.
// Malformed JSON / non-object / array → plain defaults.
//   - rainProbabilityThreshold: finite number, clamped to 0–100
//   - rainAmountThreshold: finite number, rounded to 0.1 mm, clamped 0–50
//   - windowStartHour / windowEndHour: finite number, rounded, clamped 0–23
//   - windowEndHour <= windowStartHour → both reset to 6/20
//   - dayCount: finite number, rounded, clamped 1–7
// Unknown keys are ignored. Always returns a fresh object.
function parseConfig(raw) {
  var cfg = defaultConfig()
  if (raw == null || raw === "") return cfg
  var data
  if (typeof raw === "string") {
    try {
      data = JSON.parse(raw)
    } catch (e) {
      return cfg
    }
  } else {
    data = raw
  }
  if (!data || typeof data !== "object" || Array.isArray(data)) return cfg

  if (typeof data.rainProbabilityThreshold === "number" && isFinite(data.rainProbabilityThreshold))
    cfg.rainProbabilityThreshold = Math.min(100, Math.max(0, data.rainProbabilityThreshold))
  if (typeof data.rainAmountThreshold === "number" && isFinite(data.rainAmountThreshold))
    cfg.rainAmountThreshold = Math.min(50, Math.max(0, Math.round(data.rainAmountThreshold * 10) / 10))
  if (typeof data.windowStartHour === "number" && isFinite(data.windowStartHour))
    cfg.windowStartHour = Math.min(23, Math.max(0, Math.round(data.windowStartHour)))
  if (typeof data.windowEndHour === "number" && isFinite(data.windowEndHour))
    cfg.windowEndHour = Math.min(23, Math.max(0, Math.round(data.windowEndHour)))
  if (cfg.windowEndHour <= cfg.windowStartHour) {
    cfg.windowStartHour = 6
    cfg.windowEndHour = 20
  }
  if (typeof data.dayCount === "number" && isFinite(data.dayCount))
    cfg.dayCount = Math.min(7, Math.max(1, Math.round(data.dayCount)))
  return cfg
}

// `dayCount` empty day states (default 5, clamped 1–7): non-rideable, no
// data — the pre-fetch default (dimmed no-data dots), never a fake ride
// signal.
function emptyDayStates(dayCount) {
  var n = (typeof dayCount === "number" && isFinite(dayCount))
      ? Math.min(7, Math.max(1, Math.round(dayCount)))
      : 5
  var out = []
  for (var i = 0; i < n; i++)
    out.push({ date: "", rideable: false, mm: 0, maxProb: -1, hasData: false })
  return out
}

// ---- BOM date handling ------------------------------------------------------
//
// BOM timestamps are ISO 8601 with an explicit zone. For the daily forecast
// each entry is stamped at "local midnight expressed in UTC" — i.e. for a
// UTC+10 place the date string is the previous UTC day's 14:00Z. Adding half
// a day (43200000 ms) then reading the machine-local calendar date recovers
// the intended local date for any real timezone (|offset| < 12h), which is
// how the upstream bom-weather plugin labels its days. This matters only so
// the tooltip/weekday is right — the day ORDER comes from the bridge's
// daily[] array (index 0 = today), so no date arithmetic drives the indexing.

function parseIso(text) {
  var s = String(text == null ? "" : text).replace(/^\s+|\s+$/g, "").slice(0, 40)
  if (!/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?(\.\d+)?(Z|[+-]\d{2}:?\d{2})$/.test(s)) return null
  var d = new Date(s)
  return isNaN(d.getTime()) ? null : d
}

function pad2(n) { return (n < 10 ? "0" : "") + n }

// BOM daily `date` (local midnight expressed in UTC) → the local calendar
// date as "YYYY-MM-DD". Returns "" on unparseable input. TZ-robust: the +12h
// slack plus reading the machine-local date recovers the intended local date
// regardless of the machine's own offset.
function localDayString(isoDate) {
  var d = parseIso(isoDate)
  if (!d) return ""
  d = new Date(d.getTime() + 43200000)   // +12h: local noon of the intended day
  return d.getFullYear() + "-" + pad2(d.getMonth() + 1) + "-" + pad2(d.getDate())
}

// Rain rule over a bin/bom-api weather response (raw JSON string).
// Returns `dayCount` day states (index 0 = tomorrow … dayCount-1), or null
// when the raw data is unusable (bad JSON, ok !== true, missing/too-short
// daily array, or a malformed day). `config` is optional; missing keys fall
// back to defaultConfig().
function computeDayStates(raw, config) {
  var d = defaultConfig()
  if (config && typeof config === "object" && !Array.isArray(config)) {
    if (typeof config.rainProbabilityThreshold === "number" && isFinite(config.rainProbabilityThreshold))
      d.rainProbabilityThreshold = config.rainProbabilityThreshold
    if (typeof config.rainAmountThreshold === "number" && isFinite(config.rainAmountThreshold))
      d.rainAmountThreshold = Math.min(50, Math.max(0, Math.round(config.rainAmountThreshold * 10) / 10))
    if (typeof config.windowStartHour === "number" && isFinite(config.windowStartHour))
      d.windowStartHour = config.windowStartHour
    if (typeof config.windowEndHour === "number" && isFinite(config.windowEndHour))
      d.windowEndHour = config.windowEndHour
    if (typeof config.dayCount === "number" && isFinite(config.dayCount))
      d.dayCount = Math.min(7, Math.max(1, Math.round(config.dayCount)))
  }
  var threshold = d.rainProbabilityThreshold
  var amountThreshold = d.rainAmountThreshold
  var startHour = d.windowStartHour
  var endHour = d.windowEndHour

  var parsed
  try {
    parsed = JSON.parse(String(raw || ""))
  } catch (e) {
    return null
  }
  if (!parsed || typeof parsed !== "object" || parsed.ok !== true) return null
  var daily = parsed.daily
  if (!Array.isArray(daily) || daily.length < d.dayCount + 1) return null

  // Build a per-local-date hourly index so the data-driven window rule can
  // decide, per day, whether every hour in [startHour, endHour) is present.
  // Local date + hour come from parsing the (UTC ISO) hourly time in the
  // machine's own zone — the same zone the daily local dates are expressed
  // in. If there is no usable hourly data at all, every day falls back to
  // whole-day (graceful).
  var byDate = {}
  var haveHourly = false
  if (Array.isArray(parsed.hourly)) {
    for (var hi = 0; hi < parsed.hourly.length; hi++) {
      var he = parsed.hourly[hi]
      if (!he || typeof he !== "object") continue
      var t = parseIso(he.time)
      if (!t) continue
      var ld = t.getFullYear() + "-" + pad2(t.getMonth() + 1) + "-" + pad2(t.getDate())
      var lh = t.getHours()
      if (!byDate[ld]) byDate[ld] = { hours: {}, chances: {} }
      byDate[ld].hours[lh] = true
      var hr = he.rain && typeof he.rain === "object" ? parseFloat(he.rain.chance) : NaN
      if (!isNaN(hr)) byDate[ld].chances[lh] = hr
      haveHourly = true
    }
  }

  // Data-driven window chance for a day: the max hourly chance over
  // [startHour, endHour) of that day, but ONLY if every window hour is
  // present in the hourly data — otherwise null (the caller then falls back
  // to whole-day). "An hour with no rain % value" = an hour absent from the
  // response (BOM's per-hour chance is never null), so presence is the test.
  function windowChanceFor(localDate) {
    var bucket = byDate[localDate]
    if (!bucket) return null
    var max = -1
    for (var h = startHour; h < endHour; h++) {
      if (bucket.hours[h] !== true) return null   // an in-window hour is missing
      if (bucket.chances[h] !== undefined && bucket.chances[h] > max) max = bucket.chances[h]
    }
    return max >= 0 ? max : null
  }

  var states = []
  for (var day = 1; day <= d.dayCount; day++) {
    var entry = daily[day]
    if (!entry || typeof entry !== "object") return null
    var rain = entry.rain && typeof entry.rain === "object" ? entry.rain : {}
    var wholeDayChance = parseFloat(rain.chance)
    var amount = (rain.amount && typeof rain.amount === "object")
        ? parseFloat(rain.amount.max) : NaN

    var localDate = localDayString(entry.date)
    var windowChance = haveHourly ? windowChanceFor(localDate) : null
    // The chance actually used: the window max when the window is fully
    // covered, else the whole-day chance (two-tier, decided 2026-09-06).
    var chanceUsed = windowChance !== null ? windowChance : wholeDayChance

    // Chance rule: missing/null chance = NO chance (never a fake ride-block).
    var chanceOk = !isNaN(chanceUsed) && chanceUsed >= threshold
    // Amount rule: 0.0 threshold = OFF (chance alone decides); amount is
    // WHOLE-DAY for every day (the window affects only chance). A missing/null
    // amount is treated as NOT met (never fabricates rain).
    var amountOk = true
    if (amountThreshold > 0) amountOk = !isNaN(amount) && amount >= amountThreshold

    var rainy = chanceOk && amountOk
    states.push({
      date: localDate,
      rideable: !rainy,
      mm: isNaN(amount) ? 0 : amount,          // whole-day total (amount.max)
      maxProb: isNaN(chanceUsed) ? -1 : chanceUsed,   // chance actually used
      hasData: true
    })
  }
  return states
}

// "YYYY-MM-DD" → 3-letter weekday ("SUN"…"SAT"). Date math in UTC so the
// result never shifts across time zones (the date string is already local).
function weekday3(date) {
  var wd = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
  return wd[new Date(Date.UTC(+date.slice(0, 4), +date.slice(5, 7) - 1, +date.slice(8, 10))).getUTCDay()]
}

// Per-day "WED x.xmm NN%" summary (3-letter weekday) — the permanent tooltip.
// Days stacked one per line (carried from weatheride 2026-09-03). Missing
// probability → "?". Invalid input / wrong length (not 1–7) → "weatheride".
function formatTooltip(states) {
  if (!states || states.length < 1 || states.length > 7) return "weatheride"
  return states.map(function(s) {
    var p = s.maxProb < 0 ? "?" : Math.round(s.maxProb) + "%"
    return weekday3(s.date) + " " + s.mm.toFixed(1) + "mm " + p
  }).join("\n")
}

// NOTE (2026-09-06): weatheride's parseLocationFile is GONE — weatheride-au
// reads its location from the widget's own shell.json setting
// (`setting("location", ...)`), not from omarchy.weather's weather.json, so
// it has no dependency on that file (user decision: fully independent).
