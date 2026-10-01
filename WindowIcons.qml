import QtQuick
import Quickshell
import Quickshell.Hyprland

// What is open on each desktop, as data and icons. The settings panel and the
// bar indicator both ask this, so the lookup lives in one place. A desktop owns
// one workspace per monitor, so its workspaces are numbered from `monitorCount`.
Item {
  id: root

  property int monitorCount: 1
  // The shell's AppLibrary (bar.shell.appLibrary), which also searches the
  // on-disk icon index; optional.
  property var appLibrary: null

  function workspacesOf(desk) {
    var out = []
    var count = Math.max(1, root.monitorCount)
    for (var i = 1; i <= count; i++) out.push((desk - 1) * count + i)
    return out
  }

  // The windows open on a desktop, across its workspaces: { appId, title }.
  function windowsOfDesk(desk) {
    var ids = root.workspacesOf(desk)
    var out = []
    var list = Hyprland.toplevels ? Hyprland.toplevels.values : []
    for (var i = 0; i < list.length; i++) {
      var t = list[i]
      if (!t || !t.workspace || ids.indexOf(t.workspace.id) < 0) continue
      var ipc = t.lastIpcObject || {}
      out.push({
        appId: String(t.wayland && t.wayland.appId ? t.wayland.appId : (ipc["class"] || "")),
        title: String(t.title || "")
      })
    }
    return out
  }

  // The same, one entry per app: { appId, title, count }.
  function appsOfDesk(desk) {
    var windows = root.windowsOfDesk(desk)
    var seen = {}
    var out = []
    for (var i = 0; i < windows.length; i++) {
      var id = windows[i].appId
      if (seen[id] === undefined) {
        seen[id] = out.length
        out.push({ appId: id, title: windows[i].title, count: 1 })
      } else {
        out[seen[id]].count++
      }
    }
    return out
  }

  // The app's icon, through its desktop entry where there is one: a window
  // class such as "brave-origin" is not an icon name by itself. Falls back to
  // the class as an icon name, then to the shell's generic icon.
  function iconFor(appId) {
    var id = String(appId || "")
    var name = id
    try {
      var entry = DesktopEntries.byId(id)
      if (!entry) {
        var guess = DesktopEntries.heuristicLookup(id)
        var a = id.toLowerCase(), b = guess ? String(guess.id || "").toLowerCase() : ""
        if (guess && b !== "" && (a === b || a.indexOf(b) !== -1 || b.indexOf(a) !== -1)) entry = guess
      }
      if (entry && entry.icon) name = String(entry.icon)
    } catch (e) { }
    if (root.appLibrary) return root.appLibrary.iconSource(name)
    return Quickshell.iconPath(name, true)
  }
}
