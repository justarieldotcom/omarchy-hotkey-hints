// Pure parsing logic for t480.hotkey-hints. No QML/Quickshell imports here —
// keep parsing/grouping testable in isolation, mirroring the sibling
// control-station plugin's Model.js convention.
.pragma library

var LEADING_MODS = ["SUPER", "ALT", "CTRL", "SHIFT"]

// One line of `omarchy menu keybindings --print` looks like:
//   "SUPER SHIFT ALT + B                 → Browser (private)"
//   "PRINT                                → Screenshot"
// Modifiers (if any) are space-separated, then " + ", then the key, then
// "→", then the free-text description. A line with no modifier (bare key)
// has no " + " at all.
function parseKeybindingLine(line) {
  var arrowIndex = line.indexOf("→") // →
  if (arrowIndex < 0) return null

  var left = line.slice(0, arrowIndex).trim()
  var description = line.slice(arrowIndex + 1).trim()
  if (!left || !description) return null

  var mods = []
  var key = left

  var plusIndex = left.lastIndexOf(" + ")
  if (plusIndex >= 0) {
    var modsPart = left.slice(0, plusIndex).trim()
    key = left.slice(plusIndex + 3).trim()
    if (modsPart) mods = modsPart.split(/\s+/).filter(function(m) { return m !== "" })
  }
  if (!key) return null

  return {
    mods: mods,
    key: key,
    leading: mods.length > 0 ? mods[0] : null,
    description: description
  }
}

function titleCaseToken(token) {
  // Leave digits/punctuation-only tokens (e.g. "0".."9") untouched; title-case
  // alphabetic ones ("RETURN" -> "Return").
  if (!/[A-Za-z]/.test(token)) return token
  return token.charAt(0).toUpperCase() + token.slice(1).toLowerCase()
}

function keyLabel(key) {
  return titleCaseToken(key)
}

function comboLabel(entry) {
  var rest = entry.mods.slice(1).concat([entry.key])
  return rest.map(titleCaseToken).join(" + ")
}

// Groups every binding whose FIRST/leading modifier (as written) is one of
// SUPER/ALT/CTRL/SHIFT into that bucket. Bindings with no modifier at all
// (e.g. bare PRINT) are dropped — this overlay only ever appears while a
// modifier is held, so they'd never be reachable through it.
function groupKeybindings(text) {
  var groups = {}
  for (var i = 0; i < LEADING_MODS.length; i++) groups[LEADING_MODS[i]] = []

  var lines = String(text || "").split("\n")
  for (var j = 0; j < lines.length; j++) {
    var entry = parseKeybindingLine(lines[j])
    if (!entry || !entry.leading) continue
    if (LEADING_MODS.indexOf(entry.leading) < 0) continue
    groups[entry.leading].push({
      mods: entry.mods,
      key: entry.key,
      description: entry.description,
      combo: comboLabel(entry)
    })
  }

  for (var k = 0; k < LEADING_MODS.length; k++) {
    groups[LEADING_MODS[k]].sort(function(a, b) {
      if (a.mods.length !== b.mods.length) return a.mods.length - b.mods.length
      return a.combo < b.combo ? -1 : (a.combo > b.combo ? 1 : 0)
    })
  }
  return groups
}

// Progressive disclosure. Given the modifiers currently held, produce the
// minimal "next step" hints instead of a wall of bindings:
//   direct     — combos completed by one more key (every modifier in the
//                binding is already held): held [SUPER]  ->  "+ K".
//   overflow   — how many direct combos were cut from the cap.
//   branches   — combos that need one more modifier before a key/more depth,
//                grouped by that next modifier: held [SUPER]  ->  "+ Ctrl (12)".
// Only bindings whose modifier SET is a superset of the held set are
// reachable; bindings that don't include every held modifier are ignored.
function stepsForHeld(groups, held, maxDirect) {
  var heldSet = {}
  for (var i = 0; i < held.length; i++) heldSet[held[i]] = true

  var direct = []
  var branchCounts = {}
  for (var b = 0; b < LEADING_MODS.length; b++) {
    var list = groups[LEADING_MODS[b]] || []
    for (var g = 0; g < list.length; g++) {
      var entry = list[g]

      var reachable = true
      for (var h = 0; h < held.length; h++) {
        if (entry.mods.indexOf(held[h]) < 0) { reachable = false; break }
      }
      if (!reachable) continue

      var next = null
      for (var m = 0; m < entry.mods.length; m++) {
        if (!heldSet[entry.mods[m]]) { next = entry.mods[m]; break }
      }
      if (next === null) {
        direct.push(entry)
      } else if (LEADING_MODS.indexOf(next) >= 0) {
        branchCounts[next] = (branchCounts[next] || 0) + 1
      }
    }
  }

  direct.sort(function(a, b) {
    // Nudged keys (SPACE, RETURN, ESCAPE …) and letters ahead of bare-digit
    // workspace binds, so the first cap-filled row shows the flagship combos
    // instead of SUPER+0…9.
    var digitA = /^[0-9]/.test(a.key), digitB = /^[0-9]/.test(b.key)
    if (digitA !== digitB) return digitA ? 1 : -1
    var ka = keyLabel(a.key), kb = keyLabel(b.key)
    if (ka < kb) return -1
    if (ka > kb) return 1
    return a.description < b.description ? -1 : (a.description > b.description ? 1 : 0)
  })

  var capped = []
  var capOn = maxDirect > 0
  for (var c = 0; c < direct.length; c++) {
    if (capOn && capped.length >= maxDirect) break
    capped.push({ key: keyLabel(direct[c].key), description: clipDescription(direct[c].description) })
  }
  var overflow = Math.max(0, direct.length - capped.length)

  var branches = []
  for (var q = 0; q < LEADING_MODS.length; q++) {
    var mod = LEADING_MODS[q]
    if (branchCounts[mod]) branches.push({ mod: titleCaseToken(mod), count: branchCounts[mod] })
  }

  return { direct: capped, overflow: overflow, branches: branches }
}

