import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Commons
import qs.Ui

// On-screen pager shown for a moment after a desktop switch: one square per
// desktop, the current one marked in the accent colour, and an arrow on the
// side the switch moved towards. Horizontal for the sideways animations,
// stacked for the vertical ones.
//
// One of these lives in each bar's indicator, so every monitor shows its own.
// The window is a visual-only overlay: no keyboard focus, and an empty input
// region so clicks pass through it.
Item {
  id: root

  property var screen: null
  property color accent: Color.accent
  property int count: 2
  property var labels: []          // custom desktop names; missing ones read D1..Dn
  property bool vertical: false
  property int duration: 1700

  property bool opened: false
  property int direction: 1        // +1 towards the last desktop, -1 towards the first
  property int target: 1           // the desktop switched to, 1-based
  property int marker: 0           // 0-based square the highlight sits on
  property bool slide: false       // highlight glides only once the card is up

  readonly property int cellH: Style.space(34)
  readonly property int gap: Style.space(8)        // between squares
  readonly property int edge: Style.space(2)       // between the arrow and the squares
  readonly property int arrowSlot: Style.space(20)
  readonly property int pad: Style.space(9)
  // Every square is as wide as the longest name so they line up, and never
  // narrower than it is tall.
  readonly property int cellW: Math.max(root.cellH, Math.ceil(root.widest) + Style.space(22))
  readonly property real widest: {
    var most = 0
    for (var i = 1; i <= root.count; i++)
      most = Math.max(most, names.advanceWidth(root.labelFor(i)))
    return most
  }
  // Squares run along the strip; `lane` is the size across it.
  readonly property int lane: root.vertical ? root.cellW : root.cellH
  readonly property int step: (root.vertical ? root.cellH : root.cellW) + root.gap
  readonly property int run: root.count * (root.vertical ? root.cellH : root.cellW)
    + (root.count - 1) * root.gap

  function labelFor(index) {
    var custom = root.labels
    if (custom && index <= custom.length && custom[index - 1]) return String(custom[index - 1])
    return "D" + index
  }

  FontMetrics {
    id: names
    font.family: Style.font.family
    font.bold: true
    font.pixelSize: Style.font.title
  }
  readonly property string arrowGlyph: root.vertical
    ? (root.direction > 0 ? "" : "")
    : (root.direction > 0 ? "" : "")

  // `from` and `to` are 1-based desktops; `dir` is +1 or -1.
  function show(from, to, dir) {
    root.direction = dir
    root.target = to
    if (root.opened) {
      root.slide = true
      root.marker = to - 1
    } else {
      // Start on the desktop just left, then glide to the new one.
      root.slide = false
      root.marker = from - 1
      root.opened = true
      glideTimer.restart()
    }
    hideTimer.restart()
  }

  Timer {
    id: glideTimer
    interval: 90
    onTriggered: {
      root.slide = true
      root.marker = root.target - 1
    }
  }

  Timer {
    id: hideTimer
    interval: root.duration
    onTriggered: root.opened = false
  }

  PanelWindow {
    id: window
    screen: root.screen
    visible: root.opened || card.opacity > 0.01
    implicitWidth: card.width
    implicitHeight: card.height
    color: "transparent"
    WlrLayershell.namespace: "tandem-popup"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    exclusionMode: ExclusionMode.Ignore
    mask: Region {}

    BorderSurface {
      id: card
      width: card.borderLeft + root.pad + strip.width + root.pad + card.borderRight
      height: card.borderTop + root.pad + strip.height + root.pad + card.borderBottom
      color: Util.alpha(Color.background, 0.97)
      borderSpec: Border.surfaceSpec("popups", "border", Color.popups.border, Math.max(1, Style.space(2)))
      radius: Style.cornerRadius
      opacity: root.opened ? 1 : 0
      Behavior on opacity { NumberAnimation { duration: 140 } }

      // Arrow slot, squares, arrow slot: both slots are always reserved so
      // the card keeps its size whichever way the switch went.
      Item {
        id: strip
        x: card.borderLeft + root.pad
        y: card.borderTop + root.pad
        width: root.vertical ? root.lane : root.arrowSlot * 2 + root.edge * 2 + root.run
        height: root.vertical ? root.arrowSlot * 2 + root.edge * 2 + root.run : root.lane

        Item {
          id: squares
          x: root.vertical ? 0 : root.arrowSlot + root.edge
          y: root.vertical ? root.arrowSlot + root.edge : 0
          width: root.vertical ? root.lane : root.run
          height: root.vertical ? root.run : root.lane

          Repeater {
            model: root.count

            Rectangle {
              required property int index
              x: root.vertical ? 0 : index * root.step
              y: root.vertical ? index * root.step : 0
              width: root.cellW
              height: root.cellH
              radius: Style.space(7)
              color: Util.alpha(Color.popups.text, 0.08)
              border.width: 1
              border.color: Util.alpha(Color.popups.text, 0.25)

              Text {
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: root.labelFor(parent.index + 1)
                color: Color.popups.text
                opacity: 0.6
                font.family: Style.font.family
                font.pixelSize: Style.font.title
              }
            }
          }

          // The marker, on top of the squares so it reads as the current one.
          Rectangle {
            x: root.vertical ? 0 : root.marker * root.step
            y: root.vertical ? root.marker * root.step : 0
            width: root.cellW
            height: root.cellH
            radius: Style.space(7)
            color: Util.alpha(root.accent, 0.3)
            border.width: 2
            border.color: root.accent
            Behavior on x { enabled: root.slide; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            Behavior on y { enabled: root.slide; NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

            Text {
              anchors.centerIn: parent
              textFormat: Text.PlainText
              text: root.labelFor(root.marker + 1)
              color: root.accent
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }
          }
        }

        Text {
          textFormat: Text.PlainText
          text: root.arrowGlyph
          color: root.accent
          font.family: Style.font.family
          font.pixelSize: Style.font.heading
          width: root.vertical ? root.lane : root.arrowSlot
          height: root.vertical ? root.arrowSlot : root.lane
          horizontalAlignment: Text.AlignHCenter
          verticalAlignment: Text.AlignVCenter
          // Towards the last desktop the arrow sits after the squares, towards
          // the first it sits before them.
          x: root.vertical ? 0
             : (root.direction > 0 ? root.arrowSlot + root.edge * 2 + root.run : 0)
          y: root.vertical
             ? (root.direction > 0 ? root.arrowSlot + root.edge * 2 + root.run : 0)
             : 0
        }
      }
    }
  }
}
