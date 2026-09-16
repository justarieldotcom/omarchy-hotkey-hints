import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Always-loaded hold-a-modifier overlay (panel kind). Never reads the keyboard;
// it only reacts to IPC press/release/dismiss/state/ping from the root-owned
// watcher installed to /usr/local/libexec/omarchy-hotkey-hints/.
Item {
  id: root

  readonly property string pluginId: "io.github.mikus2604.hotkey-hints"
  readonly property var leadingMods: ["SUPER", "ALT", "CTRL", "SHIFT"]
  readonly property int maxHelperBytes: 262144
  readonly property int helperDeadlineMs: 20000

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
  readonly property string homeDir: {
    var h = String(Quickshell.env("HOME") || "")
    if (h.charAt(0) !== "/" || h.indexOf("\0") >= 0) return ""
    return h
  }
  readonly property string helperPy: sourceDir + "/scripts/state-file.py"
  readonly property string helperKb: sourceDir + "/scripts/print-keybindings.sh"

  property var held: []
  property bool opened: false
  property var hintGroups: ({ SUPER: [], ALT: [], CTRL: [], SHIFT: [] })
  property var stepView: ({ direct: [], overflow: 0, branches: [] })

  readonly property int stuckCloseMs: 8000

  property var rawSettings: ({})
  readonly property string fontFamily: {
    var s = rawSettings.fontFamily ? String(rawSettings.fontFamily) : ""
    s = s.replace(/[<>&\x00-\x1f\x7f]/g, "").slice(0, 64)
    return s || Style.font.family
  }
  readonly property int fontSize: {
    var v = parseInt(rawSettings.fontSize, 10)
    return (v >= 9 && v <= 28) ? v : Style.font.body
  }
  readonly property int pad: {
    var v = parseInt(rawSettings.padding, 10)
    return (v >= 4 && v <= 48) ? v : Style.space(10)
  }
  readonly property string position: {
    var p = String(rawSettings.position || "center")
    return (p === "top" || p === "center" || p === "bottom") ? p : "center"
  }
  readonly property real overlayOpacity: {
    var v = parseFloat(rawSettings.opacity)
    return (v >= 0.3 && v <= 1) ? v : 0.97
  }
  readonly property int maxDirect: {
    var v = parseInt(rawSettings.maxDirect, 10)
    return (v >= 2 && v <= 24) ? v : 6
  }
  readonly property int revealDelayMs: {
    var v = parseInt(rawSettings.revealDelayMs, 10)
    return (v >= 120 && v <= 600) ? v : 280
  }
  readonly property bool rememberUsage: rawSettings.rememberUsage === true || rawSettings.rememberUsage === "true"

  property var usageCounts: ({})

  readonly property int baseW: 800
  property int cardW: baseW
  property int extraH: 0
  property int posX: -1
  property int posY: -1
  readonly property int minW: 360
  readonly property int maxExtraH: 700
  property bool userMoved: false
  property var moveGrab: ({})
  property var resizeGrab: ({})

  readonly property int font: {
    var scaled = Math.round(root.fontSize * root.cardW / root.baseW)
    return Math.max(9, Math.min(26, scaled))
  }

  readonly property int cardH: Math.max(36, contentCol.implicitHeight
    + card.borderTop + card.borderBottom + 2 * root.pad + root.extraH)

  function screenW() { return panel.screen ? panel.screen.width : 0 }
  function screenH() { return panel.screen ? panel.screen.height : 0 }

  function clampPos() {
    var sw = root.screenW(), sh = root.screenH()
    if (!sw || !sh) return
    root.posX = Math.max(0, Math.min(root.posX, sw - root.cardW))
    root.posY = Math.max(0, Math.min(root.posY, sh - root.cardH))
  }

  function seedPosition() {
    var sw = root.screenW() || 1600
    var sh = root.screenH() || 900
    root.cardW = Math.max(root.minW, Math.min(root.cardW, sw - 24))
    root.posX = Math.round((sw - root.cardW) / 2)
    var y = root.position === "top" ? 48
      : root.position === "bottom" ? (sh - root.cardH - 48)
      : Math.round((sh - root.cardH) / 2)
    root.posY = Math.max(8, y)
    root.clampPos()
  }

  function grabMove(mx, my) {
    root.moveGrab = { x: mx, y: my, px: root.posX, py: root.posY }
  }

  function dragMove(mx, my) {
    if (root.moveGrab.x === undefined) return
    var sw = root.screenW(), sh = root.screenH()
    if (sw && sh) {
      var nx = root.moveGrab.px + mx - root.moveGrab.x
      var ny = root.moveGrab.py + my - root.moveGrab.y
      root.posX = Math.max(0, Math.min(nx, sw - root.cardW))
      root.posY = Math.max(0, Math.min(ny, sh - root.cardH))
      root.userMoved = true
    }
  }

  function grabResize(mx, my) {
    root.resizeGrab = { x: mx, y: my, w: root.cardW, h: root.extraH }
  }

  function dragResize(mx, my) {
    if (root.resizeGrab.x === undefined) return
    var sw = root.screenW()
    var nw = root.resizeGrab.w + mx - root.resizeGrab.x
    root.cardW = Math.max(root.minW, Math.min(nw, (sw ? sw - 24 : 1100)))
    root.extraH = Math.max(0, Math.min(root.resizeGrab.h + my - root.resizeGrab.y, root.maxExtraH))
    root.clampPos()
  }

  function press(mod) {
    mod = String(mod || "").toUpperCase()
    if (root.leadingMods.indexOf(mod) < 0) return
    if (root.held.indexOf(mod) >= 0) {
      if (root.opened) stuckGuard.restart()
      return
    }
    root.held = root.held.concat([mod])
    if (root.opened) {
      stuckGuard.restart()
      return
    }
    revealTimer.restart()
  }

  function release(mod) {
    mod = String(mod || "").toUpperCase()
    var idx = root.held.indexOf(mod)
    if (idx < 0) return
    root.held = root.held.slice(0, idx).concat(root.held.slice(idx + 1))
    if (root.held.length === 0) root.dismiss()
    else stuckGuard.restart()
  }

  function dismiss() {
    revealTimer.stop()
    stuckGuard.stop()
    root.held = []
    root.opened = false
  }

  function recomputeSteps() {
    root.stepView = Model.stepsForHeld(root.hintGroups, root.held, root.maxDirect,
      root.rememberUsage ? root.usageCounts : ({}))
  }

  onHeldChanged: recomputeSteps()
  onMaxDirectChanged: recomputeSteps()
  onRememberUsageChanged: {
    recomputeSteps()
    root.writeWatch()
  }
  onUsageCountsChanged: recomputeSteps()

  Timer {
    id: revealTimer
    interval: root.revealDelayMs
    onTriggered: {
      if (root.held.length === 0) return
      root.opened = true
      recenterTimer.restart()
      stuckGuard.restart()
    }
  }

  Timer {
    id: recenterTimer
    interval: 16
    onTriggered: {
      root.clampPos()
      if (!root.userMoved) root.seedPosition()
    }
  }

  Timer {
    id: stuckGuard
    interval: root.stuckCloseMs
    onTriggered: { root.dismiss() }
  }

  function stopProc(proc, killer) {
    if (proc.running) {
      proc.signal(15)
      killer.restart()
    }
  }

  function fetchKeybindings() {
    stopProc(keybindsProc, keybindsKill)
    keybindsProc.buf = ""
    keybindsProc.command = ["/usr/bin/bash", root.helperKb]
    keybindsProc.running = true
    keybindsDeadline.restart()
  }

  function readShell() {
    stopProc(shellReadProc, shellReadKill)
    shellReadProc.buf = ""
    shellReadProc.command = ["/usr/bin/python3", "-I", "-S", root.helperPy, "read", "shell"]
    shellReadProc.running = true
    shellReadDeadline.restart()
  }

  function readUsage() {
    stopProc(usageReadProc, usageReadKill)
    usageReadProc.buf = ""
    usageReadProc.command = ["/usr/bin/python3", "-I", "-S", root.helperPy, "read", "usage"]
    usageReadProc.running = true
    usageReadDeadline.restart()
  }

  function writeState(kind, payload) {
    stopProc(writeProc, writeKill)
    writeProc.kind = kind
    writeProc.payload = payload
    writeProc.command = ["/usr/bin/python3", "-I", "-S", root.helperPy, "write", kind]
    writeProc.running = true
    writeDeadline.restart()
  }

  function writeKnownBindings() {
    root.writeState("bindings", JSON.stringify(Model.flattenBindingIdentities(root.hintGroups)))
  }

  function writeWatch() {
    root.writeState("watch", JSON.stringify({ rememberUsage: root.rememberUsage }))
  }

  function applyShellConfig(text) {
    try {
      var cfg = JSON.parse(text || "{}")
      root.rawSettings = Model.pickBarEntrySettings(cfg, root.pluginId)
    } catch (e) {
      root.rawSettings = {}
    }
  }

  function takeChunk(proc, chunk, killer) {
    proc.buf += chunk
    if (proc.buf.length > root.maxHelperBytes) {
      proc.signal(15)
      killer.restart()
      proc.buf = ""
    }
  }

  Process {
    id: keybindsProc
    property string buf: ""
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.takeChunk(keybindsProc, chunk, keybindsKill) }
    }
    onExited: function(code, status) {
      keybindsDeadline.stop()
      if (code === 0 && keybindsProc.buf)
        root.hintGroups = Model.groupKeybindings(keybindsProc.buf)
      root.writeKnownBindings()
      root.recomputeSteps()
      keybindsProc.buf = ""
    }
  }
  Timer { id: keybindsDeadline; interval: root.helperDeadlineMs; onTriggered: { keybindsProc.signal(15); keybindsKill.restart() } }
  Timer { id: keybindsKill; interval: 2000; onTriggered: keybindsProc.signal(9) }

  Process {
    id: shellReadProc
    property string buf: ""
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.takeChunk(shellReadProc, chunk, shellReadKill) }
    }
    onExited: function(code, status) {
      shellReadDeadline.stop()
      if (code === 0) root.applyShellConfig(shellReadProc.buf)
      shellReadProc.buf = ""
    }
  }
  Timer { id: shellReadDeadline; interval: root.helperDeadlineMs; onTriggered: { shellReadProc.signal(15); shellReadKill.restart() } }
  Timer { id: shellReadKill; interval: 2000; onTriggered: shellReadProc.signal(9) }

  Process {
    id: usageReadProc
    property string buf: ""
    stdout: SplitParser {
      splitMarker: ""
      onRead: function(chunk) { root.takeChunk(usageReadProc, chunk, usageReadKill) }
    }
    onExited: function(code, status) {
      usageReadDeadline.stop()
      if (code === 0) root.usageCounts = Model.parseUsageCounts(usageReadProc.buf)
      usageReadProc.buf = ""
    }
  }
  Timer { id: usageReadDeadline; interval: root.helperDeadlineMs; onTriggered: { usageReadProc.signal(15); usageReadKill.restart() } }
  Timer { id: usageReadKill; interval: 2000; onTriggered: usageReadProc.signal(9) }

  Process {
    id: writeProc
    property string payload: ""
    property string kind: ""
    stdinEnabled: true
    onStarted: writeProc.write(writeProc.payload)
    onExited: function(code, status) { writeDeadline.stop() }
  }
  Timer { id: writeDeadline; interval: root.helperDeadlineMs; onTriggered: { writeProc.signal(15); writeKill.restart() } }
  Timer { id: writeKill; interval: 2000; onTriggered: writeProc.signal(9) }

  FileView {
    id: shellWatch
    path: root.homeDir !== "" ? root.homeDir + "/.config/omarchy/shell.json" : ""
    preload: false
    watchChanges: true
    blockAllReads: true
    printErrors: false
    onFileChanged: root.readShell()
  }

  FileView {
    id: usageWatch
    path: root.homeDir !== "" ? root.homeDir + "/.local/state/omarchy/hotkey-hints/usage.json" : ""
    preload: false
    watchChanges: true
    blockAllReads: true
    printErrors: false
    onFileChanged: root.readUsage()
  }

  IpcHandler {
    target: root.pluginId
    function press(mod: string): string { root.press(mod); return "ok" }
    function release(mod: string): string { root.release(mod); return "ok" }
    function dismiss(): string { root.dismiss(); return "ok" }
    function state(): string { return root.opened ? "open" : "closed" }
    function ping(): string { return "ok" }
  }

  Component.onCompleted: {
    fetchKeybindings()
    readShell()
    readUsage()
    writeWatch()
  }

  Component.onDestruction: {
    keybindsProc.signal(15)
    shellReadProc.signal(15)
    usageReadProc.signal(15)
    writeProc.signal(15)
  }

  PanelWindow {
    id: panel
    visible: root.opened
    implicitWidth: root.cardW
    implicitHeight: root.cardH
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "io-github-mikus2604-hotkey-hints"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    anchors {
      top: true
      left: true
    }

    margins {
      top: root.posY
      left: root.posX
    }

    Item {
      id: cardHost
      anchors.fill: parent
      clip: true

      BorderSurface {
        id: card
        anchors.fill: parent
        color: Util.alpha(Color.background, root.overlayOpacity)
        borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
        radius: Style.cornerRadius

        Column {
          id: contentCol
          x: card.borderLeft + root.pad
          y: card.borderTop + root.pad
          width: card.width - card.borderLeft - card.borderRight - 2 * root.pad
          spacing: Math.max(2, Style.spacing.sm)

          RowLayout {
            width: parent.width
            spacing: Style.spacing.sm

            Text {
              textFormat: Text.PlainText
              text: root.held.map(Model.titleCaseToken).join(" + ")
              font.family: root.fontFamily
              font.bold: true
              font.pixelSize: root.font + Style.space(2)
              color: Color.accent
              Layout.alignment: Qt.AlignVCenter
            }
            Text {
              textFormat: Text.PlainText
              text: "next:"
              font.family: root.fontFamily
              font.pixelSize: Math.max(9, root.font - 2)
              color: Util.alpha(Color.popups.text, 0.5)
              Layout.alignment: Qt.AlignVCenter
            }
            Item { Layout.fillWidth: true }
            Text {
              textFormat: Text.PlainText
              text: "drag to move"
              font.family: root.fontFamily
              font.pixelSize: Math.max(9, root.font - 2)
              color: Util.alpha(Color.popups.text, 0.45)
              Layout.alignment: Qt.AlignVCenter
            }
          }

          Flow {
            visible: root.stepView.direct.length > 0
              || root.stepView.branches.length > 0
              || root.stepView.overflow > 0
            width: parent.width
            spacing: Math.max(3, Style.spacing.xs)

            Repeater {
              model: root.stepView.direct
              delegate: Rectangle {
                radius: Style.cornerRadius / 2
                color: Util.alpha(Color.popups.text, 0.06)
                border.width: 1
                border.color: Util.alpha(Color.popups.border, 0.4)
                implicitWidth: row.implicitWidth + Style.space(8)
                implicitHeight: row.implicitHeight + Style.space(2)
                Row {
                  id: row
                  anchors.centerIn: parent
                  spacing: Style.space(4)
                  Text {
                    textFormat: Text.PlainText
                    text: "+ " + modelData.key
                    font.family: root.fontFamily
                    font.bold: true
                    font.pixelSize: root.font
                    color: Color.popups.text
                  }
                  Text {
                    visible: modelData.description !== ""
                    textFormat: Text.PlainText
                    text: modelData.description
                    font.family: root.fontFamily
                    font.pixelSize: root.font
                    color: Util.alpha(Color.popups.text, 0.7)
                  }
                }
              }
            }

            Rectangle {
              visible: root.stepView.overflow > 0
              radius: Style.cornerRadius / 2
              color: Util.alpha(Color.popups.text, 0.035)
              border.width: 1
              border.color: Util.alpha(Color.popups.border, 0.25)
              implicitWidth: orow.implicitWidth + Style.space(8)
              implicitHeight: orow.implicitHeight + Style.space(2)
              Row {
                id: orow
                anchors.centerIn: parent
                Text {
                  textFormat: Text.PlainText
                  text: "+" + root.stepView.overflow + " more"
                  font.family: root.fontFamily
                  font.bold: true
                  font.pixelSize: root.font
                  color: Util.alpha(Color.popups.text, 0.6)
                }
              }
            }

            Repeater {
              model: root.stepView.branches
              delegate: Rectangle {
                radius: Style.cornerRadius / 2
                color: Util.alpha(Color.accent, 0.12)
                border.width: 1
                border.color: Util.alpha(Color.accent, 0.5)
                implicitWidth: brow.implicitWidth + Style.space(8)
                implicitHeight: brow.implicitHeight + Style.space(2)
                Row {
                  id: brow
                  anchors.centerIn: parent
                  spacing: Style.space(4)
                  Text {
                    textFormat: Text.PlainText
                    text: "+ " + modelData.mod
                    font.family: root.fontFamily
                    font.bold: true
                    font.pixelSize: root.font
                    color: Color.accent
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: "· " + modelData.count
                    font.family: root.fontFamily
                    font.pixelSize: Math.max(9, root.font - 1)
                    color: Util.alpha(Color.accent, 0.8)
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }
            }
          }

          Repeater {
            model: root.stepView.direct.length === 0
              && root.stepView.branches.length === 0
              && root.stepView.overflow === 0
              ? 1 : 0

            delegate: Text {
              textFormat: Text.PlainText
              text: root.held.length > 0
                ? "No shortcuts under " + root.held.map(Model.titleCaseToken).join(" + ") + " yet."
                : ""
              font.family: root.fontFamily
              font.pixelSize: Math.max(9, root.font - 1)
              color: Util.alpha(Color.popups.text, 0.5)
            }
          }
        }
      }

      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.SizeAllCursor
        onPressed: function(m) {
          stuckGuard.restart()
          root.grabMove(m.x, m.y)
        }
        onPositionChanged: function(m) { root.dragMove(m.x, m.y) }
      }

      Rectangle {
        id: resizeGrip
        width: Math.max(16, Style.space(14))
        height: width
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        color: Util.alpha(Color.accent, 0.18)
        radius: Math.min(6, Style.cornerRadius / 2)

        Text {
          textFormat: Text.PlainText
          anchors.centerIn: parent
          text: "⤡"
          font.family: root.fontFamily
          font.pixelSize: Math.max(9, root.font - 2)
          color: Util.alpha(Color.accent, 0.9)
        }

        MouseArea {
          anchors.fill: parent
          cursorShape: Qt.SizeFDiagCursor
          onPressed: function(m) {
            stuckGuard.restart()
            root.grabResize(m.x, m.y)
          }
          onPositionChanged: function(m) { root.dragResize(m.x, m.y) }
        }
      }
    }
  }
}
