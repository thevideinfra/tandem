import QtQuick
import QtQuick.Shapes
import qs.Commons

// Two monitors joined by a link: the bar icon for the settings panel. Drawn
// on an 18 x 14.5 grid with 1.5-unit strokes so it stays crisp at bar size; a
// glyph traced from the full-size artwork came out with sub-pixel lines.
// Omarchy 4.5 scales every bar icon so its longest side is the same, so the
// drawing is close to square rather than two screens side by side.
// Each screen's inner edge breaks around the link instead of running under it.
Item {
  id: root

  property real iconWidth: Style.space(18)
  property color color: Color.foreground

  readonly property real u: iconWidth / 18

  width: iconWidth
  height: 14.5 * u
  implicitWidth: width
  implicitHeight: height

  Shape {
    anchors.fill: parent
    antialiasing: true
    layer.enabled: true
    layer.samples: 4

    Outline { edge: 7.25; outer: 0.75 }
    Outline { edge: 10.75; outer: 17.25 }

    // The link, overlapping both screens.
    Bar { x0: 5.5; y0: 4.5; x1: 12.5; y1: 6.0 }

    // Stands: a neck and a base under each screen.
    Bar { x0: 3.25; y0: 10.75; x1: 4.75; y1: 13.25 }
    Bar { x0: 1.5; y0: 13.0; x1: 6.5; y1: 14.5 }
    Bar { x0: 13.25; y0: 10.75; x1: 14.75; y1: 13.25 }
    Bar { x0: 11.5; y0: 13.0; x1: 16.5; y1: 14.5 }
  }

  // A screen outline as one open stroke, starting and ending on the inner
  // edge either side of the link. `edge` is the inner side, `outer` the far
  // side; the corners are quarter arcs.
  component Outline: ShapePath {
    property real edge: 0
    property real outer: 0
    readonly property real dir: outer < edge ? -1 : 1
    readonly property real r: 1.5
    readonly property real top: 0.75
    readonly property real bottom: 10.75

    strokeColor: root.color
    strokeWidth: 1.5 * root.u
    fillColor: "transparent"
    capStyle: ShapePath.FlatCap
    joinStyle: ShapePath.RoundJoin

    startX: edge * root.u
    startY: (top + r) * root.u
    PathArc {
      x: (edge + dir * r) * root.u; y: top * root.u
      radiusX: 1.5 * root.u; radiusY: 1.5 * root.u
      direction: dir < 0 ? PathArc.Counterclockwise : PathArc.Clockwise
    }
    PathLine { x: (outer - dir * r) * root.u; y: top * root.u }
    PathArc {
      x: outer * root.u; y: (top + r) * root.u
      radiusX: 1.5 * root.u; radiusY: 1.5 * root.u
      direction: dir < 0 ? PathArc.Counterclockwise : PathArc.Clockwise
    }
    PathLine { x: outer * root.u; y: (bottom - r) * root.u }
    PathArc {
      x: (outer - dir * r) * root.u; y: bottom * root.u
      radiusX: 1.5 * root.u; radiusY: 1.5 * root.u
      direction: dir < 0 ? PathArc.Counterclockwise : PathArc.Clockwise
    }
    PathLine { x: (edge + dir * r) * root.u; y: bottom * root.u }
    PathArc {
      x: edge * root.u; y: (bottom - r) * root.u
      radiusX: 1.5 * root.u; radiusY: 1.5 * root.u
      direction: dir < 0 ? PathArc.Counterclockwise : PathArc.Clockwise
    }
  }

  // A filled bar with fully rounded ends along its short side.
  component Bar: ShapePath {
    id: bar
    property real x0: 0
    property real y0: 0
    property real x1: 0
    property real y1: 0
    readonly property real rr: Math.min(x1 - x0, y1 - y0) / 2 * root.u

    strokeWidth: 0
    strokeColor: "transparent"
    fillColor: root.color

    PathRectangle {
      x: bar.x0 * root.u; y: bar.y0 * root.u
      width: (bar.x1 - bar.x0) * root.u
      height: (bar.y1 - bar.y0) * root.u
      radius: bar.rr
    }
  }
}
