import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// weatheride-au — settings panel.
// Opened by left-clicking the bar widget (Loader in BarWidget.qml). The
// panel↔bar contract is the config file: this panel WRITES it (closing the
// panel writes it via jq + tee + atomic mv into
// ~/.local/state/omarchy/settings/weatheride-au.json — save-on-close, no Save
// button per shell convention), the bar WATCHES it (BarWidget.qml) — no IPC.
//
// The panel does its OWN forecast fetch on open (the bar widget's data is not
// reachable without IPC) and re-runs Model.computeDayStates against the
// current slider values for the live preview — the preview always reflects
// exactly what closing will write (both go through Model.parseConfig).
//
// Converted 2026-09-06 from weatheride's Panel.qml for the BOM source:
//   - fetch via the forked bin/bom-api bridge, location from the widget's own
//     shell.json setting (no omarchy.weather file, no wttr auto-detect)
//   - the 06:00–20:00 window sliders are REMOVED (whole-day BOM rain data)
//   - config schema is now { rainProbabilityThreshold, rainAmountThreshold,
//     dayCount }.
//
// Window: the omarchy.weather variant — Panel {} base (qs.Ui) +
// KeyboardPanel + PanelKeyCatcher, opened via the controller the base owns.

Panel {
  id: root
  moduleName: "io.github.junkyard82.weatheride-au"
  // No IPC: only our own widget opens this panel (left click), and the
  // config file is the only channel to the bar.
  manageIpc: false

  // Injected by BarWidget.qml's Loader (same contract as omarchy.weather).
  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  // Location from this widget's shell.json entry (base setting() helper).
  readonly property string location: String(setting("location", "") || "")
  // Live shell.json patches (omarchy bar set …) reach this panel through the
  // injected settings object. When the location appears/changes (e.g. the
  // setup command was run while this panel is open) re-fetch so the preview
  // comes up without closing/reopening. refresh() no-ops while closed.
  onLocationChanged: root.refresh()
  readonly property string scriptPath: String(Qt.resolvedUrl("bin/bom-api")).replace(/^file:\/\//, "")

  function open() {
    root.controller.show()
    root.fetchAttempts = 0
    root.dirty = false   // sliders are re-seeded from the file below
    configFile.reload()   // sliders reflect the file's current content
    root.refresh()
  }
  // Save-on-close: every exit route funnels through here — Esc
  // (PanelKeyCatcher.onCloseRequested), outside-click (KeyboardPanel
  // dismissal calls owner.close()), and the popout switch (base
  // closeForPopoutSwitch → close) — so this one hook commits everything.
  function close() {
    if (root.dirty) root.saveConfig()
    root.controller.hide()
  }
  function toggle() { root.opened ? root.close() : root.open() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  // Same three glyphs as the bar dots (shared visual decisions; the
  // code points are deliberately duplicated — no cross-file QML state).
  readonly property string rideGlyph: "\u{F00A3}"
  readonly property string rainGlyph: "\u{E318}"
  readonly property string unknownGlyph: "\u{F4C3}"

  // ---- config state (what the sliders edit; written on close if changed) ----
  readonly property string configDir:
      Quickshell.env("HOME") + "/.local/state/omarchy/settings"
  readonly property string configPath: root.configDir + "/weatheride-au.json"
  property var threshold: 5
  property var rainAmount: 0   // mm; AND rule with the % chance (0.0 = chance rule alone)
  property var windowStart: 6   // commute window start hour (two-tier; 0–23)
  property var windowEnd: 20    // commute window end hour (two-tier; 0–23)
  property var dayCount: 5     // days shown, tomorrow…day+N; 1–7
  // True once a slider has moved since open(); close() commits only when
  // dirty, so an unedited open→close writes nothing (no file churn, no
  // spurious bar "config applied" lines).
  property bool dirty: false

  // The validated config object the preview runs on: parseConfig of the
  // slider values, so the preview can never diverge from the close-time
  // write payload.
  readonly property var previewConfig: Model.parseConfig({
    rainProbabilityThreshold: root.threshold,
    rainAmountThreshold: root.rainAmount,
    windowStartHour: root.windowStart,
    windowEndHour: root.windowEnd,
    dayCount: root.dayCount
  })
  readonly property var previewStates: {
    var states = Model.computeDayStates(root.lastRaw, root.previewConfig)
    return states || Model.emptyDayStates(root.dayCount)
  }

  function previewGlyph(index) {
    var s = root.previewStates[index]
    if (!s || !s.hasData) return root.unknownGlyph
    return s.rideable ? root.rideGlyph : root.rainGlyph
  }
  function previewDim(index) {
    var s = root.previewStates[index]
    return !s || !s.hasData || !s.rideable
  }

  FileView {
    id: configFile
    path: root.configPath
    printErrors: false
    // Deliberately NOT watched: the panel re-reads on open (open() calls
    // reload()); a live watch would fight a slider mid-drag. The bar-side
    // watch is the FileView in BarWidget.qml.
    onLoaded: root.applyConfigFile(String(text()))
    onLoadFailed: root.applyConfigFile("")
  }

  // Seed the sliders from the file (missing/bad → defaults via parseConfig).
  function applyConfigFile(raw) {
    var cfg = Model.parseConfig(raw)
    root.threshold = Math.round(Number(cfg.rainProbabilityThreshold))
    root.rainAmount = Number(cfg.rainAmountThreshold)
    root.windowStart = cfg.windowStartHour
    root.windowEnd = cfg.windowEndHour
    root.dayCount = cfg.dayCount
  }

  // ---- forecast (own fetch on open; via the forked bridge, whole-day) ----
  property string lastRaw: ""
  property int fetchAttempts: 0
  readonly property int maxFetchAttempts: 3

  Timer {
    id: fetchRetryTimer
    interval: 10 * 1000
    repeat: false
    onTriggered: root.refresh()
  }

  function refresh() {
    // Not open yet (initial FileView loads fire at construction) → skip;
    // open() re-triggers everything once the panel is actually shown.
    if (!root.opened) return
    if (!root.location) return
    if (!forecastProc.running) root.fetchForecast()
  }

  function fetchForecast() {
    if (!root.location) return
    forecastProc.command = [root.scriptPath, "weather", root.location, "--max-age", "0"]
    forecastProc.running = true
  }

  function onForecastFailure() {
    root.fetchAttempts += 1
    // Preview stays on the no-data glyphs; a few retries cover transient
    // blips, then the panel shows what it has (reopening resets the count).
    if (root.fetchAttempts < root.maxFetchAttempts) fetchRetryTimer.start()
  }

  // ---- setup (new-install QoL): copy the location command from the
  // "no location set" section (mirrors bom-weather's copySetupCommand). ----
  function copySetupCommand() {
    Quickshell.execDetached(["wl-copy", Model.SETUP_COMMAND])
    Quickshell.execDetached(["omarchy-notification-send", "--app-name", "weatheride-au", "-g", "\u{F012F}",
      "Command copied", "Paste it in a terminal with your suburb — the bar fetches automatically"])
  }

  // ---- Save (save-on-close): close() calls this when dirty. jq builds the
  // JSON (validated numbers only — nothing user-shaped ever passes through
  // the shell), tee writes the mktemp file in the target directory, mv is
  // an atomic same-filesystem rename. The bar's debounced watch sees the
  // rename as exactly one change. ----
  function saveConfig() {
    var cfg = root.previewConfig   // already validated by Model.parseConfig
    var t = Math.round(Number(cfg.rainProbabilityThreshold))
    var ra = Math.round(Number(cfg.rainAmountThreshold) * 10) / 10
    var ws = Math.round(Number(cfg.windowStartHour))
    var we = Math.round(Number(cfg.windowEndHour))
    var dc = Math.round(Number(cfg.dayCount))
    Quickshell.execDetached(["sh", "-c",
      "mkdir -p '" + root.configDir + "' && " +
      "tmp=$(mktemp '" + root.configDir + "/.weatheride-au.json.XXXXXX') && " +
      "jq -n --argjson t " + t + " --argjson ra " + ra + " --argjson ws " + ws + " --argjson we " + we + " --argjson dc " + dc +
      " '{rainProbabilityThreshold:$t, rainAmountThreshold:$ra, windowStartHour:$ws, windowEndHour:$we, dayCount:$dc}' " +
      "| tee \"$tmp\" >/dev/null && mv -f \"$tmp\" '" + root.configPath + "'"])
  }

  function fmtHour(h) {
    var s = String(h)
    return s.length < 2 ? "0" + s : s
  }

  // ---- window ----
  // No centerOnBar (deliberately, unlike the omarchy.weather panel this was
  // copied from): the default KeyboardPanel placement centres the card under
  // the anchorItem (the bar widget) with a screen-edge clamp — the same
  // popout-under-the-widget behaviour as home-lab-mon's PopupCard. The
  // omarchy.weather-style centre-of-bar placement looked wrong when the
  // widget sits at a bar edge.
  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // ---------- Title row ----------
        Row {
          width: parent.width
          spacing: Style.space(8)

          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: "weatheride-au"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.title
            font.bold: true
          }
          Text {
            anchors.verticalCenter: parent.verticalCenter
            text: root.location !== "" ? root.location : "no location set"
            color: root.bar.foreground
            opacity: 0.5
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator {}

        // ---- Setup: no location configured yet (new-install QoL, mirrors
        // bom-weather's "Location needed" section). The forecast preview is
        // meaningless without a location, so it is hidden (its visible:false
        // gates below) while this section is shown instead.
        Column {
          visible: root.location === ""
          width: parent.width
          spacing: Style.space(8)

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "No location set. Run this command, substituting in your town or city name:"
            color: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.body
          }

          Rectangle {
            width: parent.width
            height: setupCommand.implicitHeight + Style.space(16)
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.bar.foreground, Color.accent)

            Text {
              id: setupCommand
              textFormat: Text.PlainText
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.margins: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
              text: Model.SETUP_COMMAND
              wrapMode: Text.WrapAnywhere
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Button {
            text: "Copy command"
            iconText: "\u{F012F}"   // nf-md-content_copy
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            bordered: true
            onClicked: root.copySetupCommand()
          }

          Text {
            textFormat: Text.PlainText
            width: parent.width
            wrapMode: Text.WordWrap
            text: "Ambiguous name? Add the state (\"Brighton VIC\") or use the postcode. The bar and this panel pick the new location up automatically."
            color: root.bar.foreground
            opacity: 0.5
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---------- Live preview (same glyphs as the bar dots) ----------
        PanelSectionHeader {
          visible: root.location !== ""
          text: "FORECAST"
        }

        Row {
          visible: root.location !== ""
          spacing: Style.space(14)

          Repeater {
            model: root.previewStates.length
            Column {
              required property int index
              spacing: Style.space(2)

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.previewGlyph(index)
                color: root.bar.foreground
                opacity: root.previewDim(index) ? 0.35 : 1.0
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.heading
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.previewStates[index].hasData
                     ? Model.weekday3(root.previewStates[index].date)
                     : "–"
                color: root.bar.foreground
                opacity: 0.5
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }
        }

        // Raw per-day data, one line per day (same string as the bar
        // tooltip; vertical). The panel grows with this: contentHeight fits
        // the column's implicit height.
        Text {
          width: parent.width
          horizontalAlignment: Text.AlignLeft
          visible: root.previewStates[0].hasData && root.location !== ""
          text: Model.formatTooltip(root.previewStates)
          color: root.bar.foreground
          opacity: 0.5
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
        }

        PanelSeparator {}

        // ---------- Days shown (1–7, default 5) ----------
        PanelSectionHeader { text: "DAYS SHOWN" }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Row {
            width: parent.width
            Text {
              id: dayCountLabel
              width: parent.width - dayCountValue.implicitWidth
              anchors.verticalCenter: parent.verticalCenter
              text: "Show the next"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              id: dayCountValue
              anchors.verticalCenter: parent.verticalCenter
              text: root.dayCount + (root.dayCount === 1 ? " day" : " days")
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }
          PanelSlider {
            id: dayCountSlider
            bar: root.bar
            width: parent.width
            minimum: 1
            maximum: 7
            step: 1
            integer: true
            value: root.dayCount
            onMoved: function(v) { root.dayCount = v; root.dirty = true }
          }
        }

        PanelSeparator {}

        // ---------- Rain rules ----------
        PanelSectionHeader { text: "RAIN RULES" }

        Column {
          width: parent.width
          spacing: Style.space(6)

          Row {
            width: parent.width
            Text {
              id: thresholdLabel
              width: parent.width - thresholdValue.implicitWidth
              anchors.verticalCenter: parent.verticalCenter
              text: "Rain day if chance of rain ≥"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              id: thresholdValue
              anchors.verticalCenter: parent.verticalCenter
              text: root.threshold + " %"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }
          PanelSlider {
            id: thresholdSlider
            bar: root.bar
            width: parent.width
            minimum: 0
            maximum: 100
            step: 1
            integer: true
            value: root.threshold
            onMoved: function(v) { root.threshold = v; root.dirty = true }
          }

          // Rain amount (AND rule): a day is rain only if the chance rule
          // above AND day total rainfall (amount.max) >= this. 0.0 = the
          // chance rule alone decides.
          Row {
            width: parent.width
            Text {
              id: rainAmountLabel
              width: parent.width - rainAmountValue.implicitWidth
              anchors.verticalCenter: parent.verticalCenter
              text: "Rain day if total rain ≥"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              id: rainAmountValue
              anchors.verticalCenter: parent.verticalCenter
              text: root.rainAmount.toFixed(1) + " mm"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }
          // 0.1 mm snapping: PanelSlider's `integer` flag only rounds to
          // whole numbers, so the caller rounds (PanelSlider.qml: "snapping
          // is the caller's job"); step: 0.1 drives the wheel notches.
          PanelSlider {
            id: rainAmountSlider
            bar: root.bar
            width: parent.width
            minimum: 0
            maximum: 50
            step: 0.1
            value: root.rainAmount
            onMoved: function(v) {
              root.rainAmount = Math.round(v * 10) / 10
              root.dirty = true
            }
          }

          // Commute window (two-tier, decided 2026-09-06): the window applies
          // to a day only where BOM's hourly data fully covers it (max chance
          // within the window); elsewhere the whole-day chance is used. Amount
          // stays whole-day. The RangeSlider's two knobs can't cross, so
          // start < end is guaranteed — no clamp logic needed.
          Row {
            width: parent.width
            Text {
              id: windowLabel
              width: parent.width - windowValue.implicitWidth
              anchors.verticalCenter: parent.verticalCenter
              text: "Rain day if rain between"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }
            Text {
              id: windowValue
              anchors.verticalCenter: parent.verticalCenter
              text: root.fmtHour(root.windowStart) + ":00 – " + root.fmtHour(root.windowEnd) + ":00"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }
          }
          RangeSlider {
            id: windowSlider
            bar: root.bar
            width: parent.width
            minimum: 0
            maximum: 23
            step: 1
            integer: true
            startValue: root.windowStart
            endValue: root.windowEnd
            onStartMoved: function(v) { root.windowStart = v; root.dirty = true }
            onEndMoved: function(v) { root.windowEnd = v; root.dirty = true }
          }

        }

      }
    }
  }

  // ---- fetch process (via the forked bridge) ----
  Process {
    id: forecastProc
    onExited: function(exitCode) {
      if (exitCode !== 0) root.onForecastFailure()
    }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (!raw) { root.onForecastFailure(); return }
        var states = Model.computeDayStates(raw, root.previewConfig)
        if (states) {
          root.lastRaw = raw
          root.fetchAttempts = 0
        } else {
          root.onForecastFailure()   // unparseable / too few days
        }
      }
    }
  }
}
