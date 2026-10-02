import QtQuick
import Quickshell.Io
import qs.Commons

// The colour Tandem draws its highlights in. By default the theme's own accent;
// or one of the other colours in the current theme's palette (blue, cyan,
// green, magenta, ...), read from the theme's colors.toml. The choice is
// stored by name, so it follows a theme change, and falls back to the accent
// where the new theme has no such colour.
Item {
  id: root

  // "theme" or a palette name.
  property string choice: "theme"
  property var palette: ({})

  readonly property var names: ["blue", "cyan", "green", "magenta", "yellow", "red", "orange"]
  readonly property var available: names.filter(function(n) { return root.palette[n] !== undefined })
  readonly property color value: root.colorOf(root.choice)

  function colorOf(name) {
    if (name !== "theme" && root.palette[name] !== undefined) return root.palette[name]
    return Color.accent
  }

  function parse(text) {
    var next = {}
    var lines = String(text).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^\s*([a-z_]+)\s*=\s*"(#[0-9a-fA-F]{6})"/)
      if (m) next[m[1]] = m[2]
    }
    root.palette = next
  }

  FileView {
    id: colors
    path: Color.currentThemePath + "/colors.toml"
    watchChanges: true
    printErrors: false
    onLoaded: root.parse(text())
    onFileChanged: reload()
  }

  // A theme switch reaches the shell as a pushed payload, and the file may be
  // swapped under the watch, so also re-read shortly after the accent moves.
  Connections {
    target: Color
    function onAccentChanged() { refresh.restart() }
  }

  Timer {
    id: refresh
    interval: 400
    onTriggered: colors.reload()
  }
}
