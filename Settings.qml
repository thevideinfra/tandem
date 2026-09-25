import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

// Settings panel for videinfra.tandem. Every read and write goes through the
// tandem-config script in the sibling plugin, so validation and file handling
// live in one tested place instead of being reimplemented here.
//
// Desktop, key and animation edits are staged locally and only written when
// Apply is pressed: each write regenerates the Hyprland config and reloads it,
// which is far too disruptive to do on every click while someone is still
// deciding. Density and font size only change this panel, so they save as
// soon as they are picked.
Panel {
  id: root
  moduleName: "videinfra.tandem"
  ipcTarget: "videinfra.tandem"

  readonly property string pluginDir:
    Quickshell.env("HOME") + "/.config/omarchy/plugins/videinfra.tandem"

  // Saved values, as last read from disk.
  property int desktops: 2
  property bool numbers: true
  property bool tabKeys: true
  property bool scrollKeys: true
  property bool separator: false
  property string toggleKey: "SUPER + F"
  property string sendKey: "SUPER + SHIFT + F"
  property string animation: "slide"
  property var detected: []
  property var savedLabels: []   // normalized from disk, one per desktop
  property var pLabels: []       // staged edits
  property var labelSlots: []    // drives the Repeater; reassigned to rebuild it

  // Staged edits.
  property int pDesktops: 2
  property bool pNumbers: true
  property bool pTab: true
  property bool pScroll: true
  property bool pSeparator: false
  property string pAnimation: "slide"

  // Workspace animation styles Hyprland accepts, plus "none" to leave its own
  // workspace animation alone.
  readonly property var animationChoices: [
    { value: "slide", label: "Slide" },
    { value: "slidevert", label: "Slide vertical" },
    { value: "fade", label: "Fade" },
    { value: "slidefade", label: "Slide + fade" },
    { value: "slidefadevert", label: "Slide + fade vertical" },
    { value: "none", label: "Hyprland default" }
  ]

  property bool busy: false
  property string errorText: ""

  // ---- Display settings, set from the gear view ----
  // Same scales as omaudiopanel, so the two panels match side by side.
  property string density: "normal"
  property string fontSize: "normal"
  property bool showMonitors: true
  property bool showKeys: true
  readonly property real densityScale:
    density === "compact" ? 0.61 : (density === "comfortable" ? 0.83 : 0.71)
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
  property bool settingsOpen: false

  // Style.space scaled by the chosen density.
  function sp(px) {
    return Style.space(px * densityScale)
  }

  function setDisplay(key, value) {
    root[key] = value
    Quickshell.execDetached([root.pluginDir + "/tandem-config", "set", key, String(value)])
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

  readonly property bool labelsDirty:
    JSON.stringify(pLabels) !== JSON.stringify(savedLabels)

  readonly property bool dirty: pDesktops !== desktops
    || pNumbers !== numbers || pTab !== tabKeys || pScroll !== scrollKeys
    || pSeparator !== separator || pAnimation !== animation || labelsDirty

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
    pSeparator = separator
    pAnimation = animation
    errorText = ""
  }

  function applyConfig(text) {
    try {
      var data = JSON.parse(text)
      desktops = data.desktops
      numbers = data.numbers === true
      tabKeys = data.tab === true
      scrollKeys = data.scroll === true
      separator = data.separator === true
      toggleKey = data.toggle
      sendKey = data.send
      animation = data.animation || "slide"
      density = data.density || "normal"
      fontSize = data.fontSize || "normal"
      showMonitors = data.showMonitors !== false
      showKeys = data.showKeys !== false
      detected = data.detected || []
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
    if (pSeparator !== separator) patch.separator = pSeparator
    if (pAnimation !== animation) patch.animation = pAnimation
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

  // Re-read on open so the panel never shows values a wizard run has changed,
  // and drop any edits that were staged but never applied. Closing always
  // returns to the main view.
  onOpenedChanged: {
    if (opened) reload()
    else settingsOpen = false
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
    text: "󰕰"   // nf-md-view-grid, solid 2x2
    tooltipText: "Tandem · virtual desktops"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.sp(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onActivateRequested: root.apply()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: root.sp(12)

        // ---------- Header: icon · title/status · gear ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(headerIcon.implicitHeight, headerLabels.implicitHeight, gearButton.implicitHeight)

          Text {
            id: headerIcon
            textFormat: Text.PlainText
            text: "󰕰"
            color: Color.accent
            font.family: Style.font.family
            font.pixelSize: root.fontDisplay
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: headerLabels
            anchors.left: headerIcon.right
            anchors.leftMargin: root.sp(14)
            anchors.right: gearButton.left
            anchors.rightMargin: root.sp(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: root.sp(2)

            Text {
              width: parent.width
              text: "Tandem"
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: root.fontTitle
              font.bold: true
              elide: Text.ElideRight
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: ("Desktop " + root.currentDesk + " of " + root.desktops
                + " · " + root.monitorCount
                + (root.monitorCount === 1 ? " monitor" : " monitors")).toUpperCase()
              color: Qt.darker(root.barForeground, 1.4)
              font.family: Style.font.family
              font.pixelSize: root.fontCaption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
            }
          }

          // Opens the settings view in place of the panel content.
          Text {
            id: gearButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.settingsOpen ? "󰅖" : "󰒓"
            // Larger than the header text and accent on hover, so it reads
            // as a control rather than decoration.
            color: gearMouse.containsMouse || root.settingsOpen ? Color.accent : root.barForeground
            font.family: Style.font.family
            font.pixelSize: Math.round(root.fontTitle * 1.45)
            opacity: gearMouse.containsMouse || root.settingsOpen ? 1.0 : 0.85

            MouseArea {
              id: gearMouse
              anchors.fill: parent
              anchors.margins: -root.sp(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.settingsOpen = !root.settingsOpen
            }

            PanelToolTip {
              visible: gearMouse.containsMouse
              text: root.settingsOpen ? "Close settings" : "Panel settings"
              fontFamily: Style.font.family
            }
          }
        }

        MainView {
          width: parent.width
          visible: !root.settingsOpen
        }

        SettingsView {
          width: parent.width
          visible: root.settingsOpen
        }

        // ---------- apply / revert, shared by both views ----------
        PanelSeparator {
          visible: root.dirty || root.busy
          foreground: root.barForeground
        }

        Item {
          width: parent.width
          visible: root.dirty || root.busy
          implicitHeight: applyLabel.implicitHeight

          Text {
            id: applyLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.busy ? "Applying..." : "\uf0c7  Apply changes"
            color: root.busy ? Qt.darker(root.barForeground, 1.5) : Color.accent
            font.family: Style.font.family
            font.pixelSize: root.fontBody
            font.bold: !root.busy
            opacity: applyMouse.containsMouse || root.busy ? 1.0 : 0.9
          }

          Text {
            id: revertLabel
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: !root.busy
            textFormat: Text.PlainText
            text: "\uf0e2  Revert"
            color: root.barForeground
            opacity: revertMouse.containsMouse ? 1.0 : 0.6
            font.family: Style.font.family
            font.pixelSize: root.fontSmall
          }

          MouseArea {
            id: applyMouse
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.right: revertLabel.visible ? revertLabel.left : parent.right
            anchors.topMargin: -root.sp(4)
            anchors.bottomMargin: -root.sp(4)
            enabled: root.dirty && !root.busy
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.apply()
          }

          MouseArea {
            id: revertMouse
            anchors.fill: revertLabel
            anchors.margins: -root.sp(4)
            enabled: revertLabel.visible
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.revert()
          }
        }

        Text {
          width: parent.width
          visible: root.errorText !== ""
          text: root.errorText
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: Style.font.family
          font.pixelSize: root.fontCaption
        }
      }
    }
  }

  // Desktop count, names and what the keys do.
  component MainView: Column {
    spacing: root.sp(10)

    PanelSeparator { foreground: root.barForeground }

    Item {
      width: parent.width
      implicitHeight: Math.max(desktopsHeader.implicitHeight, stepper.implicitHeight)

      SectionHeader {
        id: desktopsHeader
        anchors.left: parent.left
        anchors.verticalCenter: parent.verticalCenter
        text: "DESKTOPS"
      }

      Row {
        id: stepper
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: root.sp(8)

        StepButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\uf068"
          tooltipText: "One fewer desktop"
          active: root.pDesktops > 1
          onClicked: if (root.pDesktops > 1) root.pDesktops--
        }

        Text {
          anchors.verticalCenter: parent.verticalCenter
          width: root.sp(22)
          horizontalAlignment: Text.AlignHCenter
          text: root.pDesktops
          color: Color.accent
          font.family: Style.font.family
          font.pixelSize: root.fontTitle
          font.bold: true
        }

        StepButton {
          anchors.verticalCenter: parent.verticalCenter
          iconText: "\uf067"
          tooltipText: "One more desktop"
          active: root.pDesktops < 10
          onClicked: if (root.pDesktops < 10) root.pDesktops++
        }
      }
    }

    // One row per desktop. The desktop you are on gets an accent stripe and
    // number, like the device in use in the audio panel.
    Column {
      width: parent.width
      spacing: root.sp(4)

      Repeater {
        model: root.labelSlots

        Item {
          id: nameRow
          required property var modelData
          readonly property bool current: modelData.i + 1 === root.currentDesk
          width: parent.width
          implicitHeight: nameField.implicitHeight

          Rectangle {
            visible: nameRow.current
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(2, root.sp(3))
            height: parent.height - root.sp(6)
            radius: width / 2
            color: Color.accent
          }

          Text {
            id: nameIndex
            anchors.left: parent.left
            anchors.leftMargin: root.sp(10)
            anchors.verticalCenter: parent.verticalCenter
            width: root.sp(24)
            text: modelData.i + 1
            color: nameRow.current ? Color.accent : root.barForeground
            opacity: nameRow.current ? 1.0 : 0.55
            font.family: Style.font.family
            font.pixelSize: root.fontSmall
            font.bold: nameRow.current
          }

          TextField {
            id: nameField
            anchors.left: nameIndex.right
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            placeholderText: root.defaultLabel(modelData.i)
            foreground: root.barForeground
            font.family: Style.font.family
            font.pixelSize: root.fontBody
            verticalPadding: root.sp(5)
            maximumLength: 16

            // Set once rather than bound: a binding would fight the cursor
            // while typing, since editing rewrites the array it reads from.
            Component.onCompleted: text = modelData.initial
            onTextChanged: root.setLabel(modelData.i, text)
          }
        }
      }
    }

    Caption {
      width: parent.width
      text: "Blank falls back to D1..D" + root.pDesktops + "."
    }

    PanelSeparator { visible: root.showMonitors; foreground: root.barForeground }
    SectionHeader { visible: root.showMonitors; text: "MONITORS" }

    Column {
      visible: root.showMonitors
      width: parent.width
      spacing: root.sp(3)

      Repeater {
        model: root.detected

        KeyValue {
          required property var modelData
          required property int index
          width: parent.width
          key: (index + 1) + ". " + modelData.name
          note: root.monitorPosition(index)
          value: modelData.width + "x" + modelData.height
        }
      }
    }

    PanelSeparator { visible: root.showKeys; foreground: root.barForeground }
    SectionHeader { visible: root.showKeys; text: "KEYS" }

    Column {
      visible: root.showKeys
      width: parent.width
      spacing: root.sp(3)

      KeyValue { width: parent.width; key: "Next desktop"; value: root.toggleKey }
      KeyValue { width: parent.width; key: "Send window"; value: root.sendKey }
    }
  }

  // Replaces the main view while the gear is on. Density, font size and the
  // section switches save straight away; the rest is staged for Apply like the main view.
  component SettingsView: Column {
    spacing: root.sp(10)

    PanelSeparator { foreground: root.barForeground }

    Text {
      textFormat: Text.PlainText
      text: "󰁍 Back"
      color: root.barForeground
      font.family: Style.font.family
      font.pixelSize: root.fontSmall
      font.bold: true
      opacity: backMouse.containsMouse ? 1.0 : 0.75

      MouseArea {
        id: backMouse
        anchors.fill: parent
        anchors.margins: -root.sp(4)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.settingsOpen = false
      }
    }

    SectionHeader { text: "DENSITY" }

    ChoiceChips {
      width: parent.width
      choices: [
        { value: "compact", label: "Compact" },
        { value: "normal", label: "Normal" },
        { value: "comfortable", label: "Comfortable" }
      ]
      selected: root.density
      onPicked: function(value) { root.setDisplay("density", value) }
    }

    SectionHeader { text: "FONT SIZE" }

    ChoiceChips {
      width: parent.width
      choices: [
        { value: "small", label: "Small" },
        { value: "normal", label: "Normal" },
        { value: "large", label: "Large" }
      ]
      selected: root.fontSize
      onPicked: function(value) { root.setDisplay("fontSize", value) }
    }

    PanelSeparator { foreground: root.barForeground }
    SectionHeader { text: "SHOW" }

    Column {
      width: parent.width
      spacing: root.sp(6)

      SettingSwitch {
        width: parent.width
        label: "Monitors section"
        checked: root.showMonitors
        onToggled: root.setDisplay("showMonitors", !root.showMonitors)
      }

      SettingSwitch {
        width: parent.width
        label: "Keys section"
        checked: root.showKeys
        onToggled: root.setDisplay("showKeys", !root.showKeys)
      }
    }

    PanelSeparator { foreground: root.barForeground }
    SectionHeader { text: "SHORTCUTS" }

    // The switches sit closer together than the view's sections.
    Column {
      width: parent.width
      spacing: root.sp(6)

      SettingSwitch {
        width: parent.width
        label: "SUPER+1.." + root.pDesktops + " jumps to a desktop"
        checked: root.pNumbers
        onToggled: root.pNumbers = !root.pNumbers
      }

      SettingSwitch {
        width: parent.width
        label: "SUPER+TAB cycles"
        checked: root.pTab
        onToggled: root.pTab = !root.pTab
      }

      SettingSwitch {
        width: parent.width
        label: "SUPER+scroll cycles"
        checked: root.pScroll
        onToggled: root.pScroll = !root.pScroll
      }
    }

    PanelSeparator { foreground: root.barForeground }
    SectionHeader { text: "BAR" }

    SettingSwitch {
      width: parent.width
      label: "Separator between desktops"
      checked: root.pSeparator
      onToggled: root.pSeparator = !root.pSeparator
    }

    PanelSeparator { foreground: root.barForeground }
    SectionHeader { text: "ANIMATION" }

    ChoiceChips {
      width: parent.width
      choices: root.animationChoices
      selected: root.pAnimation
      onPicked: function(value) { root.pAnimation = value }
    }

    Caption {
      width: parent.width
      text: "Match how the monitors are arranged."
    }

    PanelSeparator { foreground: root.barForeground }

    Text {
      textFormat: Text.PlainText
      text: "\uf013  Re-run setup wizard"
      color: setupMouse.containsMouse ? Color.accent : root.barForeground
      font.family: Style.font.family
      font.pixelSize: root.fontBody

      MouseArea {
        id: setupMouse
        anchors.fill: parent
        anchors.margins: -root.sp(4)
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.runSetup()
      }
    }
  }

  component SectionHeader: PanelSectionHeader {
    foreground: root.barForeground
    fontFamily: Style.font.family
    fontSize: root.fontCaption
  }

  component Caption: Text {
    color: root.barForeground
    opacity: 0.45
    wrapMode: Text.WordWrap
    font.family: Style.font.family
    font.pixelSize: root.fontSmall
  }

  // A dim label on the left and its value in the accent on the right.
  // An optional note sits right after the label, at full strength.
  component KeyValue: Item {
    id: kv
    property string key: ""
    property string note: ""
    property string value: ""
    implicitHeight: Math.max(kvKey.implicitHeight, kvValue.implicitHeight)

    Text {
      id: kvKey
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      width: Math.min(implicitWidth,
        kv.width - kvValue.width - kvNote.width - root.sp(16))
      textFormat: Text.PlainText
      text: kv.key
      color: root.barForeground
      opacity: 0.75
      elide: Text.ElideRight
      font.family: Style.font.family
      font.pixelSize: root.fontSmall
    }

    Text {
      id: kvNote
      anchors.left: kvKey.right
      anchors.leftMargin: kv.note !== "" ? root.sp(8) : 0
      anchors.verticalCenter: parent.verticalCenter
      width: kv.note !== "" ? implicitWidth : 0
      textFormat: Text.PlainText
      text: kv.note
      color: root.barForeground
      font.family: Style.font.family
      font.pixelSize: root.fontSmall
      font.bold: true
    }

    Text {
      id: kvValue
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: kv.value
      color: Color.accent
      font.family: Style.font.family
      font.pixelSize: root.fontSmall
      font.bold: true
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

    implicitWidth: root.sp(24)
    implicitHeight: root.sp(24)
    radius: width / 2
    color: stepMouse.containsMouse && step.active ? Util.alpha(Color.accent, 0.2) : "transparent"
    border.width: 1
    border.color: stepMouse.containsMouse && step.active ? Color.accent : Util.alpha(root.barForeground, 0.25)
    opacity: step.active ? 1.0 : 0.4

    Text {
      anchors.centerIn: parent
      textFormat: Text.PlainText
      text: step.iconText
      color: stepMouse.containsMouse && step.active ? Color.accent : root.barForeground
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

  // A wrapping row of text choices; the selected one is accent, bold and
  // underlined. choices: [{ value, label }].
  component ChoiceChips: Flow {
    id: chips
    property var choices: []
    property var selected
    signal picked(var value)

    spacing: root.sp(10)

    Repeater {
      model: chips.choices

      Text {
        required property var modelData
        readonly property bool chosen: chips.selected === modelData.value
        textFormat: Text.PlainText
        text: modelData.label
        color: chosen ? Color.accent : root.barForeground
        font.family: Style.font.family
        font.pixelSize: root.fontSmall
        font.bold: chosen
        font.underline: chosen
        opacity: chosen || chipMouse.containsMouse ? 1.0 : 0.55

        MouseArea {
          id: chipMouse
          anchors.fill: parent
          anchors.margins: -root.sp(3)
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: chips.picked(parent.modelData.value)
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
      color: sw.checked ? Util.alpha(Color.accent, 0.3) : Util.alpha(root.barForeground, 0.1)
      border.width: 1
      border.color: sw.checked ? Color.accent : Util.alpha(root.barForeground, 0.25)
      Behavior on color { ColorAnimation { duration: 120 } }

      Rectangle {
        width: parent.height - root.sp(6)
        height: width
        radius: width / 2
        anchors.verticalCenter: parent.verticalCenter
        x: sw.checked ? parent.width - width - root.sp(3) : root.sp(3)
        color: sw.checked ? Color.accent : Qt.darker(root.barForeground, 1.4)
        Behavior on x { NumberAnimation { duration: 120 } }
        Behavior on color { ColorAnimation { duration: 120 } }
      }
    }
  }
}
