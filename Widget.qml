import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon whose only job is to host Settings for the hold-a-modifier overlay.
Panel {
  id: root
  moduleName: "io.github.mikus2604.hotkey-hints"
  ipcTarget: "io.github.mikus2604.hotkey-hints.settings"
  manageIpc: true

  property var hostWidget: null
  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function localPath(url) {
    var value = String(url || "")
    if (value.indexOf("file://") === 0) value = value.substring(7)
    try { return decodeURIComponent(value) } catch (error) { return value }
  }
  readonly property string sourceDir: {
    var p = localPath(Qt.resolvedUrl("."))
    if (p.length > 0 && p.charAt(p.length - 1) === "/") p = p.substring(0, p.length - 1)
    return p
  }
  readonly property string helperPy: sourceDir + "/scripts/state-file.py"

  function clampInt(v, lo, hi, fallback) {
    var n = parseInt(v, 10)
    if (isNaN(n)) return fallback
    return Math.max(lo, Math.min(hi, n))
  }

  property string fFamily: String(setting("fontFamily", "")).slice(0, 64)
  property int fSize: clampInt(setting("fontSize", 13), 9, 28, 13)
  property int padValue: clampInt(setting("padding", 10), 4, 48, 10)
  property string positionValue: String(setting("position", "center"))
  property real opacityValue: Math.max(0.3, Math.min(1, parseFloat(setting("opacity", 0.97)) || 0.97))
  property int maxDirectValue: clampInt(setting("maxDirect", 6), 2, 24, 6)
  property int revealDelayValue: clampInt(setting("revealDelayMs", 280), 120, 600, 280)
  property bool rememberUsageValue: setting("rememberUsage", false) === true || setting("rememberUsage", false) === "true"

  function refreshFields() {
    familyField.text = root.fFamily
    sizeField.value = root.fSize
    padField.value = root.padValue
    positionDropdown.value = root.positionValue
    opacitySlider.value = root.opacityValue
    maxDirectField.value = root.maxDirectValue
    revealDelayField.value = root.revealDelayValue
    rememberUsageToggle.checked = root.rememberUsageValue
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  function save() {
    var next = {
      fontFamily: familyField.text.trim().slice(0, 64),
      fontSize: String(Math.max(9, Math.min(28, sizeField.value))),
      padding: String(Math.max(4, Math.min(48, padField.value))),
      position: positionDropdown.value,
      opacity: String(Math.max(0.3, Math.min(1, opacitySlider.value))),
      maxDirect: String(Math.max(2, Math.min(24, maxDirectField.value))),
      revealDelayMs: String(Math.max(120, Math.min(600, revealDelayField.value))),
      rememberUsage: String(rememberUsageToggle.checked)
    }
    root.fFamily = next.fontFamily
    root.fSize = parseInt(next.fontSize, 10)
    root.padValue = parseInt(next.padding, 10)
    root.positionValue = next.position
    root.opacityValue = parseFloat(next.opacity)
    root.maxDirectValue = parseInt(next.maxDirect, 10)
    root.revealDelayValue = parseInt(next.revealDelayMs, 10)
    root.rememberUsageValue = rememberUsageToggle.checked
    root.persistSettings(next)
  }

  function resetUsage() {
    resetUsageProc.running = false
    resetUsageProc.command = ["/usr/bin/python3", "-I", "-S", root.helperPy, "write", "usage"]
    resetUsageProc.running = true
  }

  Process {
    id: resetUsageProc
    stdinEnabled: true
    onStarted: resetUsageProc.write("{}\n")
  }

  function preview() {
    previewOpenProc.command = ["/usr/bin/omarchy-shell", "-q", root.moduleName, "press", "SUPER"]
    previewOpenProc.running = true
    previewCloseTimer.restart()
  }

  Process { id: previewOpenProc }
  Process { id: previewCloseProc }
  Timer {
    id: previewCloseTimer
    interval: 2200
    onTriggered: {
      previewCloseProc.command = ["/usr/bin/omarchy-shell", "-q", root.moduleName, "dismiss"]
      previewCloseProc.running = true
    }
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) Qt.callLater(refreshFields)
  Component.onCompleted: refreshFields()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: ""
    tooltipText: "Hotkey Hints settings"
    onPressed: function(buttonCode) { root.toggle() }
  }

  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: popup.fittedContentWidth(Style.space(340))
    contentHeight: popup.fittedContentHeight(settingsColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()

      Column {
        id: settingsColumn
        anchors.fill: parent
        anchors.margins: Style.spacing.popupPadding
        spacing: Style.spacing.lg

        PanelSectionHeader {
          text: "HOTKEY HINTS"
          fontFamily: root.fontFamily
        }

        Text {
          textFormat: Text.PlainText
          width: parent.width
          wrapMode: Text.WordWrap
          text: "Hold Super, Ctrl, Alt, or Shift to see the hotkeys that branch off it, then add more modifiers to drill in. Release the last modifier to close — the card never takes keyboard focus, so Escape is not a close path."
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: Qt.darker(root.foreground, 1.4)
        }

        PanelSeparator {}

        TextField {
          id: familyField
          width: parent.width
          text: root.fFamily
          maximumLength: 64
          placeholderText: "Theme font (leave empty)"
          font.family: root.fontFamily
        }

        NumberField {
          id: sizeField
          label: "Font size"
          value: root.fSize
          from: 9
          to: 28
          stepSize: 1
          fontFamily: root.fontFamily
        }

        NumberField {
          id: padField
          label: "Overlay padding"
          value: root.padValue
          from: 4
          to: 48
          stepSize: 2
          fontFamily: root.fontFamily
        }

        NumberField {
          id: revealDelayField
          label: "Reveal delay (ms)"
          value: root.revealDelayValue
          from: 120
          to: 600
          stepSize: 20
          fontFamily: root.fontFamily
        }

        Dropdown {
          id: positionDropdown
          label: "Position"
          value: root.positionValue
          options: ["top", "center", "bottom"]
          fontFamily: root.fontFamily
        }

        NumberField {
          id: maxDirectField
          label: "Direct combos shown per level"
          value: root.maxDirectValue
          from: 2
          to: 24
          stepSize: 1
          fontFamily: root.fontFamily
        }

        Column {
          width: parent.width
          spacing: Style.spacing.xs
          Text {
            textFormat: Text.PlainText
            text: "Opacity: " + opacitySlider.value.toFixed(2)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
          }
          PanelSlider {
            id: opacitySlider
            width: parent.width
            bar: root.bar
            value: root.opacityValue
            minimum: 0.3
            maximum: 1.0
            step: 0.01
          }
        }

        PanelSeparator {}

        Toggle {
          id: rememberUsageToggle
          width: parent.width
          label: "Remember most-used"
          description: "Sort chips by how often you press each bound combo. Off by default. When on, the watcher inspects non-modifier keydowns only while a modifier is held, and only writes a count after matching a known binding."
          foreground: root.foreground
          accent: Color.accent
          fontFamily: root.fontFamily
          checked: root.rememberUsageValue
          onClicked: rememberUsageToggle.checked = !rememberUsageToggle.checked
        }

        Flow {
          width: parent.width
          spacing: Style.spacing.controlGap
          Button {
            text: "Preview (Super)"
            fontFamily: root.fontFamily
            onClicked: root.preview()
          }
          Button {
            text: "Reset usage stats"
            fontFamily: root.fontFamily
            onClicked: root.resetUsage()
          }
          Button {
            text: "Save"
            fontFamily: root.fontFamily
            accent: Color.accent
            bordered: true
            onClicked: root.save()
          }
        }
      }
    }
  }
}
