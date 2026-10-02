import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// Settings panel for videinfra.tandem, in three pages: Desktops, Keybinds and
// Styling. Every read and write goes through the tandem-config script in the
// sibling plugin, so validation and file handling live in one tested place
// instead of being reimplemented here.
//
// Desktop, name, key and transition edits are staged locally and only written
// when Apply is pressed: each write regenerates the Hyprland config and
// reloads it, which is far too disruptive to do on every click while someone
// is still deciding. Density, font size and the popup only change how things
// look, so they save as soon as they are picked.
Panel {
  id: root
  moduleName: "videinfra.tandem"
  ipcTarget: "videinfra.tandem"

  // Set by BarWidget.qml. The bar only marks a panel as open when its
  // registered owner is the item in the bar slot, which is that wrapper.
  property var popoutOwner: null

  readonly property string pluginDir:
    Quickshell.env("HOME") + "/.config/omarchy/plugins/videinfra.tandem"

  // Saved values, as last read from disk.
  property int desktops: 2
  property bool numbers: true
  property bool tabKeys: true
  property bool scrollKeys: true
  property string toggleKey: "SUPER + F"
  property string sendKey: "SUPER + SHIFT + F"
  property string version: ""
  property string animation: "slide"
  property string savedMode: ""
  property var detected: []
  property var monitorNames: []   // the order tandem uses: configured, else detected
  property var savedLabels: []   // normalized from disk, one per desktop
  property var pLabels: []       // staged edits
  property var labelSlots: []    // drives the Repeater; reassigned to rebuild it

  // Staged edits.
  property int pDesktops: 2
  property bool pNumbers: true
  property bool pTab: true
  property bool pScroll: true
  property string pEffect: "slide"
  property string pMode: "horizontal"
  property string pToggle: "SUPER + F"
  property string pSend: "SUPER + SHIFT + F"

  readonly property string repoUrl: "https://github.com/thevideinfra/tandem"

  // ---- Editing the switch keys ----
  // A key is a set of modifiers plus one plain key. The plain key is captured
  // from a real key press while the panel has focus; the modifiers are chosen
  // with buttons, because SUPER + the key would be taken by the compositor
  // bind before the panel ever saw it.
  readonly property var modifierNames: ["SUPER", "SHIFT", "CTRL", "ALT"]
  property string keyEdit: ""      // "toggle", "send" or "" for none
  property bool capturing: false   // waiting for the plain key
  property string keyError: ""

  function keyParts(spec) {
    return String(spec).split("+").map(function(p) { return p.trim() })
      .filter(function(p) { return p !== "" })
  }

  function keyModifiers(spec) {
    return keyParts(spec).filter(function(p) { return modifierNames.indexOf(p) >= 0 })
  }

  function keyBase(spec) {
    var rest = keyParts(spec).filter(function(p) { return modifierNames.indexOf(p) < 0 })
    return rest.length > 0 ? rest[rest.length - 1] : ""
  }

  function joinKey(mods, base) {
    var ordered = modifierNames.filter(function(m) { return mods.indexOf(m) >= 0 })
    return ordered.concat([base]).join(" + ")
  }

  // The carry-a-window key is the switch key with SHIFT added, unless it has
  // been set to something else. While it is still that, it follows the switch
  // key.
  function withShift(spec) {
    var mods = keyModifiers(spec)
    if (mods.indexOf("SHIFT") < 0) mods.push("SHIFT")
    return joinKey(mods, keyBase(spec))
  }

  function setKey(which, spec) {
    keyError = ""
    if (which === "toggle") {
      var follows = pSend === withShift(pToggle)
      pToggle = spec
      if (follows) pSend = withShift(spec)
    } else {
      pSend = spec
    }
    if (pToggle === pSend) keyError = "Both keys are the same"
  }

  function toggleModifier(which, name) {
    var spec = which === "toggle" ? pToggle : pSend
    var mods = keyModifiers(spec)
    var at = mods.indexOf(name)
    if (at >= 0) mods.splice(at, 1)
    else mods.push(name)
    if (mods.length === 0) {
      keyError = "Keep at least one modifier"
      return
    }
    setKey(which, joinKey(mods, keyBase(spec)))
  }

  // Qt key -> the key name Hyprland binds use. Anything not listed is not
  // offered rather than guessed at.
  readonly property var keyNames: ({
    [Qt.Key_Space]: "space", [Qt.Key_Return]: "Return", [Qt.Key_Enter]: "Return",
    [Qt.Key_Tab]: "Tab", [Qt.Key_Backspace]: "BackSpace",
    [Qt.Key_Left]: "Left", [Qt.Key_Right]: "Right", [Qt.Key_Up]: "Up", [Qt.Key_Down]: "Down",
    [Qt.Key_Home]: "Home", [Qt.Key_End]: "End", [Qt.Key_PageUp]: "Prior", [Qt.Key_PageDown]: "Next",
    [Qt.Key_Comma]: "comma", [Qt.Key_Period]: "period", [Qt.Key_Slash]: "slash",
    [Qt.Key_Semicolon]: "semicolon", [Qt.Key_Apostrophe]: "apostrophe",
    [Qt.Key_Minus]: "minus", [Qt.Key_Equal]: "equal",
    [Qt.Key_BracketLeft]: "bracketleft", [Qt.Key_BracketRight]: "bracketright",
    [Qt.Key_Backslash]: "backslash", [Qt.Key_QuoteLeft]: "grave"
  })

  function hyprKeyName(key) {
    if (key >= Qt.Key_A && key <= Qt.Key_Z) return String.fromCharCode(key)
    if (key >= Qt.Key_0 && key <= Qt.Key_9) return String.fromCharCode(key)
    if (key >= Qt.Key_F1 && key <= Qt.Key_F12) return "F" + (key - Qt.Key_F1 + 1)
    return keyNames[key] || ""
  }

  function isModifierKey(key) {
    return key === Qt.Key_Shift || key === Qt.Key_Control || key === Qt.Key_Alt
      || key === Qt.Key_Meta || key === Qt.Key_Super_L || key === Qt.Key_Super_R
      || key === Qt.Key_AltGr || key === Qt.Key_CapsLock
  }

  function captureKey(event) {
    if (event.key === Qt.Key_Escape) {
      capturing = false
      keyKeeper.focus = false
      keyCatcher.forceActiveFocus()
      return
    }
    if (isModifierKey(event.key)) return
    var name = hyprKeyName(event.key)
    if (name === "") {
      keyError = "That key is not supported"
    } else {
      var spec = keyEdit === "toggle" ? pToggle : pSend
      setKey(keyEdit, joinKey(keyModifiers(spec), name))
    }
    capturing = false
    keyCatcher.forceActiveFocus()
  }

  // ---- Switch mode and transition ----
  // Hyprland takes one style string that fuses the two: "slide" and
  // "slidevert", "slidefade" and "slidefadevert", plus "fade" and "none".
  // The panel offers them as two choices -- which way the monitors are
  // arranged, and what the switch looks like -- and joins them on apply.
  // Fade and none have no direction, so the mode is saved on its own for the
  // popup and the panel to follow.
  readonly property bool stacked: {
    var mons = root.detected
    if (!mons || mons.length < 2) return false
    var a = mons[0], b = mons[1]
    var sideBySide = a.y < b.y + b.height && b.y < a.y + a.height
    return !sideBySide
  }

  function effectOf(style) {
    if (style === "slidevert") return "slide"
    if (style === "slidefadevert") return "slidefade"
    return style
  }

  function modeOf(style) {
    if (style === "slidevert" || style === "slidefadevert") return "vertical"
    if (style === "slide" || style === "slidefade") return "horizontal"
    if (root.savedMode !== "") return root.savedMode
    return root.stacked ? "vertical" : "horizontal"
  }

  function styleOf(effect, mode) {
    if (effect === "slide") return mode === "vertical" ? "slidevert" : "slide"
    if (effect === "slidefade") return mode === "vertical" ? "slidefadevert" : "slidefade"
    return effect
  }

  readonly property string effect: effectOf(animation)
  readonly property string mode: modeOf(animation)

  readonly property var effectChoices: [
    { value: "slide", label: "Slide" },
    { value: "fade", label: "Fade" },
    { value: "slidefade", label: "Slide + fade" },
    { value: "none", label: "Default" }
  ]

  property bool busy: false
  property string errorText: ""

  // ---- Display settings ----
  // Same scales as omaudiopanel, so the two panels match side by side.
  property string density: "normal"
  property string fontSize: "normal"
  property bool popup: false
  property string indicator: "boxes"
  property bool divider: false
  property bool windowIcons: false
  property bool clickToSwitch: true
  property string accentChoice: "theme"
  readonly property real densityScale:
    density === "compact" ? 0.61 : (density === "roomy" ? 0.83 : 0.71)
  // Text shrinks half as fast as spacing so compact stays readable, then the
  // font size setting scales it on top.
  readonly property real fontScale: (0.5 + 0.5 * densityScale)
    * (fontSize === "small" ? 0.85 : (fontSize === "large" ? 1.07 : 0.95))
  // Sized off the title token: themes can set body larger than title, which
  // made field and switch text outgrow the panel's own heading.
  readonly property real fontTitle: Math.round(Style.font.title * fontScale * 1.1)
  readonly property real fontBody: Math.round(Style.font.title * fontScale)
  readonly property real fontSmall: Math.max(9, Math.round(Style.font.title * fontScale * 0.9))
  readonly property real fontCaption: Math.max(9, Math.round(Style.font.caption * fontScale))
  readonly property real fontDisplay: Math.round(Style.font.display * fontScale)

  property string page: "desktops"
  readonly property var pages: [
    { id: "desktops", label: "Desktops", icon: "" },
    { id: "keybinds", label: "Keybinds", icon: "" },
    { id: "styling", label: "Styling", icon: "" }
  ]

  function stepPage(step) {
    var index = 0
    for (var i = 0; i < pages.length; i++) if (pages[i].id === page) index = i
    page = pages[((index + step) % pages.length + pages.length) % pages.length].id
  }

  TandemAccent {
    id: accentSource
    choice: root.accentChoice
  }

  // The colour Tandem highlights with: the theme accent, or a chosen palette colour.
  readonly property color accent: accentSource.value

  // Style.space scaled by the chosen density.
  function sp(px) {
    return Style.space(px * densityScale)
  }

  function tint(alpha) {
    return Util.alpha(root.barForeground, alpha)
  }

  function setDisplay(key, value) {
    root[key] = value
    Quickshell.execDetached([root.pluginDir + "/tandem-config", "set", key, String(value)])
  }

  // Saved under the key "accent"; the property is named for what it holds.
  function setAccent(name) {
    accentChoice = name
    Quickshell.execDetached([root.pluginDir + "/tandem-config", "set", "accent", name])
  }

  function showDesk(index) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("tandem_show(" + index + ")"))
  }

  // Desktops are laid out one workspace per monitor, as in the indicator.
  readonly property int monitorCount: Math.max(1, Hyprland.monitors.values.length)
  readonly property int currentDesk: Hyprland.focusedWorkspace === null
    ? 1
    : Math.max(1, Math.ceil(Hyprland.focusedWorkspace.id / monitorCount))

  // Where a detected monitor sits relative to the others: "Top" / "Bottom"
  // when stacked, "Left" / "Right" side by side, "Top left" and so on for a
  // grid. Monitors whose vertical extents overlap count as one row.
  function monitorPosition(index) {
    var mons = root.detected
    if (!mons || mons.length < 2 || !mons[index]) return ""
    var rows = []
    var sorted = mons.slice().sort(function(a, b) { return a.y - b.y || a.x - b.x })
    for (var i = 0; i < sorted.length; i++) {
      var m = sorted[i], placed = false
      for (var r = 0; r < rows.length && !placed; r++) {
        var first = rows[r][0]
        if (m.y < first.y + first.height && first.y < m.y + m.height) {
          rows[r].push(m)
          placed = true
        }
      }
      if (!placed) rows.push([m])
    }
    function pick(i, n, names) {
      if (n < 2) return ""
      return i === 0 ? names[0] : (i === n - 1 ? names[2] : names[1])
    }
    var target = mons[index]
    for (var r2 = 0; r2 < rows.length; r2++) {
      var row = rows[r2].sort(function(a, b) { return a.x - b.x })
      var col = row.indexOf(target)
      if (col < 0) continue
      var v = pick(r2, rows.length, ["Top", "Middle", "Bottom"])
      var h = pick(col, row.length, ["Left", "Center", "Right"])
      if (v && h) return v + " " + h.toLowerCase()
      return v || h
    }
    return ""
  }

  // Workspace numbers a desktop owns, one per monitor: "1 \u00b7 2".
  function workspacesOf(desk) {
    var out = []
    var count = Math.max(1, monitorNames.length || monitorCount)
    for (var i = 1; i <= count; i++) out.push((desk - 1) * count + i)
    return out
  }

  WindowIcons {
    id: windowData
    monitorCount: Math.max(1, root.monitorNames.length || root.monitorCount)
    appLibrary: root.bar && root.bar.shell ? root.bar.shell.appLibrary : null
  }

  function windowsOfDesk(desk) { return windowData.windowsOfDesk(desk) }

  // "WS 1, 2": the workspaces a desktop owns, one per monitor.
  function workspaceText(desk) {
    return "WS " + workspacesOf(desk).join(", ")
  }

  function iconFor(appId) { return windowData.iconFor(appId) }

  // Which workspace a monitor shows on the desktop you are on.
  function workspaceOnMonitor(name) {
    var at = monitorNames.indexOf(name)
    return at < 0 ? 0 : workspacesOf(currentDesk)[at]
  }

  function positionByName(name) {
    for (var i = 0; i < detected.length; i++)
      if (detected[i].name === name) return monitorPosition(i)
    return ""
  }

  // ---- Identify: name every screen on itself for a moment ----
  property bool identifying: false

  function identify() {
    identifying = true
    identifyTimer.restart()
  }

  Timer {
    id: identifyTimer
    interval: 2500
    onTriggered: root.identifying = false
  }

  Variants {
    model: Quickshell.screens

    PanelWindow {
      id: identifyWindow
      required property var modelData
      screen: modelData
      visible: root.identifying
      implicitWidth: identifyCard.width
      implicitHeight: identifyCard.height
      color: "transparent"
      WlrLayershell.namespace: "tandem-identify"
      WlrLayershell.layer: WlrLayer.Overlay
      WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
      exclusionMode: ExclusionMode.Ignore
      mask: Region {}

      BorderSurface {
        id: identifyCard
        width: borderLeft + borderRight + identifyColumn.implicitWidth + Style.space(48)
        height: borderTop + borderBottom + identifyColumn.implicitHeight + Style.space(32)
        color: Util.alpha(Color.background, 0.97)
        borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
        radius: Style.cornerRadius

        Column {
          id: identifyColumn
          anchors.centerIn: parent
          spacing: Style.space(4)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: identifyWindow.modelData.name
            color: root.accent
            font.family: Style.font.family
            font.pixelSize: Style.font.displayLarge
            font.bold: true
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            readonly property string place: root.positionByName(identifyWindow.modelData.name)
            readonly property int ws: root.workspaceOnMonitor(identifyWindow.modelData.name)
            text: (place !== "" ? place + " \u00b7 " : "") + (ws > 0 ? "workspace " + ws : "")
            color: Color.popups.text
            opacity: 0.75
            font.family: Style.font.family
            font.pixelSize: Style.font.title
          }
        }
      }
    }
  }

  readonly property bool labelsDirty:
    JSON.stringify(pLabels) !== JSON.stringify(savedLabels)

  // How many separate edits are waiting for Apply.
  readonly property int pending:
    (pDesktops !== desktops ? 1 : 0)
    + (labelsDirty ? 1 : 0)
    + (pNumbers !== numbers ? 1 : 0)
    + (pTab !== tabKeys ? 1 : 0)
    + (pScroll !== scrollKeys ? 1 : 0)
    + (pEffect !== effect ? 1 : 0)
    + (pMode !== mode ? 1 : 0)
    + (pToggle !== toggleKey ? 1 : 0)
    + (pSend !== sendKey ? 1 : 0)

  readonly property bool dirty: pending > 0 && keyError === ""

  // Panel is a plain Item; the bar slot takes its size from here, so without
  // this the widget collapses to zero width and never renders.
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function reload() {
    if (readProc.running) return
    readProc.running = true
  }

  function revert() {
    pLabels = savedLabels.slice()
    rebuildSlots()
    pDesktops = desktops
    pNumbers = numbers
    pTab = tabKeys
    pScroll = scrollKeys
    pEffect = effect
    pMode = mode
    pToggle = toggleKey
    pSend = sendKey
    keyEdit = ""
    capturing = false
    keyError = ""
    errorText = ""
  }

  function applyConfig(text) {
    try {
      var data = JSON.parse(text)
      desktops = data.desktops
      numbers = data.numbers === true
      tabKeys = data.tab === true
      scrollKeys = data.scroll === true
      toggleKey = data.toggle
      sendKey = data.send
      version = data.version || ""
      savedMode = data.mode || ""
      animation = data.animation || "slide"
      density = data.density || "normal"
      fontSize = data.fontSize || "normal"
      popup = data.popup === true
      indicator = data.indicator === "text" ? "text" : "boxes"
      divider = data.divider === true
      windowIcons = data.windowIcons === true
      clickToSwitch = data.clickToSwitch !== false
      accentChoice = data.accent || "theme"
      detected = data.detected || []
      monitorNames = data.monitors || detected.map(function(m) { return m.name })
      savedLabels = normalizeLabels(data.labels, data.desktops)
      revert()
    } catch (e) {
      errorText = "Could not read settings"
    }
  }

  function apply() {
    if (busy || !dirty) return
    var patch = {}
    if (pDesktops !== desktops) patch.desktops = pDesktops
    if (pNumbers !== numbers) patch.numbers = pNumbers
    if (pTab !== tabKeys) patch.tab = pTab
    if (pScroll !== scrollKeys) patch.scroll = pScroll
    if (pToggle !== toggleKey) patch.toggle = pToggle
    if (pSend !== sendKey) patch.send = pSend
    if (pEffect !== effect || pMode !== mode) {
      var style = styleOf(pEffect, pMode)
      if (style !== animation) patch.animation = style
      patch.mode = pMode
    }
    if (labelsDirty) {
      // Blank fields fall back to the default name, and an all-default set is
      // stored as [] so the config does not carry redundant D1..Dn.
      var out = normalizeLabels(pLabels, pDesktops)
      patch.labels = allDefault(out) ? [] : out
    }

    busy = true
    errorText = ""
    writeProc.command = [root.pluginDir + "/tandem-config", "set-json", JSON.stringify(patch)]
    writeProc.running = true
  }

  function defaultLabel(i) { return "D" + (i + 1) }

  // Always exactly `count` entries: a short or missing list is topped up with
  // defaults, a long one is truncated.
  function normalizeLabels(arr, count) {
    var out = []
    for (var i = 0; i < count; i++)
      out.push(arr && arr[i] ? String(arr[i]) : defaultLabel(i))
    return out
  }

  // The Repeater rebuilds only when its model identity changes, so the fields
  // pick up externally changed names instead of keeping stale text.
  function rebuildSlots() {
    var slots = []
    for (var i = 0; i < pLabels.length; i++) slots.push({ i: i, initial: pLabels[i] })
    labelSlots = slots
  }

  function setLabel(i, text) {
    var copy = pLabels.slice()
    copy[i] = text
    pLabels = copy
  }

  function allDefault(arr) {
    for (var i = 0; i < arr.length; i++)
      if (arr[i] !== defaultLabel(i)) return false
    return true
  }

  onPDesktopsChanged: {
    pLabels = normalizeLabels(pLabels, pDesktops)
    rebuildSlots()
  }

  function runSetup() {
    if (root.bar) root.bar.run("omarchy-launch-tui " + root.pluginDir + "/tandem-setup")
    root.close()
  }

  // True while a name field has focus, so typed letters reach it instead of
  // being taken as panel keys (j, k, h, l and x all are).
  property bool editing: false

  // Re-read on open so the panel never shows values a wizard run has changed,
  // and drop any edits that were staged but never applied. It opens on the
  // desktops page.
  onOpenedChanged: {
    if (opened) reload()
    else {
      page = "desktops"
      editing = false
      capturing = false
      keyEdit = ""
    }
  }

  Process {
    id: readProc
    command: [root.pluginDir + "/tandem-config", "get"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyConfig(text)
    }
  }

  Process {
    id: writeProc
    stderr: StdioCollector { waitForEnd: true }
    onExited: function(code) {
      root.busy = false
      if (code !== 0) root.errorText = "Could not apply changes"
      root.reload()
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    iconComponent: Component {
      Item {
        TandemIcon {
          anchors.centerIn: parent
          color: root.barForeground
        }
      }
    }
    tooltipText: "Tandem · virtual desktops"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root.popoutOwner || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Less padding than the shell's popups, to save space; the width gives up
    // the same amount so the content area keeps its size.
    padding: Style.space(8)
    readonly property int savedPadding: Math.max(0, Style.spacing.popupPadding - panel.padding)
    // Never narrower than the status line and the banner need, whatever the
    // density scales the spacing down to.
    contentWidth: panel.fittedContentWidth(Math.max(root.sp(330), Style.space(220)) - 2 * savedPadding)
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      blocked: root.editing || root.capturing
      onCloseRequested: root.close()
      onActivateRequested: root.apply()
      onMoveRequested: function(dx, dy) { if (dx !== 0) root.stepPage(dx) }
      onTabRequested: function(direction) { root.switchPanel(direction) }

      // Takes focus while a key is being captured, so the press reaches it
      // before anything else in the panel.
      Item {
        id: keyKeeper
        Keys.onPressed: function(event) {
          if (!root.capturing) return
          root.captureKey(event)
          event.accepted = true
        }
      }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: root.sp(10)

        // ---------- Header: icon · title/status ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(headerIcon.implicitHeight, headerLabels.implicitHeight)

          TandemIcon {
            id: headerIcon
            iconWidth: Math.round(root.fontDisplay * 1.5)
            color: root.accent
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: headerLabels
            anchors.left: headerIcon.right
            anchors.leftMargin: root.sp(12)
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.sp(2)

            // The name on the left; the version and the repository link on
            // the right of the same line, so they stay clear of it.
            Item {
              width: parent.width
              implicitHeight: Math.max(titleText.implicitHeight, versionRow.implicitHeight)

              Text {
                id: titleText
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                text: "Tandem"
                color: root.barForeground
                font.family: Style.font.family
                font.pixelSize: root.fontTitle
                font.bold: true
              }

              Row {
                id: versionRow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: root.sp(7)

              Rectangle {
                visible: root.version !== ""
                anchors.verticalCenter: parent.verticalCenter
                width: versionText.implicitWidth + root.sp(10)
                height: versionText.implicitHeight + root.sp(4)
                radius: height / 2
                color: Util.alpha(root.accent, 0.15)
                border.width: 1
                border.color: Util.alpha(root.accent, 0.45)

                Text {
                  id: versionText
                  anchors.centerIn: parent
                  textFormat: Text.PlainText
                  text: "v" + root.version
                  color: root.accent
                  font.family: Style.font.family
                  font.pixelSize: root.fontCaption
                  font.bold: true
                }
              }

              // Opens the repository in the browser.
              Text {
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "\uf09b"
                color: repoMouse.containsMouse ? root.accent : root.barForeground
                opacity: repoMouse.containsMouse ? 1.0 : 0.6
                font.family: Style.font.family
                font.pixelSize: root.fontBody

                MouseArea {
                  id: repoMouse
                  anchors.fill: parent
                  anchors.margins: -root.sp(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: {
                    if (root.bar) root.bar.run("xdg-open " + Util.shellQuote(root.repoUrl))
                    root.close()
                  }
                }

                PanelToolTip {
                  visible: repoMouse.containsMouse
                  text: "Open on GitHub"
                  fontFamily: Style.font.family
                }
              }
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: ("Desktop " + root.currentDesk + "/" + root.desktops
                + " · " + root.monitorCount
                + (root.monitorCount === 1 ? " monitor" : " monitors")).toUpperCase()
              color: Qt.darker(root.barForeground, 1.4)
              font.family: Style.font.family
              font.pixelSize: root.fontCaption
              font.bold: true
              font.letterSpacing: 0.6
              elide: Text.ElideRight
            }
          }

        }

        PanelSeparator { foreground: root.barForeground }

        // ---------- Pages ----------
        // Sized to the tallest page so the panel does not jump about as the
        // tabs change.
        Item {
          width: parent.width
          implicitHeight: Math.max(desktopsPage.implicitHeight,
            keybindsPage.implicitHeight, stylingPage.implicitHeight)

          DesktopsPage { id: desktopsPage; visible: root.page === "desktops" }
          KeybindsPage { id: keybindsPage; visible: root.page === "keybinds" }
          StylingPage { id: stylingPage; visible: root.page === "styling" }
        }

        // ---------- Staged changes ----------
        Rectangle {
          width: parent.width
          visible: root.dirty || root.busy || root.errorText !== ""
          implicitHeight: bannerRow.implicitHeight + root.sp(16)
          radius: root.sp(7)
          color: Util.alpha(root.errorText !== "" ? (root.bar ? root.bar.urgent : Color.urgent) : root.accent, 0.12)
          border.width: 1
          border.color: Util.alpha(root.errorText !== "" ? (root.bar ? root.bar.urgent : Color.urgent) : root.accent, 0.4)

          Row {
            id: bannerRow
            anchors.fill: parent
            anchors.margins: root.sp(8)
            spacing: root.sp(8)

            Text {
              width: parent.width - revertText.width - applyButton.width - root.sp(16)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.errorText !== "" ? root.errorText
                : (root.busy ? "Applying..." : root.pending + " pending")
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: root.fontSmall
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              id: revertText
              anchors.verticalCenter: parent.verticalCenter
              visible: !root.busy
              textFormat: Text.PlainText
              text: "Revert"
              color: root.barForeground
              opacity: revertMouse.containsMouse ? 1.0 : 0.65
              font.family: Style.font.family
              font.pixelSize: root.fontSmall

              MouseArea {
                id: revertMouse
                anchors.fill: parent
                anchors.margins: -root.sp(4)
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.revert()
              }
            }

            Rectangle {
              id: applyButton
              anchors.verticalCenter: parent.verticalCenter
              width: applyText.implicitWidth + root.sp(18)
              height: applyText.implicitHeight + root.sp(10)
              radius: root.sp(6)
              color: root.accent
              opacity: root.busy ? 0.5 : (applyMouse.containsMouse ? 1.0 : 0.9)

              Text {
                id: applyText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "Apply & reload"
                color: root.onAccent
                font.family: Style.font.family
                font.pixelSize: root.fontSmall
                font.bold: true
              }

              MouseArea {
                id: applyMouse
                anchors.fill: parent
                hoverEnabled: true
                enabled: root.dirty && !root.busy
                cursorShape: Qt.PointingHandCursor
                onClicked: root.apply()
              }
            }
          }
        }

        // ---------- Tabs ----------
        PanelSeparator { foreground: root.barForeground }

        Row {
          width: parent.width

          Repeater {
            model: root.pages

            Item {
              id: tab
              required property var modelData
              readonly property bool current: root.page === modelData.id
              width: parent.width / root.pages.length
              height: tabColumn.implicitHeight + root.sp(8)

              Rectangle {
                visible: tab.current
                anchors.top: parent.top
                anchors.horizontalCenter: parent.horizontalCenter
                width: parent.width * 0.5
                height: Math.max(2, root.sp(2))
                radius: height / 2
                color: root.accent
              }

              Column {
                id: tabColumn
                anchors.centerIn: parent
                spacing: root.sp(2)

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: tab.modelData.icon
                  color: tab.current ? root.accent : root.barForeground
                  opacity: tab.current || tabMouse.containsMouse ? 1.0 : 0.55
                  font.family: Style.font.family
                  font.pixelSize: root.fontTitle
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: tab.modelData.label
                  color: tab.current ? root.accent : root.barForeground
                  opacity: tab.current || tabMouse.containsMouse ? 1.0 : 0.55
                  font.family: Style.font.family
                  font.pixelSize: root.fontCaption
                  font.bold: tab.current
                }
              }

              MouseArea {
                id: tabMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.page = tab.modelData.id
              }
            }
          }
        }
      }
    }
  }

  // Text on an accent fill: black or white by the accent's luminance, so it
  // stays readable whatever the theme's accent is.
  readonly property color onAccent: {
    var c = root.accent
    return (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) > 0.5 ? "#101014" : "#ffffff"
  }

  // ===================== pages =====================

  component DesktopsPage: Column {
    width: parent.width
    spacing: root.sp(10)

    SectionLabel { icon: ""; text: "DESKTOPS"; tag: "REQUIRES APPLY" }

    Item {
      width: parent.width
      implicitHeight: stepper.implicitHeight

      Text {
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.pDesktops + (root.pDesktops === 1 ? " desktop" : " desktops")
        color: root.barForeground
        font.family: Style.font.family
        font.pixelSize: root.fontBody
      }

      Row {
        id: stepper
        anchors.right: parent.right
        spacing: root.sp(8)

        StepButton {
          iconText: ""
          tooltipText: "One fewer desktop"
          active: root.pDesktops > 1
          onClicked: if (root.pDesktops > 1) root.pDesktops--
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: root.sp(22)
          horizontalAlignment: Text.AlignHCenter
          text: root.pDesktops
          color: root.accent
          font.family: Style.font.family
          font.pixelSize: root.fontTitle
          font.bold: true
        }

        StepButton {
          iconText: ""
          tooltipText: "One more desktop"
          active: root.pDesktops < 10
          onClicked: if (root.pDesktops < 10) root.pDesktops++
        }
      }
    }

    // One row per desktop: its number, a name field, and either an ACTIVE
    // mark or a button to switch to it.
    Column {
      width: parent.width
      spacing: root.sp(5)

      Repeater {
        model: root.labelSlots

        Rectangle {
          id: deskRow
          required property var modelData
          readonly property bool current: modelData.i + 1 === root.currentDesk
          width: parent.width
          implicitHeight: nameField.implicitHeight + infoLine.implicitHeight + root.sp(15)
          radius: root.sp(7)
          color: current ? Util.alpha(root.accent, 0.12) : root.tint(0.05)
          border.width: 1
          border.color: current ? Util.alpha(root.accent, 0.45) : root.tint(0.1)

          Rectangle {
            width: root.sp(26)
            height: root.sp(26)
            id: numberChip
            anchors.left: parent.left
            anchors.leftMargin: root.sp(6)
            anchors.verticalCenter: parent.verticalCenter
            radius: root.sp(6)
            color: root.tint(0.08)
            border.width: 1
            border.color: deskRow.current ? root.accent : root.tint(0.18)

            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: deskRow.modelData.i + 1
              color: deskRow.current ? root.accent : root.barForeground
              font.family: Style.font.family
              font.pixelSize: root.fontSmall
              font.bold: true
            }
          }

          // ACTIVE on the current desktop, Switch on the others.
          Item {
            id: rowAction
            anchors.right: parent.right
            anchors.rightMargin: root.sp(6)
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(activeText.implicitWidth, switchText.implicitWidth) + root.sp(16)
            height: activeText.implicitHeight + root.sp(8)

            Rectangle {
              anchors.fill: parent
              visible: deskRow.current
              radius: root.sp(5)
              color: root.accent

              Text {
                id: activeText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "ACTIVE"
                color: root.onAccent
                font.family: Style.font.family
                font.pixelSize: root.fontCaption
                font.bold: true
                font.letterSpacing: 0.8
              }
            }

            Rectangle {
              anchors.fill: parent
              visible: !deskRow.current
              radius: root.sp(5)
              color: switchMouse.containsMouse ? Util.alpha(root.accent, 0.18) : "transparent"
              border.width: 1
              border.color: switchMouse.containsMouse ? root.accent : root.tint(0.25)

              Text {
                id: switchText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "Switch"
                color: switchMouse.containsMouse ? root.accent : root.barForeground
                font.family: Style.font.family
                font.pixelSize: root.fontCaption
              }

              MouseArea {
                id: switchMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.showDesk(deskRow.modelData.i + 1)
              }
            }
          }

          TextField {
            id: nameField
            anchors.left: numberChip.right
            anchors.leftMargin: root.sp(6)
            anchors.right: rowAction.left
            anchors.rightMargin: root.sp(6)
            anchors.top: parent.top
            anchors.topMargin: root.sp(5)
            placeholderText: root.defaultLabel(deskRow.modelData.i)
            foreground: root.barForeground
            font.family: Style.font.family
            font.pixelSize: root.fontBody
            verticalPadding: root.sp(4)
            maximumLength: 16

            // Set once rather than bound: a binding would fight the cursor
            // while typing, since editing rewrites the array it reads from.
            Component.onCompleted: text = deskRow.modelData.initial
            onTextChanged: root.setLabel(deskRow.modelData.i, text)
            onActiveFocusChanged: root.editing = activeFocus
            Keys.onEscapePressed: keyCatcher.forceActiveFocus()
          }

          // Open windows as icons, with the workspaces on the right. Hover an
          // icon for the window's title.
          Item {
            id: infoLine
            anchors.left: nameField.left
            anchors.right: nameField.right
            anchors.top: nameField.bottom
            anchors.topMargin: root.sp(4)
            implicitHeight: root.sp(23)
            height: implicitHeight

            readonly property var windows: root.windowsOfDesk(deskRow.modelData.i + 1)
            readonly property int shown: Math.min(windows.length, 8)

            Text {
              id: infoText
              anchors.right: parent.right
              anchors.rightMargin: root.sp(2)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.workspaceText(deskRow.modelData.i + 1)
              color: root.barForeground
              opacity: 0.5
              font.family: Style.font.family
              font.pixelSize: root.fontCaption
            }

            Text {
              visible: infoLine.windows.length === 0
              anchors.left: parent.left
              anchors.leftMargin: root.sp(2)
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: "No windows"
              color: root.barForeground
              opacity: 0.45
              font.family: Style.font.family
              font.pixelSize: root.fontCaption
            }

            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: root.sp(5)

              Repeater {
                model: infoLine.windows.slice(0, infoLine.shown)

                Image {
                  id: appIcon
                  required property var modelData
                  width: root.sp(21)
                  height: root.sp(21)
                  sourceSize: Qt.size(width * 2, height * 2)
                  fillMode: Image.PreserveAspectFit
                  smooth: true
                  source: root.iconFor(modelData.appId)

                  MouseArea {
                    id: iconMouse
                    anchors.fill: parent
                    hoverEnabled: true
                  }

                  PanelToolTip {
                    visible: iconMouse.containsMouse
                    text: appIcon.modelData.title !== "" ? appIcon.modelData.title : appIcon.modelData.appId
                    fontFamily: Style.font.family
                  }
                }
              }

              Text {
                visible: infoLine.windows.length > infoLine.shown
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: "+" + (infoLine.windows.length - infoLine.shown)
                color: root.barForeground
                opacity: 0.6
                font.family: Style.font.family
                font.pixelSize: root.fontCaption
              }
            }
          }
        }
      }
    }

    Caption { width: parent.width; text: "Blank falls back to D1..D" + root.pDesktops + "." }

    PanelSeparator { foreground: root.barForeground }
    Item {
      width: parent.width
      implicitHeight: Math.max(monitorsLabel.implicitHeight, identifyButton.implicitHeight)

      SectionLabel { id: monitorsLabel; icon: ""; text: "MONITORS"; anchors.verticalCenter: parent.verticalCenter }

      Rectangle {
        id: identifyButton
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        implicitWidth: identifyText.implicitWidth + root.sp(16)
        implicitHeight: identifyText.implicitHeight + root.sp(8)
        width: implicitWidth
        height: implicitHeight
        radius: root.sp(5)
        color: identifyMouse.containsMouse ? Util.alpha(root.accent, 0.18) : "transparent"
        border.width: 1
        border.color: identifyMouse.containsMouse ? root.accent : root.tint(0.25)

        Text {
          id: identifyText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: "Identify"
          color: identifyMouse.containsMouse ? root.accent : root.barForeground
          font.family: Style.font.family
          font.pixelSize: root.fontCaption
        }

        MouseArea {
          id: identifyMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.identify()
        }

        PanelToolTip {
          visible: identifyMouse.containsMouse
          text: "Show each monitor's name on its screen"
          fontFamily: Style.font.family
        }
      }
    }

    MonitorMap { width: parent.width }
  }

  // The monitors to scale, as they sit on the desk, each with the workspace
  // it shows on the desktop you are on. The one with focus is outlined.
  component MonitorMap: Rectangle {
    id: map
    readonly property var mons: root.detected
    readonly property int pad: root.sp(8)

    height: root.sp(124)
    radius: root.sp(7)
    color: root.tint(0.03)
    border.width: 1
    border.color: root.tint(0.1)
    visible: mons.length > 0

    readonly property var frame: {
      var list = map.mons
      if (!list || list.length === 0) return { scale: 1, ox: 0, oy: 0, x0: 0, y0: 0 }
      var x0 = list[0].x, y0 = list[0].y, x1 = x0, y1 = y0
      for (var i = 0; i < list.length; i++) {
        x0 = Math.min(x0, list[i].x); y0 = Math.min(y0, list[i].y)
        x1 = Math.max(x1, list[i].x + list[i].width); y1 = Math.max(y1, list[i].y + list[i].height)
      }
      var scale = Math.min((map.width - 2 * map.pad) / (x1 - x0), (map.height - 2 * map.pad) / (y1 - y0))
      return {
        scale: scale, x0: x0, y0: y0,
        ox: (map.width - (x1 - x0) * scale) / 2,
        oy: (map.height - (y1 - y0) * scale) / 2
      }
    }

    Repeater {
      model: map.mons

      Rectangle {
        id: tile
        required property var modelData
        readonly property bool focused: Hyprland.focusedMonitor !== null
          && Hyprland.focusedMonitor.name === modelData.name
        readonly property int ws: root.workspaceOnMonitor(modelData.name)
        x: map.frame.ox + (modelData.x - map.frame.x0) * map.frame.scale + 1
        y: map.frame.oy + (modelData.y - map.frame.y0) * map.frame.scale + 1
        width: modelData.width * map.frame.scale - 2
        height: modelData.height * map.frame.scale - 2
        radius: root.sp(4)
        color: focused ? Util.alpha(root.accent, 0.14) : root.tint(0.07)
        border.width: focused ? 2 : 1
        border.color: focused ? root.accent : root.tint(0.3)

        Column {
          anchors.centerIn: parent
          spacing: root.sp(1)

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: tile.modelData.name
            color: tile.focused ? root.accent : root.barForeground
            font.family: Style.font.family
            font.pixelSize: root.fontSmall
            font.bold: true
          }

          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            textFormat: Text.PlainText
            text: tile.modelData.width + "\u00d7" + tile.modelData.height
            color: root.barForeground
            opacity: 0.6
            font.family: Style.font.family
            font.pixelSize: root.fontCaption
          }
        }
      }
    }
  }

  component KeybindsPage: Column {
    width: parent.width
    spacing: root.sp(10)

    SectionLabel { icon: ""; text: "SWITCH KEYS" }

    Column {
      width: parent.width
      spacing: root.sp(5)

      KeyEditor { width: parent.width; which: "toggle"; label: "Next desktop" }
      KeyEditor { width: parent.width; which: "send"; label: "Send window" }
    }

    Caption {
      width: parent.width
      visible: root.keyError === ""
      text: "Click a row to change its keys."
    }

    Text {
      width: parent.width
      visible: root.keyError !== ""
      textFormat: Text.PlainText
      text: root.keyError
      wrapMode: Text.WordWrap
      color: root.bar ? root.bar.urgent : Color.urgent
      font.family: Style.font.family
      font.pixelSize: root.fontCaption
    }

    PanelSeparator { foreground: root.barForeground }
    SectionLabel { icon: ""; text: "EXTRA BINDS"; tag: "REQUIRES APPLY" }

    Column {
      width: parent.width
      spacing: root.sp(7)

      SettingSwitch {
        width: parent.width
        label: "Jump with SUPER + 1.." + root.pDesktops
        checked: root.pNumbers
        onToggled: root.pNumbers = !root.pNumbers
      }

      SettingSwitch {
        width: parent.width
        label: "SUPER + TAB cycles"
        checked: root.pTab
        onToggled: root.pTab = !root.pTab
      }

      SettingSwitch {
        width: parent.width
        label: "SUPER + scroll cycles"
        checked: root.pScroll
        onToggled: root.pScroll = !root.pScroll
      }
    }

    PanelSeparator { foreground: root.barForeground }
    SectionLabel { icon: "\uf245"; text: "MOUSE" }

    SettingSwitch {
      width: parent.width
      label: "Click a desktop to go to it"
      checked: root.clickToSwitch
      onToggled: root.setDisplay("clickToSwitch", !root.clickToSwitch)
    }

    PanelSeparator { foreground: root.barForeground }

    Rectangle {
      width: parent.width
      implicitHeight: wizardText.implicitHeight + root.sp(18)
      radius: root.sp(7)
      color: wizardMouse.containsMouse ? Util.alpha(root.accent, 0.12) : root.tint(0.05)
      border.width: 1
      border.color: wizardMouse.containsMouse ? Util.alpha(root.accent, 0.45) : root.tint(0.1)

      Text {
        id: wizardText
        anchors.left: parent.left
        anchors.leftMargin: root.sp(10)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: "  Re-run setup wizard"
        color: wizardMouse.containsMouse ? root.accent : root.barForeground
        font.family: Style.font.family
        font.pixelSize: root.fontBody
      }

      Text {
        anchors.right: parent.right
        anchors.rightMargin: root.sp(10)
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: ""
        color: root.barForeground
        opacity: 0.55
        font.family: Style.font.family
        font.pixelSize: root.fontSmall
      }

      MouseArea {
        id: wizardMouse
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.runSetup()
      }
    }
  }

  component StylingPage: Column {
    width: parent.width
    spacing: root.sp(9)

    SectionLabel { icon: ""; text: "DENSITY" }

    Segmented {
      width: parent.width
      columns: 3
      choices: [
        { value: "compact", label: "Compact" },
        { value: "normal", label: "Normal" },
        { value: "roomy", label: "Roomy" }
      ]
      selected: root.density
      onPicked: function(value) { root.setDisplay("density", value) }
    }

    SectionLabel { icon: ""; text: "FONT SIZE" }

    Segmented {
      width: parent.width
      columns: 3
      choices: [
        { value: "small", label: "Small" },
        { value: "normal", label: "Normal" },
        { value: "large", label: "Large" }
      ]
      selected: root.fontSize
      onPicked: function(value) { root.setDisplay("fontSize", value) }
    }

    SectionLabel { icon: "\uf1fb"; text: "ACCENT" }

    AccentPicker { width: parent.width }

    SectionLabel { icon: "\uf0ca"; text: "BAR INDICATOR" }

    Segmented {
      width: parent.width
      columns: 2
      choices: [
        { value: "boxes", label: "Boxes" },
        { value: "text", label: "Text" }
      ]
      selected: root.indicator
      onPicked: function(value) { root.setDisplay("indicator", value) }
    }

    SettingSwitch {
      width: parent.width
      label: "Line after the indicator"
      checked: root.divider
      onToggled: root.setDisplay("divider", !root.divider)
    }

    SettingSwitch {
      width: parent.width
      label: "Show open windows"
      checked: root.windowIcons
      onToggled: root.setDisplay("windowIcons", !root.windowIcons)
    }

    PanelSeparator { foreground: root.barForeground }
    SectionLabel { icon: ""; text: "SWITCH MODE"; tag: "REQUIRES APPLY" }

    // Which way the monitors sit, so the switch moves the right way.
    Row {
      width: parent.width
      spacing: root.sp(6)

      Repeater {
        model: [
          { value: "horizontal", label: "Side by side", note: "Horizontal" },
          { value: "vertical", label: "Stacked", note: "Vertical" }
        ]

        Rectangle {
          id: modeCard
          required property var modelData
          readonly property bool chosen: root.pMode === modelData.value
          width: (parent.width - root.sp(6)) / 2
          implicitHeight: modeContent.implicitHeight + root.sp(14)
          radius: root.sp(7)
          color: chosen ? Util.alpha(root.accent, 0.12) : (modeMouse.containsMouse ? root.tint(0.09) : root.tint(0.05))
          border.width: chosen ? 2 : 1
          border.color: chosen ? root.accent : root.tint(0.12)

          Row {
            id: modeContent
            anchors.centerIn: parent
            spacing: root.sp(8)

            // Two little screens, laid out the way the mode describes.
            Item {
              width: root.sp(26)
              height: root.sp(22)
              anchors.verticalCenter: parent.verticalCenter

              Repeater {
                model: 2

                Rectangle {
                  required property int index
                  readonly property bool wide: modeCard.modelData.value === "horizontal"
                  x: wide ? index * (parent.width / 2 + root.sp(1)) : 0
                  y: wide ? 0 : index * (parent.height / 2 + root.sp(1))
                  width: wide ? parent.width / 2 - root.sp(1) : parent.width
                  height: wide ? parent.height : parent.height / 2 - root.sp(1)
                  radius: root.sp(2)
                  color: modeCard.chosen ? Util.alpha(root.accent, 0.35) : root.tint(0.12)
                  border.width: 1
                  border.color: modeCard.chosen ? root.accent : root.tint(0.35)
                }
              }
            }

            Column {
              anchors.verticalCenter: parent.verticalCenter
              spacing: root.sp(1)

              Text {
                textFormat: Text.PlainText
                text: modeCard.modelData.label
                color: modeCard.chosen ? root.accent : root.barForeground
                font.family: Style.font.family
                font.pixelSize: root.fontSmall
                font.bold: true
              }

              Text {
                textFormat: Text.PlainText
                text: modeCard.modelData.note
                color: root.barForeground
                opacity: 0.55
                font.family: Style.font.family
                font.pixelSize: root.fontCaption
              }
            }
          }

          MouseArea {
            id: modeMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.pMode = modeCard.modelData.value
          }
        }
      }
    }

    SectionLabel { icon: ""; text: "TRANSITION"; tag: "REQUIRES APPLY" }

    Segmented {
      width: parent.width
      columns: 2
      choices: root.effectChoices
      selected: root.pEffect
      onPicked: function(value) { root.pEffect = value }
    }

    PanelSeparator { foreground: root.barForeground }
    SectionLabel { icon: ""; text: "POPUP" }

    SettingSwitch {
      width: parent.width
      label: "Show a pager when switching"
      checked: root.popup
      onToggled: root.setDisplay("popup", !root.popup)
    }
  }

  // ===================== pieces =====================

  // Icon, uppercase title, and an optional tag on the right.
  component SectionLabel: Item {
    id: section
    property string icon: ""
    property string text: ""
    property string tag: ""

    width: parent ? parent.width : implicitWidth
    implicitHeight: Math.max(sectionTitle.implicitHeight, sectionIcon.implicitHeight)

    Text {
      id: sectionIcon
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: root.sp(20)
      textFormat: Text.PlainText
      text: section.icon
      color: root.barForeground
      opacity: 0.65
      font.family: Style.font.family
      font.pixelSize: root.fontBody
    }

    Text {
      id: sectionTitle
      anchors.left: sectionIcon.right
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: section.text
      color: root.barForeground
      font.family: Style.font.family
      font.pixelSize: root.fontSmall
      font.bold: true
      font.letterSpacing: 1.2
    }

    Text {
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: section.tag
      color: root.barForeground
      opacity: 0.4
      font.family: Style.font.family
      font.pixelSize: root.fontCaption
      font.letterSpacing: 0.8
    }
  }

  component Caption: Text {
    color: root.barForeground
    opacity: 0.45
    wrapMode: Text.WordWrap
    font.family: Style.font.family
    font.pixelSize: root.fontCaption
  }

  // A label on the left and a row of key caps on the right: "SUPER + F".
  component KeyRow: Rectangle {
    id: keyRow
    property string label: ""
    property string spec: ""
    property bool open: false
    signal clicked()
    readonly property var parts: root.keyParts(spec)

    // A long combination does not fit beside its label; the caps then drop
    // to a second line under it.
    readonly property bool wrapped:
      keyLabel.implicitWidth + capsRow.implicitWidth + root.sp(30) > width
    implicitHeight: wrapped
      ? keyLabel.implicitHeight + capsRow.implicitHeight + root.sp(20)
      : capsRow.implicitHeight + root.sp(14)
    radius: root.sp(7)
    color: open ? Util.alpha(root.accent, 0.1) : (rowMouse.containsMouse ? root.tint(0.09) : root.tint(0.05))
    border.width: 1
    border.color: open ? Util.alpha(root.accent, 0.45) : root.tint(0.1)

    MouseArea {
      id: rowMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: keyRow.clicked()
    }

    Text {
      id: keyLabel
      anchors.left: parent.left
      anchors.leftMargin: root.sp(10)
      anchors.top: keyRow.wrapped ? parent.top : undefined
      anchors.topMargin: root.sp(7)
      anchors.verticalCenter: keyRow.wrapped ? undefined : parent.verticalCenter
      textFormat: Text.PlainText
      text: keyRow.label
      color: root.barForeground
      font.family: Style.font.family
      font.pixelSize: root.fontBody
    }

    Row {
      id: capsRow
      anchors.right: parent.right
      anchors.rightMargin: root.sp(8)
      anchors.bottom: keyRow.wrapped ? parent.bottom : undefined
      anchors.bottomMargin: root.sp(7)
      anchors.verticalCenter: keyRow.wrapped ? undefined : parent.verticalCenter
      spacing: root.sp(4)

      Repeater {
        model: keyRow.parts

        Row {
          id: capGroup
          required property string modelData
          required property int index
          spacing: root.sp(4)

          Text {
            visible: capGroup.index > 0
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "+"
            color: root.barForeground
            opacity: 0.45
            font.family: Style.font.family
            font.pixelSize: root.fontSmall
          }

          Rectangle {
            width: Math.max(root.sp(22), capText.implicitWidth + root.sp(14))
            height: capText.implicitHeight + root.sp(8)
            radius: root.sp(5)
            color: root.tint(0.08)
            border.width: 1
            border.color: root.tint(0.28)

            Text {
              id: capText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: capGroup.modelData
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: root.fontSmall
            }
          }
        }
      }
    }
  }

  // A key row that opens into an editor: modifier buttons, and a button that
  // waits for the plain key. The edit is staged like the rest.
  component KeyEditor: Column {
    id: editor
    property string which: ""
    property string label: ""
    readonly property string spec: which === "toggle" ? root.pToggle : root.pSend
    readonly property bool open: root.keyEdit === which
    readonly property bool changed: which === "toggle" ? root.pToggle !== root.toggleKey : root.pSend !== root.sendKey

    spacing: root.sp(4)

    KeyRow {
      width: parent.width
      label: editor.label + (editor.changed ? " \u2022" : "")
      spec: editor.spec
      open: editor.open
      onClicked: {
        root.capturing = false
        root.keyError = ""
        root.keyEdit = editor.open ? "" : editor.which
      }
    }

    Rectangle {
      width: parent.width
      visible: editor.open
      implicitHeight: editorBody.implicitHeight + root.sp(16)
      radius: root.sp(7)
      color: root.tint(0.03)
      border.width: 1
      border.color: root.tint(0.1)

      Column {
        id: editorBody
        anchors.fill: parent
        anchors.margins: root.sp(8)
        spacing: root.sp(7)

        Row {
          spacing: root.sp(5)

          Repeater {
            model: root.modifierNames

            Rectangle {
              id: modChip
              required property string modelData
              readonly property bool on: root.keyModifiers(editor.spec).indexOf(modelData) >= 0
              width: modText.implicitWidth + root.sp(16)
              height: modText.implicitHeight + root.sp(10)
              radius: root.sp(5)
              color: on ? Util.alpha(root.accent, 0.15) : (modMouse.containsMouse ? root.tint(0.1) : root.tint(0.05))
              border.width: on ? 2 : 1
              border.color: on ? root.accent : root.tint(0.2)

              Text {
                id: modText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: modChip.modelData
                color: modChip.on ? root.accent : root.barForeground
                font.family: Style.font.family
                font.pixelSize: root.fontSmall
                font.bold: modChip.on
              }

              MouseArea {
                id: modMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.toggleModifier(editor.which, modChip.modelData)
              }
            }
          }
        }

        Item {
          width: parent.width
          implicitHeight: keyButton.implicitHeight

          Text {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: "Key"
            color: root.barForeground
            opacity: 0.7
            font.family: Style.font.family
            font.pixelSize: root.fontSmall
          }

          Rectangle {
            id: keyButton
            anchors.right: parent.right
            implicitWidth: keyButtonText.implicitWidth + root.sp(22)
            implicitHeight: keyButtonText.implicitHeight + root.sp(10)
            width: Math.max(implicitWidth, root.sp(110))
            height: implicitHeight
            radius: root.sp(5)
            color: root.capturing ? Util.alpha(root.accent, 0.15) : (keyMouse.containsMouse ? root.tint(0.1) : root.tint(0.06))
            border.width: root.capturing ? 2 : 1
            border.color: root.capturing ? root.accent : root.tint(0.28)

            Text {
              id: keyButtonText
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: root.capturing ? "Press a key..." : root.keyBase(editor.spec)
              color: root.capturing ? root.accent : root.barForeground
              font.family: Style.font.family
              font.pixelSize: root.fontSmall
              font.bold: !root.capturing
            }

            MouseArea {
              id: keyMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                root.keyError = ""
                root.capturing = true
                keyKeeper.forceActiveFocus()
              }
            }
          }
        }
      }
    }
  }

  // Round -/+ button for the desktop count; accent under the pointer, dim at
  // the limit.
  component StepButton: Rectangle {
    id: step
    property string iconText: ""
    property string tooltipText: ""
    property bool active: true
    signal clicked()

    implicitWidth: root.sp(26)
    implicitHeight: root.sp(26)
    radius: root.sp(7)
    color: stepMouse.containsMouse && step.active ? Util.alpha(root.accent, 0.2) : root.tint(0.06)
    border.width: 1
    border.color: stepMouse.containsMouse && step.active ? root.accent : root.tint(0.25)
    opacity: step.active ? 1.0 : 0.4

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: step.iconText
      color: stepMouse.containsMouse && step.active ? root.accent : root.barForeground
      font.family: Style.font.family
      font.pixelSize: root.fontSmall
    }

    MouseArea {
      id: stepMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: step.active ? Qt.PointingHandCursor : Qt.ArrowCursor
      onClicked: step.clicked()
    }

    PanelToolTip {
      visible: stepMouse.containsMouse
      text: step.tooltipText
      fontFamily: Style.font.family
    }
  }

  // Boxed choices in an even grid; the chosen one is outlined and tinted in
  // the accent. choices: [{ value, label }].
  component Segmented: Grid {
    id: segmented
    property var choices: []
    property var selected
    signal picked(var value)

    spacing: root.sp(6)
    readonly property real cellWidth: (width - (columns - 1) * spacing) / columns

    Repeater {
      model: segmented.choices

      Rectangle {
        id: choice
        required property var modelData
        readonly property bool chosen: segmented.selected === modelData.value
        width: segmented.cellWidth
        implicitHeight: choiceText.implicitHeight + root.sp(12)
        radius: root.sp(7)
        color: chosen ? Util.alpha(root.accent, 0.12) : (choiceMouse.containsMouse ? root.tint(0.09) : root.tint(0.05))
        border.width: chosen ? 2 : 1
        border.color: chosen ? root.accent : root.tint(0.12)

        Text {
          id: choiceText
          anchors.centerIn: parent
          textFormat: Text.PlainText
          text: choice.modelData.label
          color: choice.chosen ? root.accent : root.barForeground
          font.family: Style.font.family
          font.pixelSize: root.fontSmall
          font.bold: choice.chosen
        }

        MouseArea {
          id: choiceMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: segmented.picked(choice.modelData.value)
        }
      }
    }
  }

  // The theme's own accent, then the other colours of its palette, each drawn
  // in its real colour. The chosen one is ringed.
  component AccentPicker: Flow {
    id: picker
    spacing: root.sp(5)

    readonly property var choices: ["theme"].concat(accentSource.available)

    Repeater {
      model: picker.choices

      Rectangle {
        id: swatch
        required property string modelData
        readonly property bool chosen: root.accentChoice === modelData
        readonly property bool isTheme: modelData === "theme"
        width: isTheme ? themeLabel.implicitWidth + root.sp(30) : root.sp(23)
        height: root.sp(23)
        radius: height / 2
        color: isTheme ? root.tint(0.06) : accentSource.colorOf(modelData)
        border.width: chosen ? 2 : 1
        border.color: chosen ? root.barForeground : root.tint(isTheme ? 0.25 : 0.15)

        // The theme entry is a pill with a dot in the theme's accent.
        Rectangle {
          visible: swatch.isTheme
          anchors.left: parent.left
          anchors.leftMargin: root.sp(7)
          anchors.verticalCenter: parent.verticalCenter
          width: root.sp(11)
          height: width
          radius: width / 2
          color: Color.accent
        }

        Text {
          id: themeLabel
          visible: swatch.isTheme
          anchors.right: parent.right
          anchors.rightMargin: root.sp(8)
          anchors.verticalCenter: parent.verticalCenter
          textFormat: Text.PlainText
          text: "Theme"
          color: root.barForeground
          font.family: Style.font.family
          font.pixelSize: root.fontSmall
          font.bold: swatch.chosen
        }

        MouseArea {
          id: swatchMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: root.setAccent(swatch.modelData)
        }

        PanelToolTip {
          visible: swatchMouse.containsMouse
          text: swatch.isTheme ? "Theme accent" : swatch.modelData.charAt(0).toUpperCase() + swatch.modelData.slice(1)
          fontFamily: Style.font.family
        }
      }
    }
  }

  // A labelled on/off switch row; the whole row takes the click.
  component SettingSwitch: Item {
    id: settingRow
    property string label: ""
    property bool checked: false
    signal toggled()

    implicitHeight: Math.max(settingLabel.implicitHeight, settingToggle.implicitHeight)

    Text {
      id: settingLabel
      anchors.left: parent.left
      anchors.right: settingToggle.left
      anchors.rightMargin: root.sp(8)
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: settingRow.label
      color: root.barForeground
      font.family: Style.font.family
      font.pixelSize: root.fontBody
      elide: Text.ElideRight
    }

    AccentSwitch {
      id: settingToggle
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      checked: settingRow.checked
    }

    MouseArea {
      anchors.fill: parent
      cursorShape: Qt.PointingHandCursor
      onClicked: settingRow.toggled()
    }
  }

  // On/off switch in the theme accent: accent track and knob when on, a dim
  // neutral track when off. Presentation only; its row owns the click.
  component AccentSwitch: Item {
    id: sw
    property bool checked: false

    implicitWidth: root.sp(34)
    implicitHeight: root.sp(18)

    Rectangle {
      anchors.fill: parent
      radius: height / 2
      color: sw.checked ? Util.alpha(root.accent, 0.3) : Util.alpha(root.barForeground, 0.1)
      border.width: 1
      border.color: sw.checked ? root.accent : Util.alpha(root.barForeground, 0.25)
      Behavior on color { ColorAnimation { duration: 120 } }

      Rectangle {
        width: parent.height - root.sp(6)
        height: width
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        x: sw.checked ? parent.width - width - root.sp(3) : root.sp(3)
        color: sw.checked ? root.accent : Qt.darker(root.barForeground, 1.4)
        Behavior on x { NumberAnimation { duration: 120 } }
        Behavior on color { ColorAnimation { duration: 120 } }
      }
    }
  }
}
