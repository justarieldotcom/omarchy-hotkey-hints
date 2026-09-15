import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Commons
import qs.Ui

// Small bar icon whose only job is to host Settings for the hold-a-modifier
// overlay (Overlay.qml, a separate always-loaded "panel"-kind surface with
// no bar icon of its own). Bar-widget schema/defaults is the only mechanism
// this Omarchy shell gives third-party plugins for live-editable, persisted
// settings, so this widget exists purely to reuse it.
Panel {
  id: root
  moduleName: "t480.hotkey-hints"
  ipcTarget: "t480.hotkey-hints.settings"
  manageIpc: true

  property var hostWidget: null
  readonly property color foreground: bar ? bar.barForeground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ------------------------------------------------------------- settings
  property string fFamily: String(setting("fontFamily", ""))
  property int fSize: Math.max(9, Math.min(28, parseInt(setting("fontSize", 13), 10) || 13))
  property int padValue: Math.max(4, Math.min(48, parseInt(setting("padding", 10), 10) || 14))
  property string positionValue: String(setting("position", "center"))
  property real opacityValue: Math.max(0.3, Math.min(1, parseFloat(setting("opacity", 0.97)) || 0.97))
  property int maxDirectValue: Math.max(2, Math.min(24, parseInt(setting("maxDirect", 6), 10) || 6))
  property bool rememberUsageValue: setting("rememberUsage", false) === true || setting("rememberUsage", false) === "true"

  function refreshFields() {
    familyField.text = root.fFamily
    sizeField.value = root.fSize
    padField.value = root.padValue
    positionDropdown.value = root.positionValue
    opacitySlider.value = root.opacityValue
    maxDirectField.value = root.maxDirectValue
    rememberUsageToggle.checked = root.rememberUsageValue
  }

  // Same pattern as the sibling t480.control-station plugin: merge edits
  // into this bar entry's inline shell.json config and push it through the
  // bar's live-update path, so Overlay.qml's FileView picks it up with no
  // shell restart.
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
      fontFamily: familyField.text.trim(),
      fontSize: String(Math.max(9, Math.min(28, sizeField.value))),
      padding: String(Math.max(4, Math.min(48, padField.value))),
      position: positionDropdown.value,
      opacity: String(Math.max(0.3, Math.min(1, opacitySlider.value))),
      maxDirect: String(Math.max(2, Math.min(24, maxDirectField.value))),
      rememberUsage: String(rememberUsageToggle.checked)
    }
    root.fFamily = next.fontFamily
    root.fSize = parseInt(next.fontSize, 10)
    root.padValue = parseInt(next.padding, 10)
    root.positionValue = next.position
    root.opacityValue = parseFloat(next.opacity)
    root.maxDirectValue = parseInt(next.maxDirect, 10)
    root.rememberUsageValue = rememberUsageToggle.checked
    root.persistSettings(next)
  }

  function resetUsage() {
    resetUsageProc.command = ["omarchy-shell", "-q", "t480.hotkey-hints", "resetUsage"]
    resetUsageProc.running = true
  }

  Process { id: resetUsageProc }

  // Briefly pops the real overlay open with SUPER's hints so a settings
  // change can be eyeballed immediately, without holding any key down.
  function preview() {
    previewOpenProc.command = ["omarchy-shell", "-q", "t480.hotkey-hints", "press", "SUPER"]
    previewOpenProc.running = true
    previewCloseTimer.restart()
  }

  Process { id: previewOpenProc }
  Process { id: previewCloseProc }
  Timer {
    id: previewCloseTimer
    interval: 2200
    onTriggered: {
      previewCloseProc.command = ["omarchy-shell", "-q", "t480.hotkey-hints", "dismiss"]
      previewCloseProc.running = true
    }
  }

  // manageIpc: true (above) already gives this widget open/close/toggle/
  // show/hide over IPC via the base Panel component's own IpcHandler — no
  // need to declare another one here.

  // ============================================================= bar + popup
  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) Qt.callLater(refreshFields)
  Component.onCompleted: refreshFields()

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "" // nf-fa-keyboard
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
    // Sized from the actual settings column height rather than a guessed
    // constant, so it always fits every field without clipping regardless
    // of theme font/spacing scale. fittedContentHeight() already adds the
    // popup's own vertical padding/border inset — don't add it again here
    // (matches every other KeyboardPanel popup in the codebase).
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
          text: "Hold a modifier (Super, Ctrl, Alt, Shift) to see the hotkeys that branch off it, then add more modifiers to drill in. Press Esc or release to close."
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          color: Qt.darker(root.foreground, 1.4)
        }

        PanelSeparator {}

        TextField {
          id: familyField
          width: parent.width
          text: root.fFamily
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
          description: "Sort each level's chips by how often you actually press them, most-used first. Only real, bound combos you press are ever counted — never ordinary typing."
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