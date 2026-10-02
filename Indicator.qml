import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "videinfra.tandem"

  // Desktops are laid out one workspace per monitor, so both counts fall out
  // of Hyprland's own state and nothing has to be duplicated from tandem.lua.
  readonly property int monitorCount: Math.max(1, Hyprland.monitors.values.length)

  // Prefer the configured count; fall back to inferring it from the workspaces
  // Hyprland actually has, so the widget is still right before first setup.
  // Hyprland is the source of truth: persistent workspace rules guarantee
  // exactly desktops x monitors workspaces exist, and this updates live.
  // Injected `settings` does not -- the bar only re-injects when it rebuilds
  // the widget, so settings.desktops goes stale the moment the count changes
  // and would pin the bar to the old number until a shell restart.
  readonly property int deskCount: {
    var highest = 0
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id > highest) highest = values[i].id
    }
    if (highest > 0) return Math.max(1, Math.ceil(highest / monitorCount))
    return (settings && settings.desktops > 0) ? settings.desktops : 1
  }

  readonly property int desk: Hyprland.focusedWorkspace === null
    ? 1
    : Math.max(1, Math.ceil(Hyprland.focusedWorkspace.id / monitorCount))

  // The popup's on/off switch and the animation style are read from
  // shell.json directly. Injected `settings` only refreshes when the bar
  // rebuilds the widget, so neither would follow a change made in the panel
  // until a shell restart; the file is watched, as the shell does itself.
  property bool popupOn: false
  property string animation: "slide"
  property var popupLabels: []
  property string mode: ""
  // "boxes" draws each desktop in a rounded box, "text" is the plain labels
  // with the current one in the accent colour.
  property string indicatorStyle: "boxes"
  // A thin line after the last desktop, setting them apart from what follows.
  property bool divider: false
  // Small app icons after each desktop's name, for what is open on it.
  property bool windowIcons: false
  // Which colour to highlight with: "theme" or a palette name.
  property string accentChoice: "theme"
  // Clicking a desktop in the bar goes to it. On unless switched off.
  property bool clickToSwitch: true

  FileView {
    id: liveConfig
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.readLive(text())
    onFileChanged: reload()
  }

  function readLive(text) {
    try {
      var layout = (JSON.parse(text).bar || {}).layout || {}
      var sections = ["left", "center", "right"]
      for (var i = 0; i < sections.length; i++) {
        var entries = layout[sections[i]] || []
        for (var j = 0; j < entries.length; j++) {
          var e = entries[j]
          if (e && e.id === "videinfra.tandem" && e.role !== "settings") {
            root.popupOn = e.popup === true
            root.animation = e.animation || "slide"
            root.liveLabels = e.labels || []
            root.popupLabels = root.liveLabels
            root.mode = e.mode || ""
            root.indicatorStyle = e.indicator === "text" ? "text" : "boxes"
            root.divider = e.divider === true
            root.windowIcons = e.windowIcons === true
            root.accentChoice = e.accent || "theme"
            root.clickToSwitch = e.clickToSwitch !== false
            return
          }
        }
      }
    } catch (err) {}
  }

  // Desktop the popup last reported, and a short settle so a switch that
  // takes two hops (or is corrected a moment later) reports once.
  property int lastDesk: -1
  // The way the monitors are arranged. A saved mode wins; otherwise it comes
  // from the animation style, which only the vertical styles name.
  readonly property bool popupVertical: root.mode !== ""
    ? root.mode === "vertical"
    : (animation === "slidevert" || animation === "slidefadevert")

  onDeskChanged: settleTimer.restart()
  Component.onCompleted: settleTimer.restart()

  Timer {
    id: settleTimer
    interval: 80
    onTriggered: {
      // Hyprland is not up yet right after a shell restart.
      if (Hyprland.focusedWorkspace === null) { restart(); return }
      var previous = root.lastDesk
      root.lastDesk = root.desk
      if (previous < 1 || previous === root.desk) return
      if (popupLoader.item) popupLoader.item.show(previous, root.desk, root.direction(previous, root.desk))
    }
  }

  // Which way a switch moved. Stepping forward past the last desktop wraps to
  // the first, which still reads as "next"; with two desktops, or a jump by
  // number, it is simply lower to higher.
  function direction(from, to) {
    var n = root.deskCount
    if (n > 2) {
      var forward = (to - from + n) % n
      if (forward === 1) return 1
      if (forward === n - 1) return -1
    }
    return to > from ? 1 : -1
  }

  Loader {
    id: popupLoader
    active: root.popupOn && root.configured
    sourceComponent: DesktopPopup {
      screen: root.QsWindow.window ? root.QsWindow.window.screen : null
      count: root.deskCount
      labels: root.popupLabels
      accent: root.accent
      vertical: root.popupVertical
    }
  }

  TandemAccent {
    id: accentSource
    choice: root.accentChoice
  }

  readonly property color accent: accentSource.value

  WindowIcons {
    id: windowData
    monitorCount: root.monitorCount
    appLibrary: root.bar && root.bar.shell ? root.bar.shell.appLibrary : null
  }

  // How many app icons one desktop shows before "+N". Not on a vertical bar,
  // where there is no room beside the name.
  readonly property int maxIcons: 3
  readonly property bool showIcons: root.windowIcons && !root.vertical

  function showDesk(index) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("tandem_show(" + index + ")"))
  }

  // Custom names if the user set any, else the D1..Dn default. A short list
  // only names the desktops it covers; the rest keep their default. Read from
  // the watched shell.json so a rename shows without a shell restart, falling
  // back to the injected settings until the file has loaded.
  property var liveLabels: null

  function labelFor(index) {
    var names = root.liveLabels !== null ? root.liveLabels : (settings && settings.labels)
    if (names && index <= names.length && names[index - 1]) return names[index - 1]
    return "D" + index
  }

  function desks() {
    var ids = []
    for (var i = 1; i <= root.deskCount; i++) ids.push(i)
    return ids
  }

  // A fresh `omarchy plugin add` puts this widget in the bar with no Hyprland
  // config behind it. Offer the wizard rather than showing desktops that do
  // not work yet; tandem-config reports whether setup has ever run.
  property bool configured: true
  readonly property string pluginDir:
    Quickshell.env("HOME") + "/.config/omarchy/plugins/videinfra.tandem"

  Process {
    id: probe
    running: true
    command: [root.pluginDir + "/tandem-config", "get"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try { root.configured = JSON.parse(text).configured === true }
        catch (e) { root.configured = true }
      }
    }
  }

  function runSetup() {
    if (!root.bar) return
    root.bar.run("omarchy-launch-tui " + root.pluginDir + "/tandem-setup")
  }

  readonly property bool boxes: root.indicatorStyle === "boxes"
  readonly property real trailingGap: root.vertical || root.boxes ? 0 : Style.spaceReal(1.5)

  // Boxes are a little shorter than the bar so the strip around them reads as
  // the bar's own padding.
  readonly property int boxHeight: Math.round(root.barSize * 0.9)

  // Room taken by the divider line, margins included.
  readonly property real dividerSlot: root.divider ? Style.space(11) : 0

  // Text on the accent fill: black or white by the accent's luminance, so it
  // stays readable whatever the theme's accent is.
  readonly property color onAccent: {
    var c = root.accent
    return (0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b) > 0.5 ? "#101014" : "#ffffff"
  }

  readonly property bool named: {
    var names = root.liveLabels !== null ? root.liveLabels : (settings && settings.labels)
    return !!(names && names.length > 0)
  }

  readonly property real contentWidth: root.boxes ? boxGrid.implicitWidth : textGrid.implicitWidth + trailingGap
  readonly property real contentHeight: root.boxes ? boxGrid.implicitHeight : textGrid.implicitHeight

  // Fill the bar across its thickness, like the buttons beside it, so the
  // boxes sit centred in it rather than at the top.
  implicitWidth: root.configured
    ? (root.vertical ? root.barSize : root.contentWidth + root.dividerSlot)
    : setupButton.implicitWidth
  implicitHeight: root.configured
    ? (root.vertical ? root.contentHeight + root.dividerSlot : root.barSize)
    : setupButton.implicitHeight

  WidgetButton {
    id: setupButton
    visible: !root.configured
    bar: root.bar
    text: "Set up Tandem"
    horizontalMargin: 6
    verticalPadding: 6
    fixedHeight: root.barSize
    onPressed: function() { root.runSetup() }
  }

  // ---- Boxes ----
  GridLayout {
    id: boxGrid
    visible: root.configured && root.boxes
    anchors.fill: parent
    anchors.rightMargin: root.vertical ? 0 : root.dividerSlot
    anchors.bottomMargin: root.vertical ? root.dividerSlot : 0
    columns: root.vertical ? 1 : root.deskCount
    columnSpacing: Style.space(3)
    rowSpacing: Style.space(3)

    Repeater {
      model: root.desks()

      // One rounded box per desktop; the current one is filled with the
      // accent. accent is set by all 22 stock themes, so it is what tracks
      // the theme (WidgetButton's own active colour falls through to a
      // hardcoded urgent red).
      Rectangle {
        id: box
        required property int modelData
        readonly property bool current: root.desk === modelData

        Layout.alignment: Qt.AlignCenter
        Layout.preferredHeight: root.boxHeight
        Layout.preferredWidth: root.vertical
          ? Math.max(root.boxHeight, Math.round(root.barSize * 0.8))
          : Math.max(root.boxHeight, boxContent.implicitWidth + Style.space(3))
        radius: Style.space(5)
        color: current ? root.accent
          : Util.alpha(root.bar ? root.bar.barForeground : Color.foreground, hover.hovered ? 0.18 : 0.09)
        border.width: current ? 0 : 1
        border.color: Util.alpha(root.bar ? root.bar.barForeground : Color.foreground, 0.12)
        Behavior on color { ColorAnimation { duration: 120 } }

        Row {
          id: boxContent
          anchors.centerIn: parent
          spacing: Style.space(3)

          Text {
            id: boxText
            anchors.verticalCenter: parent.verticalCenter
            textFormat: Text.PlainText
            text: root.labelFor(box.modelData)
            color: box.current ? root.onAccent : (root.bar ? root.bar.barForeground : Color.foreground)
            opacity: box.current ? 1 : 0.7
            font.family: Style.font.family
            font.pixelSize: Math.min(Style.font.body, Math.round(root.boxHeight * 0.62))
            font.bold: box.current
          }

          WindowIconRow {
            anchors.verticalCenter: parent.verticalCenter
            desk: box.modelData
            textColor: box.current ? root.onAccent : (root.bar ? root.bar.barForeground : Color.foreground)
          }
        }

        HoverHandler { id: hover; cursorShape: root.clickToSwitch ? Qt.PointingHandCursor : Qt.ArrowCursor }

        // The bar owns the mouse over its slots (it needs it to drag widgets
        // about) and hands a click to whichever registered target is under
        // the pointer, calling triggerPress on it. A box that only listens
        // for taps itself never sees the click, so it registers like
        // WidgetButton does.
        readonly property bool interactive: root.clickToSwitch
        property var registeredBar: null

        function triggerPress(button) {
          if (button === Qt.LeftButton) root.showDesk(box.modelData)
        }

        function syncRegistration() {
          if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(box)
          registeredBar = root.bar
          if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(box)
        }

        Connections {
          target: root
          function onBarChanged() { box.syncRegistration() }
        }
        Component.onCompleted: syncRegistration()
        Component.onDestruction: {
          if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(box)
        }
      }
    }
  }

  // ---- Text ----
  GridLayout {
    id: textGrid
    visible: root.configured && !root.boxes
    anchors.fill: parent
    anchors.rightMargin: (root.vertical ? 0 : root.trailingGap + root.dividerSlot)
    anchors.bottomMargin: root.vertical ? root.dividerSlot : 0
    columns: root.vertical ? 1 : root.deskCount
    // Word labels need more room between them than "D1 D2" does; a single
    // space reads as one run-on string once the names get long.
    columnSpacing: root.vertical ? 0 : Style.space(root.named ? 4 : 1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.desks()

      RowLayout {
        id: textCell
        required property int modelData
        spacing: 0

      WidgetButton {
        id: textButton
        bar: root.bar
        text: root.labelFor(textCell.modelData)
        // Distinguish the current desktop by hue, not just brightness.
        // WidgetButton's activeColor defaults to bar.active, which no stock
        // theme defines -- it falls through to Quickshell's hardcoded urgent
        // red rather than anything in the palette. accent is set by all 22
        // stock themes, so that is the one that actually tracks the theme.
        active: root.desk === textCell.modelData
        activeColor: root.accent
        opacity: root.desk === textCell.modelData ? 1 : 0.55
        horizontalMargin: 6
        verticalPadding: 6
        fixedWidth: root.vertical ? root.barSize : -1
        fixedHeight: root.barSize
        interactive: root.clickToSwitch
        onPressed: function() { root.showDesk(textCell.modelData) }
      }

      WindowIconRow {
        Layout.alignment: Qt.AlignVCenter
        desk: textCell.modelData
        textColor: root.bar ? root.bar.barForeground : Color.foreground
        opacity: root.desk === textCell.modelData ? 1 : 0.55
      }
      }
    }
  }

  // The app icons for one desktop, then "+N" for any beyond the limit.
  component WindowIconRow: Row {
    id: iconRow
    property int desk: 1
    property color textColor: "white"
    readonly property var apps: root.showIcons ? windowData.appsOfDesk(desk) : []
    readonly property int shown: Math.min(apps.length, root.maxIcons)
    readonly property int iconSize: Math.round(root.boxHeight * 0.72)

    visible: apps.length > 0
    spacing: Style.space(2)

    Repeater {
      model: iconRow.apps.slice(0, iconRow.shown)

      Image {
        required property var modelData
        anchors.verticalCenter: parent.verticalCenter
        width: iconRow.iconSize
        height: iconRow.iconSize
        sourceSize: Qt.size(width * 2, height * 2)
        fillMode: Image.PreserveAspectFit
        smooth: true
        source: windowData.iconFor(modelData.appId)
      }
    }

    Text {
      visible: iconRow.apps.length > iconRow.shown
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: "+" + (iconRow.apps.length - iconRow.shown)
      color: iconRow.textColor
      opacity: 0.7
      font.family: Style.font.family
      font.pixelSize: Math.round(root.boxHeight * 0.45)
    }
  }

  // ---- Divider ----
  // A thin line after the last desktop, in the theme accent.
  Rectangle {
    visible: root.configured && root.divider
    readonly property real thickness: Math.max(1, Style.space(1))
    width: root.vertical ? Math.round(root.barSize * 0.5) : thickness
    height: root.vertical ? thickness : Math.round(root.barSize * 0.55)
    radius: thickness / 2
    color: Util.alpha(root.accent, 0.8)
    anchors.right: root.vertical ? undefined : parent.right
    anchors.rightMargin: Style.space(5)
    anchors.verticalCenter: root.vertical ? undefined : parent.verticalCenter
    anchors.bottom: root.vertical ? parent.bottom : undefined
    anchors.horizontalCenter: root.vertical ? parent.horizontalCenter : undefined
  }
}