function clipDescription(text) {
  if (typeof text !== "string") return ""
  text = text.replace(/\s+/g, " ").trim()
  return text.length > 20 ? text.slice(0, 19).trim() + "…" : text
}

// Reads this plugin's own persisted inline settings out of a parsed
// shell.json (the same file the bar hot-reloads), searching every bar
// section since the widget may be placed left/center/right.
function pickBarEntrySettings(shellConfig, pluginId) {
  var layout = (shellConfig && shellConfig.bar && shellConfig.bar.layout) || {}
  var sections = ["left", "center", "right"]
  for (var i = 0; i < sections.length; i++) {
    var arr = layout[sections[i]] || []
    for (var j = 0; j < arr.length; j++) {
      var entry = arr[j]
      if (entry && entry.id === pluginId) {
        var out = {}
        for (var key in entry) if (key !== "id") out[key] = entry[key]
        return out
      }
    }
  }
  return {}
}

// Assert-based self-check. Run manually while developing:
//   qs -c "import 'Model.js' as Model; Model.selfCheck()"  (or via a throwaway QML file)
function selfCheck() {
  var sample = [
    "SUPER + K                           → Keybindings",
    "SUPER SHIFT ALT + B                 → Browser (private)",
    "CTRL ALT + DELETE                   → Close all windows",
    "PRINT                                → Screenshot",
    "ALT + PRINT                         → Screenrecording",
    "SUPER SHIFT + TAB                   → Previous workspace",
    "SUPER CTRL + V                      → Universal paste",
    "SUPER CTRL + TAB                    → Former workspace"
  ].join("\n")

  var g = groupKeybindings(sample)

  console.assert(g.SUPER.length === 5, "SUPER bucket should have 5 entries, got " + g.SUPER.length)
  console.assert(g.SUPER[0].combo === "K", "shortest SUPER combo should sort first, got " + g.SUPER[0].combo)
  console.assert(g.CTRL.length === 1 && g.CTRL[0].description === "Close all windows",
    "CTRL leading bucket wrong")

  // held = [SUPER]: direct 2-key combos + branches for SHIFT and CTRL.
  var l1 = stepsForHeld(g, ["SUPER"], 8)
  console.assert(l1.direct.length === 1 && l1.direct[0].key === "K" && l1.direct[0].description === "Keybindings",
    "SUPER level should list the SUPER+K direct combo, got " + JSON.stringify(l1.direct))
  console.assert(l1.overflow === 0, "no overflow at SUPER level, got " + l1.overflow)
  console.assert(l1.branches.length === 2 && l1.branches[0].mod === "Ctrl" && l1.branches[1].mod === "Shift",
    "SUPER level branches should be Ctrl and Shift (LEADING_MODS order), got " + JSON.stringify(l1.branches))
  console.assert(l1.branches[0].count === 2, "Shift branch should have 2 (SUPER SHIFT ...), got " + l1.branches[0].count)

  // held = [SUPER, CTRL]: SUPER+CTRL direct combos, no branches left.
  var l2 = stepsForHeld(g, ["SUPER", "CTRL"], 8)
  console.assert(l2.direct.length === 2 && l2.direct[0].key === "Tab" && l2.direct[1].key === "V",
    "SUPER+CTRL level should show the V and Tab combos, got " + JSON.stringify(l2.direct))
  console.assert(l2.branches.length === 0, "SUPER+CTRL has no deeper modifiers, got " + JSON.stringify(l2.branches))

  // held order must not matter (set semantics).
  var reversed = stepsForHeld(g, ["CTRL", "SUPER"], 8)
  console.assert(reversed.direct.length === l2.direct.length && reversed.direct[0].key === "Tab",
    "held-modifier order should not change results, got " + JSON.stringify(reversed.direct))

  // Cap must truncate and report overflow.
  var capped = stepsForHeld(g, ["SUPER"], 1)
  console.assert(capped.direct.length === 1 && capped.overflow === 0,
    "cap=1 with 1 direct should show it, got " + JSON.stringify(capped.direct))

  // 3-mod binding SUPER SHIFT ALT + B only appears once SHIFT has been added.
  var withShift = stepsForHeld(g, ["SUPER", "SHIFT"], 8)
  console.assert(withShift.branches.length === 1 && withShift.branches[0].mod === "Alt",
    "SUPER+SHIFT should branch into Alt, got " + JSON.stringify(withShift.branches))

  var cfg = { bar: { layout: { right: [{ id: "other.plugin", x: 1 }, { id: "t480.hotkey-hints", fontSize: 15, position: "top" }] } } }
  var picked = pickBarEntrySettings(cfg, "t480.hotkey-hints")
  console.assert(picked.fontSize === 15 && picked.position === "top" && picked.id === undefined,
    "pickBarEntrySettings should return this plugin's own fields, minus id")
  console.assert(Object.keys(pickBarEntrySettings(cfg, "missing.plugin")).length === 0,
    "pickBarEntrySettings should return {} when the entry isn't in the bar layout")

  return true
}