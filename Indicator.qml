import QtQuick
import QtQuick.Layouts
import Quickshell.Hyprland
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

  function showDesk(index) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("tandem_show(" + index + ")"))
  }

  // Custom names if the user set any, else the D1..Dn default. A short list
  // only names the desktops it covers; the rest keep their default.
  function labelFor(index) {
    var names = settings && settings.labels
    if (names && index <= names.length && names[index - 1]) return names[index - 1]
    return "D" + index
  }

  // True once any desktop carries a custom name, which is when the tighter
  // D1/D2 spacing stops being enough.
  // Vertical bars stack the entries, where a "|" between rows reads wrong.
  readonly property bool separatorVisible:
    !root.vertical && !!(settings && settings.separator === true)

  readonly property bool named: {
    var names = settings && settings.labels
    return !!(names && names.length > 0)
  }

  function desks() {
    var ids = []
    for (var i = 1; i <= root.deskCount; i++) ids.push(i)
    return ids
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  implicitWidth: grid.implicitWidth + trailingGap
  implicitHeight: grid.implicitHeight

  GridLayout {
    id: grid
    anchors.fill: parent
    anchors.rightMargin: root.trailingGap
    columns: root.vertical ? 1 : root.deskCount
    // Word labels need more room between them than "D1 D2" does; a single
    // space reads as one run-on string once the names get long.
    columnSpacing: root.vertical ? 0 : Style.space(root.named ? 4 : 1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.desks()

      RowLayout {
        id: cell
        required property int modelData
        spacing: root.separatorVisible ? Style.space(root.named ? 3 : 2) : 0

        WidgetButton {
          bar: root.bar
          text: root.labelFor(cell.modelData)
          // Distinguish the current desktop by hue, not just brightness.
          // WidgetButton's activeColor defaults to bar.active, which no stock
          // theme defines -- it falls through to Quickshell's hardcoded urgent
          // red rather than anything in the palette. accent is set by all 22
          // stock themes, so that is the one that actually tracks the theme.
          active: root.desk === cell.modelData
          activeColor: Color.accent
          opacity: root.desk === cell.modelData ? 1 : 0.55
          horizontalMargin: 6
          verticalPadding: 6
          fixedWidth: root.vertical ? root.barSize : -1
          fixedHeight: root.barSize
          onPressed: function() { root.showDesk(cell.modelData) }
        }

        // muted is a third role every stock theme defines, so the rule stays
        // readable against both the accent-coloured active entry and the
        // dimmed inactive ones.
        Text {
          visible: root.separatorVisible && cell.modelData < root.deskCount
          text: "|"
          color: Color.muted
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          Layout.alignment: Qt.AlignVCenter
        }
      }
    }
  }
}
