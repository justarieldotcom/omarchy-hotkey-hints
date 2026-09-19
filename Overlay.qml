import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Quickshell.Hyprland
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The always-loaded hold-a-modifier overlay ("panel" kind, like omarchy.osd —
// no bar icon of its own).
//
// This file owns a small evdev helper (hotkey-watcher.py, next to this file):
// it launches it as an ordinary *unprivileged* child process and reads one
// line per event off its stdout — `press SUPER`, `release CTRL`,
// `used CTRL+SUPER:V`. The helper reads the physical keys from the kernel
// because Hyprland's own modifier binds silently drop release events (see
// docs/DEVNOTES.md). Reading /dev/input needs membership in the `input` group
// and nothing else: no root, no systemd unit, no setuid. The helper is wrapped
// in `setpriv --pdeathsig TERM` so it can never outlive this shell, the same
// way the built-in clipboard plugin supervises `wl-paste --watch`.
//
// This file still never interprets the keyboard itself — it only acts on the
// helper's validated lines (and on the IPC calls below, kept for testing).
//
// Settings (font, padding, position, opacity, and the direct-combo cap) are
// edited from the small bar icon (Widget.qml) and persisted into shell.json
// like any other bar widget; this file re-reads that same file directly since
// a bare "panel" plugin gets no injected `settings` prop the way a bar-widget
// popup does.
//
// Progressive disclosure: holding the first modifier shows only the single
// keys that complete a combo (+ Space → Menu) and the modifier branches that
// go deeper (+ Ctrl · 12). Adding another held modifier drills one level in.
// The card is a free-floating Overlay-layer surface: drag it anywhere with the
// mouse, resize it from the bottom-right corner (content reflows and the type
// scales with the width), and typing is never interrupted — `keyboardFocus`
// is None, so key events keep going to whatever window has focus underneath.
// Closing: releasing the last held modifier closes it (the `release` line
// arrives within tens of milliseconds, bypassing Hyprland's broken bindr); a
// stuckGuard timer is kept as insurance in case the helper stops unexpectedly.
//
// Usage tracking (opt-in via the `rememberUsage` setting): this file writes
// the flattened set of known bindings to bindingsFile on every keybindings
// refresh; the helper matches real keypresses against that file and, only for
// a match, prints a `used <identity>` line. That match-before-report split is
// what lets the helper read regular keys (not just modifiers) without becoming
// a keylogger — anything that isn't an actual bound hotkey never leaves the
// helper process.
Item {
  id: root

  readonly property string pluginId: "justarieldotcom.hotkey-hints"
  readonly property var leadingMods: ["SUPER", "ALT", "CTRL", "SHIFT"]

  // ------------------------------------------------------------- state
  // Modifiers currently held, in press order. Reassigning the array (never
  // mutating) triggers onHeldChanged -> content recompute.
  property var held: []
  property bool opened: false
  property var hintGroups: ({ SUPER: [], ALT: [], CTRL: [], SHIFT: [] })
  property var stepView: ({ direct: [], overflow: 0, branches: [] })

  // Every leading modifier also doubles as part of ordinary typing or other
  // shortcuts (Shift for capitals, Ctrl/Alt for their own combos, Super for
  // its own SUPER+key binds) — those are pressed and released in well under
  // 100-150ms. Deferring the reveal until the key has been held this long
  // keeps the overlay from flashing on every capital letter or fast shortcut.
  readonly property int revealDelayMs: 280
  // Insurance only: normally the helper's `release` line closes the overlay.
  // This fires only if the helper is down or missed a release, so it can
  // comfortably be long.
  readonly property int stuckCloseMs: 8000

  // ------------------------------------------------------------- settings
  property var rawSettings: ({})
  readonly property string fontFamily: rawSettings.fontFamily ? String(rawSettings.fontFamily) : Style.font.family
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
  readonly property bool rememberUsage: rawSettings.rememberUsage === true || rawSettings.rememberUsage === "true"

  // ------------------------------------------------------------- state paths
  // Honour XDG_STATE_HOME the way the built-in agents plugin does
  // (Quickshell.env returns falsy when a variable is unset).
  readonly property string homeDir: Quickshell.env("HOME")
  readonly property string stateDir:
    (Quickshell.env("XDG_STATE_HOME") || root.homeDir + "/.local/state") + "/omarchy"

  // FileView does not create parent directories, and ~/.local/state/omarchy
  // does not exist on a fresh machine. Same best-effort approach the built-in
  // notifications plugin uses: fire the mkdir, then defer the first write a
  // turn. A missed race just means no usage tracking until the next refresh —
  // the helper already tolerates the allowlist being absent.
  Process {
    id: ensureStateDirProc
    command: ["mkdir", "-p", root.stateDir]
  }

  // ------------------------------------------------------------- usage tracking
  // Map of Model.usageIdentity() -> press count, persisted to usageFile.
  // Populated only by the helper's `used` lines (which it only prints for keys
  // matching a binding in bindingsFile — see hotkey-watcher.py), so this never
  // contains anything but real, bound hotkey combos.
  property var usageCounts: ({})

  function bumpUsage(identity) {
    if (!identity) return
    var next = {}
    for (var k in root.usageCounts) next[k] = root.usageCounts[k]
    next[identity] = (next[identity] || 0) + 1
    root.usageCounts = next
    usageFile.setText(JSON.stringify(root.usageCounts, null, 2) + "\n")
  }

  function resetUsage() {
    root.usageCounts = {}
    usageFile.setText("{}\n")
  }

  function writeKnownBindings() {
    bindingsFile.setText(JSON.stringify(Model.flattenBindingIdentities(root.hintGroups), null, 2) + "\n")
  }

  // ------------------------------------------------------------- watcher
  // The helper lives next to this file. Derive its path the same way the
  // shell's own PluginRegistry finds this plugin — pluginsDir + plugin id —
  // rather than converting Qt.resolvedUrl() back to a filesystem path, which
  // would mean undoing Util.fileUrl()'s per-segment percent-encoding by hand.
  readonly property string watcherScript:
    root.homeDir + "/.config/omarchy/plugins/" + root.pluginId + "/hotkey-watcher.py"

  // starting | running | no-input-access | no-keyboard | missing-evdev | failed
  property string watcherStatus: "starting"
  property int watcherRetries: 0
  // Set for the reasons a retry cannot fix (see startWatcher). Group
  // membership only takes effect on a new login session, and a missing package
  // needs installing, so retrying those on a timer just burns CPU and hides
  // the problem. Widget.qml surfaces the status and offers a manual retry.
  property bool watcherBlocked: false

  // Only these exact shapes are acted on. The helper is the one component that
  // sees raw key data, so its output is parsed strictly rather than trusted:
  // anything not matching is dropped without reaching press()/bumpUsage().
  readonly property var reReady: /^ready$/
  readonly property var reMod: /^(press|release) (SUPER|ALT|CTRL|SHIFT)$/
  readonly property var reUsed: /^used ((?:SUPER|ALT|CTRL|SHIFT)(?:\+(?:SUPER|ALT|CTRL|SHIFT))*:[A-Z0-9_ ]+)$/
  readonly property var reError: /^error (no-input-access|no-keyboard|missing-evdev)$/

  function handleWatcherLine(rawLine) {
    var line = String(rawLine || "").trim()
    if (line === "") return

    // Keyboards opened. Deliberately leaves watcherRetries alone: a helper
    // that says ready and then crashes must still back off, so only real key
    // traffic proves it healthy enough to reset the counter.
    if (root.reReady.test(line)) {
      root.watcherStatus = "running"
      return
    }

    var m = root.reMod.exec(line)
    if (m) {
      root.watcherStatus = "running"
      root.watcherRetries = 0
      if (m[1] === "press") root.press(m[2])
      else root.release(m[2])
      return
    }

    m = root.reUsed.exec(line)
    if (m) {
      root.watcherStatus = "running"
      root.watcherRetries = 0
      if (root.rememberUsage) root.bumpUsage(m[1])
      return
    }

    m = root.reError.exec(line)
    if (m) {
      root.watcherStatus = m[1]
      root.watcherBlocked = true
      watcherRestartTimer.stop()
      console.warn(root.pluginId + ": hotkey watcher cannot start: " + m[1]
        + (m[1] === "no-input-access"
          ? " (add your user to the 'input' group, then log out and back in)"
          : m[1] === "missing-evdev" ? " (install python-evdev)" : ""))
      return
    }

    // Unrecognised line: ignored on purpose, never forwarded.
  }

  function startWatcher() {
    if (root.watcherBlocked) return
    root.watcherStatus = "starting"
    watcherProc.running = false
    watcherProc.running = true
  }

  function retryWatcher() {
    root.watcherBlocked = false
    root.watcherRetries = 0
    root.startWatcher()
  }

  Process {
    id: watcherProc
    // setpriv --pdeathsig TERM: the helper dies with the shell rather than
    // being orphaned across a restart (same guard as the clipboard plugin).
    // python3 -u: line-buffered stdout, without touching the child's
    // environment. Invoked via python3 so a lost exec bit can't break it.
    command: ["setpriv", "--pdeathsig", "TERM", "python3", "-u",
              root.watcherScript, bindingsFile.path]
    stdout: SplitParser {
      onRead: function(line) { root.handleWatcherLine(line) }
    }
    // No parameters needed: the helper reports *why* it gave up on stdout
    // (handleWatcherLine sets watcherBlocked), so an exit code would add
    // nothing. Bare handler also matches the clipboard plugin's watcher.
    onExited: {
      if (root.watcherBlocked) return // already reported a permanent reason
      root.watcherStatus = "failed"
      var delay = Math.min(1000 * Math.pow(2, root.watcherRetries), 30000)
      root.watcherRetries += 1
      watcherRestartTimer.interval = delay
      watcherRestartTimer.restart()
    }
  }

  Timer {
    id: watcherRestartTimer
    repeat: false
    onTriggered: root.startWatcher()
  }

  // --------------------------------------------------------------- geometry
  // Free-floating card. `cardW`/`extraH` are the user's resize state
  // (averaged over the session); the font scales with the width so content
  // stays proportioned while resizing, the position is top-left anchor
  // margins in output pixels.
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

  // The output Hyprland currently has focused, resolved by name against
  // Quickshell.screens — the same indirection the built-in bar uses
  // (focusedScreenName() in plugins/bar/Bar.qml). Without this the card can
  // open on the wrong output on a multi-monitor setup, and seedPosition() /
  // clampPos() then measure that wrong output's geometry.
  function focusedScreen() {
    var monitor = Hyprland.focusedMonitor
    var name = monitor ? String(monitor.name || "") : ""
    if (name === "") return null
    var screens = Quickshell.screens || []
    for (var i = 0; i < screens.length; i++) {
      if (screens[i] && String(screens[i].name || "") === name) return screens[i]
    }
    return null
  }

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

  // --------------------------------------------------------------- actions
  function press(mod) {
    mod = String(mod || "").toUpperCase()
    if (root.leadingMods.indexOf(mod) < 0) return
    if (root.held.indexOf(mod) >= 0) {
      // Already held: keep-alive while browsing (resets the stuck guard).
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
  onRememberUsageChanged: recomputeSteps()
  onUsageCountsChanged: recomputeSteps()

  // --------------------------------------------------------------- timers
  Timer {
    id: revealTimer
    interval: root.revealDelayMs
    onTriggered: {
      if (root.held.length === 0) return
      // Pick the output *before* flipping `opened`, so the screen is only ever
      // assigned while the layer surface is unmapped — nothing in this shell
      // reassigns .screen on a visible window. A null result (Hyprland hasn't
      // reported a monitor yet) deliberately leaves the last good screen in
      // place rather than resetting to output 0.
      var target = root.focusedScreen()
      if (target) panel.screen = target
      root.opened = true
      // Seed/decentre after the content has laid out (cardH is stable then),
      // unless the user has already dragged the card somewhere.
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

  function fetchKeybindings() {
    keybindsProc.running = false
    keybindsProc.command = ["omarchy", "menu", "keybindings", "--print"]
    keybindsProc.running = true
  }

  function applyShellConfig(text) {
    try {
      var cfg = JSON.parse(text || "{}")
      root.rawSettings = Model.pickBarEntrySettings(cfg, root.pluginId)
    } catch (e) {
      root.rawSettings = {}
    }
  }

  Process {
    id: keybindsProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.hintGroups = Model.groupKeybindings(text)
        root.writeKnownBindings()
        root.recomputeSteps()
      }
    }
  }

  // Usage counts (Model.usageIdentity() -> press count), bumped only via the
  // `used` IPC call below. Lives under ~/.local/state/omarchy like the
  // built-in clipboard plugin's history file.
  FileView {
    id: usageFile
    path: root.stateDir + "/hotkey-hints-usage.json"
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.usageCounts = Model.parseUsageCounts(text())
    onLoadFailed: root.usageCounts = ({})
  }

  // The flattened set of every known binding's usage identity, written
  // whenever hintGroups is (re)computed. hotkey-watcher.py reads this to
  // decide whether a keypress is a real, bound hotkey before ever reporting
  // it — this file is the only thing that keeps the helper from acting on
  // ordinary typing, and its path is handed to the helper on the command line.
  FileView {
    id: bindingsFile
    path: root.stateDir + "/hotkey-hints-bindings.json"
    watchChanges: false
    atomicWrites: true
    printErrors: false
  }

  // Settings live in the bar entry's inline shell.json config (edited via
  // Widget.qml's popup); re-read that file directly so this always-loaded
  // overlay stays current without needing a bar-entry injection.
  FileView {
    id: shellConfigFile
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.applyShellConfig(text())
    onFileChanged: reload()
  }

  IpcHandler {
    target: root.pluginId
    function press(mod: string): string { root.press(mod); return "ok" }
    function release(mod: string): string { root.release(mod); return "ok" }
    function dismiss(): string { root.dismiss(); return "ok" }
    function state(): string { return root.opened ? "open" : "closed" }
    function ping(): string { return "ok" }
    // A manual test hook. In normal operation usage counts arrive on the
    // helper's stdout instead (handleWatcherLine), where the identity has
    // already been matched against bindingsFile, so nothing but a real,
    // currently-bound hotkey combo is ever recorded. A no-op while the setting
    // is off, so flipping it back on later doesn't need to "catch up" on
    // anything missed (nothing was missed — it's just not recorded until on).
    function used(identity: string): string {
      if (root.rememberUsage) root.bumpUsage(identity)
      return "ok"
    }
    function resetUsage(): string { root.resetUsage(); return "ok" }
    // Lets Widget.qml's settings popup tell the user whether the helper is
    // actually running, and retry it after they fix a permission problem.
    function status(): string { return root.watcherStatus }
    function retry(): string { root.retryWatcher(); return root.watcherStatus }
  }

  Component.onCompleted: {
    ensureStateDirProc.running = true
    // Defer a turn so the mkdir above has landed before the first write, and
    // so bindingsFile.path is resolved before the helper is handed it.
    Qt.callLater(function() {
      root.fetchKeybindings()
      shellConfigFile.reload()
      usageFile.reload()
      root.startWatcher()
    })
  }

  // A card-sized layer surface. Anchored top-left with pixel margins so it
  // can float anywhere; sized exactly to the card, so the input region (the
  // default mask = the whole surface) is the card and nothing else. Keyboard
  // interactivity is None: keystrokes keep flowing to the window underneath,
  // so typing while the hints are up is never hijacked.
  PanelWindow {
    id: panel
    visible: root.opened
    implicitWidth: root.cardW
    implicitHeight: root.cardH
    color: "transparent"
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "justarieldotcom-hotkey-hints"
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

          // ---- header: breadcrumb of held modifiers + dragging hint
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

          // ---- single compact chip row: direct combos, overflow, branches
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

          // ---- nothing reachable under this prefix
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

      // ---- drag anywhere to move the card
      MouseArea {
        anchors.fill: parent
        cursorShape: Qt.SizeAllCursor
        onPressed: function(m) {
          stuckGuard.restart()
          root.grabMove(m.x, m.y)
        }
        onPositionChanged: function(m) { root.dragMove(m.x, m.y) }
      }

      // ---- bottom-right corner: resize grip
      Rectangle {
        id: resizeGrip
        width: Math.max(16, Style.space(14))
        height: width
        anchors.right: parent.right
        anchors.bottom: parent.bottom
        color: Util.alpha(Color.accent, 0.18)
        radius: Math.min(6, Style.cornerRadius / 2)

        Text {
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