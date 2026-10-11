import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// weatheride-au — rideability row (configurable day count, 1–7, default 5),
// sourced from the Australian Bureau of Meteorology via the forked
// bin/bom-api bridge (BOM whole-day data; independent of other plugins —
// user decision 2026-09-06).
// Rideability (whole-day): a day is rain only if daily rain chance >=
// threshold AND day total rainfall >= amount threshold (default 0.0 mm =
// amount rule off, chance alone decides). No commute window — the 06:00–20:00
// window of weatheride is gone (user decision: whole-day data, keep it
// simple). Dots show per-day state; tooltip is the raw per-day
// "WED x.xmm NN%" summary (3-letter weekday).
// Refresh: every 2 h; on fetch failure keep last-good state and retry every
// 1 min while no data is on screen (!hasFetched), every 10 min once
// last-good exists — then back to 2 h on success. A config-file change
// (weatheride-au.json, watched) re-runs the rain rule against the last good
// fetch — no new network round-trip. The first fetch after (re)start is
// delayed 30 s (boot network race, diagnosed in weatheride).
// No cached data on first load (user decision 2026-09-06): a STALE bridge
// response (outage cache) on the very first load does NOT clear the no-data
// dots — they stay until a live (non-stale) fetch succeeds. A fresh
// cached:true response (a same-instant sibling fetch within the bridge's 10 s
// dedupe window) is genuine data and clears them. See onStreamFinished.
// Location: the widget's own shell.json setting, `omarchy bar set
// io.github.junkyard82.weatheride-au location "Brighton VIC"` — read via the base
// setting() helper (no omarchy.weather file dependency).
// Glyphs: rideable = "\u{F00A3}" (md-bike)
//         cold     = "\u{F0717}" (nf-md-snowflake) — cold day, no color change
//         rain     = "\u{E318}"  (nf-weather-rain), dimmed
//         no data  = "\u{F4C3}"  (nf-oct-dot), dimmed — pre-fetch default
// Glyph colors: normal = bar foreground; hot day = bar alert color
// (bar.urgent). Temperature warnings are display-only and never
// ride-blocking; a cold day swaps the bike for a snowflake glyph (glyph
// change, not a color change); rain+hot keeps the dimmed colored
// treatment, rain+cold a dimmed plain rain glyph.
// Pure logic (rain rule, config, weekday, tooltip, BOM date parsing) lives
// in Model.js; this file keeps only the stateful QML.

