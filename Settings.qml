import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Settings panel for videinfra.tandem. Every read and write goes through the
// tandem-config script in the sibling plugin, so validation and file handling
// live in one tested place instead of being reimplemented here.
//
// Edits are staged locally and only written when Apply is pressed: each write
// regenerates the Hyprland config and reloads it, which is far too disruptive
// to do on every click while someone is still deciding.
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
  // workspace animation alone. Clicking the row steps through them.
  readonly property var animations:
    ["slide", "slidevert", "fade", "slidefade", "slidefadevert", "none"]

  readonly property var animationLabels: ({
    "slide": "Slide sideways",
    "slidevert": "Slide up and down",
    "fade": "Fade",
    "slidefade": "Slide and fade sideways",
    "slidefadevert": "Slide and fade vertically",
    "none": "Hyprland default"
  })

  property bool busy: false
  property string errorText: ""

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

  function cycleAnimation(step) {
    var n = root.animations.length
    var i = root.animations.indexOf(root.pAnimation)
    root.pAnimation = root.animations[((i + step) % n + n) % n]
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
  // and drop any edits that were staged but never applied.
  onOpenedChanged: if (opened) reload()

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
    tooltipText: "Tandem \u00b7 virtual desktops"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(340))
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
        spacing: Style.space(10)

        Text {
          text: "Tandem"
          color: root.barForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        PanelSeparator { width: parent.width; foreground: root.barForeground }
        PanelSectionHeader { text: "DESKTOPS"; foreground: root.barForeground }

        Row {
          width: parent.width
          spacing: Style.space(10)

          Text {
            text: root.pDesktops + (root.pDesktops === 1 ? " desktop" : " desktops")
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }

          PanelActionButton {
            iconText: ""
            tooltipText: "One fewer desktop"
            foreground: root.barForeground
            bordered: true
            opacity: root.pDesktops > 1 ? 1 : 0.4
            onClicked: if (root.pDesktops > 1) root.pDesktops--
          }

          PanelActionButton {
            iconText: ""
            tooltipText: "One more desktop"
            foreground: root.barForeground
            bordered: true
            opacity: root.pDesktops < 10 ? 1 : 0.4
            onClicked: if (root.pDesktops < 10) root.pDesktops++
          }
        }

        PanelSeparator { width: parent.width; foreground: root.barForeground }
        PanelSectionHeader { text: "NAMES"; foreground: root.barForeground }

        Repeater {
          model: root.labelSlots

          Item {
            required property var modelData
            width: column.width
            implicitHeight: nameField.implicitHeight

            Text {
              id: nameIndex
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(28)
              text: (modelData.i + 1) + "."
              color: root.barForeground
              opacity: 0.55
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }

            TextField {
              id: nameField
              anchors.left: nameIndex.right
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              placeholderText: root.defaultLabel(modelData.i)
              foreground: root.barForeground
              font.family: Style.font.family
              maximumLength: 16

              // Set once rather than bound: a binding would fight the cursor
              // while typing, since editing rewrites the array it reads from.
              Component.onCompleted: text = modelData.initial
              onTextChanged: root.setLabel(modelData.i, text)
            }
          }
        }

        Text {
          width: parent.width
          text: "Blank falls back to D1..D" + root.pDesktops + ". Press Apply to save."
          color: root.barForeground
          opacity: 0.45
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        PanelSeparator { width: parent.width; foreground: root.barForeground }
        PanelSectionHeader { text: "LAYOUT"; foreground: root.barForeground }

        Repeater {
          model: root.detected
          Text {
            required property var modelData
            required property int index
            width: column.width
            text: (index + 1) + ". " + modelData.name + "   "
              + modelData.width + "x" + modelData.height
            color: root.barForeground
            opacity: 0.75
            elide: Text.ElideRight
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        PanelSeparator { width: parent.width; foreground: root.barForeground }
        PanelSectionHeader { text: "KEYS"; foreground: root.barForeground }

        Text {
          width: parent.width
          text: "Next desktop:  " + root.toggleKey + "\nSend window:  " + root.sendKey
          color: root.barForeground
          opacity: 0.75
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        Repeater {
          model: [
            { key: "numbers", label: "SUPER+1.." + root.pDesktops + " jumps to a desktop", on: root.pNumbers },
            { key: "tab",     label: "SUPER+TAB cycles",                                   on: root.pTab },
            { key: "scroll",  label: "SUPER+scroll cycles",                                on: root.pScroll },
            { key: "separator", label: "Separator between desktops",                        on: root.pSeparator }
          ]

          // A real switch rather than a check/cross glyph: the marks did not
          // read as something you could click. `Toggle` is the labeled kit
          // component, but its 54px rows make the panel far too tall for four
          // of them, so this is the same pairing at panel-row height, with the
          // row owning the click.
          Item {
            required property var modelData
            width: column.width
            implicitHeight: Math.max(rowLabel.implicitHeight, rowSwitch.implicitHeight)
              + Style.space(4)

            Text {
              id: rowLabel
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: rowSwitch.left
              anchors.rightMargin: Style.space(8)
              text: modelData.label
              elide: Text.ElideRight
              color: root.barForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            ToggleSwitch {
              id: rowSwitch
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              checked: modelData.on
              foreground: root.barForeground
              trackHeight: Style.space(18)
              // The row below owns the click, so this is presentation only.
              // The cursor ring still follows the row's hover, since with
              // `interactive` off the switch never sees the pointer itself.
              interactive: false
              cursorRing: true
              hasCursor: rowMouse.containsMouse
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                if (modelData.key === "numbers") root.pNumbers = !root.pNumbers
                else if (modelData.key === "tab") root.pTab = !root.pTab
                else if (modelData.key === "scroll") root.pScroll = !root.pScroll
                else root.pSeparator = !root.pSeparator
              }
            }
          }
        }

        PanelSeparator { width: parent.width; foreground: root.barForeground }
        PanelSectionHeader { text: "ANIMATION"; foreground: root.barForeground }

        // Same shape as the desktop count above: arrows either side of the
        // value, so the row reads as adjustable without having to be clicked
        // to find out.
        Row {
          width: parent.width
          spacing: Style.space(10)

          Text {
            width: parent.width - prevAnim.width - nextAnim.width - Style.space(20)
            text: root.animationLabels[root.pAnimation] || root.pAnimation
            elide: Text.ElideRight
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            anchors.verticalCenter: parent.verticalCenter
          }

          PanelActionButton {
            id: prevAnim
            iconText: "\uf053"
            tooltipText: "Previous animation"
            foreground: root.barForeground
            bordered: true
            onClicked: root.cycleAnimation(-1)
          }

          PanelActionButton {
            id: nextAnim
            iconText: "\uf054"
            tooltipText: "Next animation"
            foreground: root.barForeground
            bordered: true
            onClicked: root.cycleAnimation(1)
          }
        }

        Text {
          width: parent.width
          text: "Pick the direction the monitors are arranged in."
          color: root.barForeground
          opacity: 0.45
          wrapMode: Text.WordWrap
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }

        PanelSeparator { width: parent.width; foreground: root.barForeground }

        // ---------- apply / revert ----------
        Item {
          width: parent.width
          implicitHeight: applyLabel.implicitHeight + Style.space(10)

          Text {
            id: applyLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.busy
              ? "Applying..."
              : (root.dirty ? "  Apply changes" : "No unsaved changes")
            color: root.dirty && !root.busy ? root.barForeground : Qt.darker(root.barForeground, 1.5)
            font.family: Style.font.family
            font.pixelSize: Style.font.body
            font.bold: root.dirty && !root.busy
          }

          Text {
            id: revertLabel
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: root.dirty && !root.busy
            text: "  Revert"
            color: root.barForeground
            opacity: 0.7
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          MouseArea {
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.right: revertLabel.visible ? revertLabel.left : parent.right
            enabled: root.dirty && !root.busy
            cursorShape: Qt.PointingHandCursor
            onClicked: root.apply()
          }

          MouseArea {
            anchors.fill: revertLabel
            enabled: revertLabel.visible
            cursorShape: Qt.PointingHandCursor
            onClicked: root.revert()
          }
        }

        PanelSeparator { width: parent.width; foreground: root.barForeground }

        Item {
          width: parent.width
          implicitHeight: setupLabel.implicitHeight + Style.space(8)

          Text {
            id: setupLabel
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "  Re-run setup wizard"
            color: root.barForeground
            font.family: Style.font.family
            font.pixelSize: Style.font.body
          }

          MouseArea {
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: root.runSetup()
          }
        }

        Text {
          width: parent.width
          visible: root.errorText !== ""
          text: root.errorText
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
