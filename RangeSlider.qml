import QtQuick
import qs.Commons
import qs.Ui

// RangeSlider — a dual-thumb slider for selecting an inclusive range (e.g.
// a start/end hour window). Custom component (Option B, decided 2026-09-06):
// Omarchy ships only the single-thumb PanelSlider, so this self-contained
// component lives in the plugin dir. It mirrors PanelSlider's visual language
// (track, fill, BorderSurface knobs, bar-driven colors, wheel support) but
// exposes two values whose knobs physically cannot cross — start < end is
// guaranteed by construction, so callers need no clamp logic.
//
// API (mirrors PanelSlider where sensible):
//   RangeSlider {
//     bar: root.bar
//     minimum: 0
//     maximum: 23
//     step: 1
//     integer: true
//     startValue: root.windowStart
//     endValue: root.windowEnd
//     onStartMoved(v)   // emitted while the start knob is dragged
//     onEndMoved(v)     // emitted while the end knob is dragged
//   }
// Clicking the track snaps the nearest knob to the click point. Dragging a
// knob clamps it against the other (start <= end-step, end >= start+step).
// The wheel nudges the knob nearest the cursor.
Item {
  id: root

  property QtObject bar: null
  property real startValue: 0
  property real endValue: 1
  property real minimum: 0
  property real maximum: 23
  property real step: 1
  property bool integer: false
  property color trackColor: bar ? Style.selectedFillFor(bar.foreground, Color.accent) : "#333"
  property color fillColor: bar ? bar.foreground : Color.foreground
  property color knobColor: bar ? bar.foreground : Color.foreground
  property int tickCount: 0
  property color tickColor: bar ? bar.background : Color.background
  property real trackHeight: Math.max(4, Math.round(Style.spacing.controlHeight * 0.11))
  property real knobSize: Math.max(14, Math.round(Style.spacing.controlHeight * 0.38))

  signal startMoved(real value)
  signal endMoved(real value)
  signal startReleased(real value)
  signal endReleased(real value)

  implicitWidth: Style.space(200)
  implicitHeight: Math.max(Style.space(22), knobSize + Style.spacing.md)

  readonly property real range: Math.max(0.0001, maximum - minimum)
  // Which knob is being dragged: -1 = start, 1 = end, 0 = none.
  property int dragWhich: 0
  // Live knob positions while dragging (avoid the jump back to value).
  property real startLive: startValue
  property real endLive: endValue

  function progressOf(v) { return Math.max(0, Math.min(1, (v - root.minimum) / root.range)) }

  onStartValueChanged: if (dragWhich !== -1) startLive = startValue
  onEndValueChanged: if (dragWhich !== 1) endLive = endValue

  function valueFromX(x) {
    var clamped = Math.max(0, Math.min(track.width, x))
    var raw = root.minimum + (clamped / track.width) * root.range
    if (root.integer) raw = Math.round(raw)
    return Math.max(root.minimum, Math.min(root.maximum, raw))
  }

  // The knob center x for a value.
  function knobX(v) { return track.width * root.progressOf(v) }

  function nearestKnob(x) {
    var sx = knobX(startLive)
    var ex = knobX(endLive)
    return (Math.abs(x - sx) <= Math.abs(x - ex)) ? -1 : 1
  }

  function setFromDrag(which, x) {
    var v = valueFromX(x)
    if (which === -1) {
      var ns = Math.min(v, root.endLive - root.step)
      ns = Math.max(root.minimum, Math.min(root.maximum, ns))
      root.startLive = ns
      root.startMoved(ns)
    } else {
      var ne = Math.max(v, root.startLive + root.step)
      ne = Math.max(root.minimum, Math.min(root.maximum, ne))
      root.endLive = ne
      root.endMoved(ne)
    }
  }

  Rectangle {
    id: track
    anchors.verticalCenter: parent.verticalCenter
    anchors.left: parent.left
    anchors.right: parent.right
    height: root.trackHeight
    radius: height / 2
    color: root.trackColor
  }

  // Fill between the two knobs (the selected range).
  Rectangle {
    id: fill
    anchors.verticalCenter: track.verticalCenter
    height: track.height
    radius: track.radius
    color: root.fillColor
    x: track.x + track.width * root.progressOf(root.startLive)
    width: track.width * (root.progressOf(root.endLive) - root.progressOf(root.startLive))
  }

  Repeater {
    model: root.tickCount > 1 ? root.tickCount : 0
    Rectangle {
      required property int index
      width: Math.max(1, Style.space(2))
      height: root.trackHeight + Style.space(4)
      radius: 1
      color: root.tickColor
      anchors.verticalCenter: track.verticalCenter
      x: Math.max(0, Math.min(track.width - width,
                              track.width * (index / (root.tickCount - 1)) - width / 2))
    }
  }

  // Start knob.
  BorderSurface {
    id: startKnob
    width: root.knobSize
    height: root.knobSize
    radius: root.knobSize / 2
    color: root.knobColor
    borderSpec: Border.flat(root.bar ? root.bar.background : "#101315", Math.max(1, Style.space(2)))
    anchors.verticalCenter: track.verticalCenter
    x: Math.max(0, Math.min(track.width - width, track.width * root.progressOf(root.startLive) - width / 2))
    scale: (root.dragWhich === -1 || mouseArea.containsMouse) ? 1.15 : 1.0

    Behavior on x {
      enabled: root.dragWhich !== -1
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }
    Behavior on scale {
      NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
    }
  }

  // End knob.
  BorderSurface {
    id: endKnob
    width: root.knobSize
    height: root.knobSize
    radius: root.knobSize / 2
    color: root.knobColor
    borderSpec: Border.flat(root.bar ? root.bar.background : "#101315", Math.max(1, Style.space(2)))
    anchors.verticalCenter: track.verticalCenter
    x: Math.max(0, Math.min(track.width - width, track.width * root.progressOf(root.endLive) - width / 2))
    scale: root.dragWhich === 1 ? 1.15 : 1.0

    Behavior on x {
      enabled: root.dragWhich !== 1
      NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
    }
    Behavior on scale {
      NumberAnimation { duration: 110; easing.type: Easing.OutCubic }
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor
    acceptedButtons: Qt.LeftButton

    onPressed: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      root.dragWhich = root.nearestKnob(mouse.x)
      root.setFromDrag(root.dragWhich, mouse.x)
    }
    onPositionChanged: function(mouse) {
      if (root.dragWhich === 0) return
      root.setFromDrag(root.dragWhich, mouse.x)
    }
    onReleased: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      var which = root.dragWhich
      if (which === -1) root.startReleased(root.startLive)
      else if (which === 1) root.endReleased(root.endLive)
      // Commit the live values back to the bound properties.
      if (which === -1) root.startValue = root.startLive
      else if (which === 1) root.endValue = root.endLive
      root.dragWhich = 0
    }
    onWheel: function(wheel) {
      // Nudge the knob nearest the cursor (fallback: end knob).
      var which = root.nearestKnob(mouseArea.mouseX)
      var delta = wheel.angleDelta.y > 0 ? root.step : -root.step
      if (which === -1) {
        var ns = Math.max(root.minimum, Math.min(root.endValue - root.step, root.startValue + delta))
        root.startValue = ns
        root.startMoved(ns)
      } else {
        var ne = Math.max(root.startValue + root.step, Math.min(root.maximum, root.endValue + delta))
        root.endValue = ne
        root.endMoved(ne)
      }
    }
  }
}