BarWidget {
  id: root
  moduleName: "io.github.junkyard82.weatheride-au"

  readonly property string rideGlyph: "\u{F00A3}"
  readonly property string snowGlyph: "\u{F0717}"  // nf-md-snowflake, cold day
  readonly property string rainGlyph: "\u{E318}"
  readonly property string unknownGlyph: "\u{F4C3}"   // nf-oct-dot, no data loaded yet

  // Location from this widget's shell.json entry (base setting() helper).
  readonly property string location: String(setting("location", "") || "")
  onLocationChanged: root.refresh()

  // The forked bridge (bundled with this plugin — independent of bom-weather).
  readonly property string scriptPath: String(Qt.resolvedUrl("bin/bom-api")).replace(/^file:\/\//, "")

  // Temperature warning color (display only, never ride-blocking): hot =
  // the bar's alert color. (Cold is a glyph swap, not a color: snowflake.)
  readonly property color hotColor: root.bar ? root.bar.urgent : Color.urgent

  // STEP 4: per-day state. Index 0 = tomorrow … N-1 = day+N (N =
  // config.dayCount, 1–7, default 5). Each entry:
  //   { date, rideable, mm, maxProb, hasData, hot, cold }
  // Initial state is non-rideable (dimmed dot) — never a fake ride signal
  // before the first successful fetch. The rain rule and weekday/tooltip
  // formatting live in Model.js.
  property var dayStates: Model.emptyDayStates()

  // Config: { rainProbabilityThreshold, rainAmountThreshold, dayCount }.
  // File: ~/.local/state/omarchy/settings/weatheride-au.json — the panel
  // writes it, this bar watches it (no IPC; both per-monitor instances pick
  // it up independently). Missing file/keys → defaults (not a fetch failure);
  // bad JSON → defaults + warn.
  property var config: Model.defaultConfig()

  // Last good forecast JSON (bridge output): a config-file change re-runs
  // the rain rule against this instead of fetching again.
  property string lastRaw: ""

  function applyDayStates(states) {
    if (!states || states.length < 1 || states.length > 7) return
    root.dayStates = states
    root.debugTooltip = Model.formatTooltip(states)
  }

  // Per-day "WED x.xmm NN%" summary (3-letter weekday) — the permanent tooltip.
  property string debugTooltip: "weatheride"

  // Refresh + failure state (same semantics as weatheride):
  //   - refreshTimer: normal 2 h cadence, re-armed on every success.
  //   - retryTimer:   1 min cadence while failing with no data on screen
  //     (!hasFetched), 10 min once last-good exists; on success back to 2 h.
  //   - initialDelayTimer: the first fetch after (re)start waits
  //     initialFetchDelayMs so it lands on a live network (boot DNS race).
  //   - last-good state is kept on failure — no staleness expiry, no
  //     failure visual.
  property bool fetchFailed: false
  property bool hasFetched: false
  property bool firstFetchScheduled: false
  property bool locationWarned: false
  readonly property int initialFetchDelayMs: 30 * 1000
  Timer { id: refreshTimer; interval: 2 * 60 * 60 * 1000; repeat: true; onTriggered: root.refresh() }
  Timer { id: retryTimer; interval: 10 * 60 * 1000; repeat: true; onTriggered: root.refresh() }
  Timer { id: initialDelayTimer; interval: root.initialFetchDelayMs; repeat: false; onTriggered: root.refresh() }

  function onFetchSuccess() {
    root.fetchFailed = false
    root.hasFetched = true
    retryTimer.stop()
    retryTimer.interval = 10 * 60 * 1000   // reset cadence for any future failure
    refreshTimer.restart()   // re-arm the 2 h cadence from now
  }
  function onFetchFailure() {
    if (!root.fetchFailed) {
      root.fetchFailed = true
      refreshTimer.stop()
      retryTimer.interval = root.hasFetched ? 10 * 60 * 1000 : 1 * 60 * 1000
      retryTimer.restart()
    }
    console.warn("weatheride-au: forecast fetch failed, retrying in " +
      (root.hasFetched ? "10 min" : "1 min"))
  }

  // Config file watch. The panel writes this file; the bar just reads it and
  // recomputes the dots — no IPC. Missing file = defaults; bad JSON =
  // defaults + warn.
  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/settings/weatheride-au.json"
    watchChanges: true
    printErrors: false
    // loaded fires after each (re)read completes, so text() is fresh there.
    // fileChanged fires before the C++ re-read completes (text() stale) and
    // several times per write — so debounce a reload instead of reading now.
    onLoaded: root.applyConfigFile(String(text()))
    onFileChanged: configReloadTimer.restart()
    onLoadFailed: root.applyConfigFile("")   // file missing/deleted → defaults
  }

  // Debounced configFile.reload() (see the fileChanged comment above).
  Timer {
    id: configReloadTimer
    interval: 200
    repeat: false
    onTriggered: configFile.reload()
  }

  // Apply the config file's content (raw = file text; "" = file missing).
  // Bad JSON → defaults + warn. Same content as last applied → no-op.
  // A config change is not a fetch: the fetch/retry state is untouched.
  property var lastConfigRaw: null   // null sentinel: real content always differs
  function applyConfigFile(raw) {
    if (raw === root.lastConfigRaw) return
    root.lastConfigRaw = raw
    if (raw !== "") {
      try {
        var parsed = JSON.parse(raw)
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
          console.warn("weatheride-au: config is not a JSON object, using defaults")
      } catch (e) {
        console.warn("weatheride-au: bad config JSON, using defaults:", e)
      }
    }
    root.config = Model.parseConfig(raw)
    console.warn("weatheride-au: config applied (threshold " + root.config.rainProbabilityThreshold
      + "%, rain " + root.config.rainAmountThreshold.toFixed(1) + "mm, window "
      + root.config.windowStartHour + "-" + root.config.windowEndHour
      + ", " + root.config.dayCount + " days)")
    root.recomputeFromConfig()
  }

  // Re-run the rain rule with the current config against the last successful
  // fetch (if any); before the first fetch, resize the no-data row to the new
  // day count. No network. Deliberately does not call
  // onFetchSuccess/onFetchFailure — a config change is not a fetch.
  function recomputeFromConfig() {
    if (!root.lastRaw) {
      root.dayStates = Model.emptyDayStates(root.config.dayCount)
      return
    }
    var states = Model.computeDayStates(root.lastRaw, root.config)
    if (states) root.applyDayStates(states)
  }

  function fetchForecast() {
    if (!root.location) return
    // --max-age 0 forces a live fetch (the bridge's own 10 s dedupe still
    // coalesces the two per-monitor instances into one round via flock).
    forecastProc.command = [root.scriptPath, "weather", root.location, "--max-age", "0"]
    forecastProc.running = true
  }

  function refresh() {
    // First fetch after (re)start: wait for the network (boot DNS race).
    // Triggers arriving while the delay is pending are coalesced; the
    // timer's call does the actual fetch.
    if (!root.hasFetched && !root.firstFetchScheduled) {
      root.firstFetchScheduled = true
      initialDelayTimer.start()
      console.warn("weatheride-au: first fetch delayed "
        + (root.initialFetchDelayMs / 1000) + " s (network not up at boot)")
      return
    }
    if (initialDelayTimer.running) return
    if (!root.location) {
      if (!root.locationWarned) {
        root.locationWarned = true
        console.warn("weatheride-au: no location set — run: " + Model.SETUP_COMMAND)
      }
      return
    }
    if (!forecastProc.running) root.fetchForecast()
  }

  // Standard bar-pill breathing room on the OUTER edges only: the dot group
  // gets the same style-scaled side margins as a single widget pill
  // (WidgetButton default horizontalMargin 8.5; clock 8.75, powerdeck 7.5,
  // fronius pillMargin Style.spaceReal(8.5)) instead of the dots' own 2px
  // edge margins sitting against its neighbours. Spacing BETWEEN the dots
  // stays tight (horizontalMargin: 2 on each dot below).
  readonly property real pillMargin: Style.spaceReal(8.5)
  implicitWidth: dotRow.implicitWidth + pillMargin * 2
  implicitHeight: dotRow.implicitHeight

  // Settings panel (Panel.qml), the omarchy.weather panelLoader pattern.
  // Shape contract for the bar's popout routing.
  readonly property bool opened: panelLoader.item ? panelLoader.item.opened === true : false
  readonly property bool popoutSwitchClosing: panelLoader.item
         ? panelLoader.item.popoutSwitchClosing === true : false

  function open() {
    if (panelLoader.item && panelLoader.item.open) panelLoader.item.open()
  }
  function close() {
    if (panelLoader.item && panelLoader.item.close) panelLoader.item.close()
  }
  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }
  function togglePanel() {
    if (panelLoader.item && panelLoader.item.toggle) panelLoader.item.toggle()
  }
  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = root
    if ("hostWidget" in target) target.hostWidget = root
  }

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }
  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()

  // One dot per day in root.dayStates (index i = day i+1, tomorrow first).
  // Row + Repeater (day count configurable 1–7). Left-click any dot →
  // settings panel.
  Row {
    id: dotRow
    anchors.centerIn: parent
    Repeater {
      model: root.dayStates.length
      WidgetButton {
        required property int index
        bar: root.bar
        text: root.dayStates[index].hasData
             ? (root.dayStates[index].rideable
                  ? (root.dayStates[index].cold ? root.snowGlyph : root.rideGlyph)
                  : root.rainGlyph)
             : root.unknownGlyph
        dimmed: !root.dayStates[index].hasData || !root.dayStates[index].rideable
        // Temperature warning (display only): hot = bar alert color; cold =
        // swaps the bike for a snowflake glyph (no color change); rain+hot /
        // rain+cold keep the dimmed treatment above.
        active: root.dayStates[index].hot
        activeColor: root.hotColor
        // New-install QoL (mirrors bom-weather's "location not set" hint):
        // with no location configured the tooltip says so instead of showing
        // the placeholder; the panel (left-click) has the setup command.
        tooltipText: root.location === "" ? "weatheride-au · location not set" : root.debugTooltip
        horizontalMargin: 2
        onPressed: function(b) { if (b === Qt.LeftButton) root.togglePanel() }
      }
    }
  }

  Process {
    id: forecastProc
    onExited: function(exitCode) {
      if (exitCode !== 0) root.onFetchFailure()   // bridge/curl failure
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) { root.onFetchFailure(); return }
        // No cached data on first load (user decision 2026-09-06): a STALE
        // response (outage cache served by the bridge) on the very first load
        // must not clear the no-data dots — keep them and retry. A fresh
        // cached:true response (same-instant sibling fetch within the bridge's
        // 10 s dedupe) is genuine data and is accepted (it would otherwise
        // strand the second monitor's dots for a minute).
        var stale = false
        try {
          var parsed = JSON.parse(raw)
          if (parsed && parsed.stale === true) stale = true
        } catch (e) { /* computeDayStates rejects it below */ }
        if (!root.hasFetched && stale) {
          root.onFetchFailure()
          return
        }
        var states = Model.computeDayStates(raw, root.config)
        if (states) {
          root.lastRaw = raw
          root.applyDayStates(states)
          root.onFetchSuccess()
        } else {
          // keep last-good state (never a fake ride signal)
          root.onFetchFailure()
        }
      }
    }
  }

  // Backstop: onLocationChanged and the config FileView already call
  // refresh(); this covers the case where neither fires before first paint.
  // refresh() is idempotent while a fetch is in flight or the first-fetch
  // delay is pending.
  Component.onCompleted: {
    console.warn("weatheride-au: DIAG onCompleted")
    root.refresh()
  }
}
