# Notes

Hyprland Lua and Omarchy API behaviour, verified against a running compositor.
None of it is documented anywhere obvious; each item caused a real bug.

## Hyprland Lua

**Workspace keys bind as `code:NN`.** Omarchy uses `SUPER + code:10`..`code:19`.
`hl.unbind("SUPER + 1")` matches nothing and fails silently.

```lua
for id = 1, 10 do hl.unbind("SUPER + code:" .. tostring(id + 9)) end
```

Also retire these, or they desync the desktops: `SUPER+TAB`,
`SUPER+SHIFT+TAB`, `SUPER+CTRL+TAB`, `SUPER+mouse_down/up`,
`SUPER+SHIFT+ALT+arrows`.

**Window selectors need a prefix.** `hl.get_window("0x...")` is always nil;
`hl.get_window("address:0x...")` works. A dead address returns nil without
erroring, which makes it a usable weak reference.

**`hyprctl dispatch <expr>` evaluates Lua in the config's own global scope**
and must be handed a dispatcher back. A global that does work and returns
`hl.dsp.no_op()` is therefore a one-call bridge from QML into config Lua:

```lua
function tandem_show(desk) show(desk) return hl.dsp.no_op() end
```

**`monitor:set_workspace` does not emit `workspace.active`.** `hl.dsp.focus`
does. Anything hooked to that event misses switches made by `set_workspace`.

**`hl.dsp.cursor.move` is absolute, not relative**, and clamps into the
nearest monitor.

## Drag state is not observable

No API reports that the mouse button came up:

- No release event after a real drag — neither `{ mouse = true, release = true }`
  nor a plain `{ release = true }` bind fires. `RELEASE` only follows a plain
  click.
- `is_key_down` takes keysyms only. Codes 272, 0x110, 1, 2, 3 and 0x120 all
  read false against a held button.
- `HL.Window` has no drag field, and no mouse-button event exists.

Consequences for carrying a dragged window:

- **A mouse switch carries it; a keyboard switch does not.** `SUPER+scroll`
  keeps the pointer grab alive and Hyprland carries the window itself across
  any number of desktops. That path must stay a plain `show()` — calling
  `send()` there moves the window twice and ends the drag.
- Keyboard switches must move the window explicitly, and the grab record is
  consumed, so one grab crosses one desktop. Without consuming it, the record
  survives the drop and the next switch moves a window nobody is holding.
- Hyprland does **not** re-press while the button is held.

Two approaches that look right and are not:

- **Re-attaching** with `hl.dsp.window.drag()` after the move keeps the window
  glued to the pointer, but suppresses the press that re-arms the record — one
  press then produces unbounded carries.
- **Pinning** (`float` + `pin`) makes the window ride every switch, but
  unpinning needs the same button-up nobody reports. A missed unpin leaves the
  window on every desktop.

Nudging the cursor after a keyboard switch does not reproduce the mouse path
either. The interactive move is bound to the mouse event path, which no
keybind can enter.

## Omarchy shell

**Widget settings are flat keys on the bar entry.** `BarModel.entrySettings()`
copies every key except `id`, the same shape the stock clock uses. Nesting
under a `settings` object yields `settings.settings.x` in the widget, and
every lookup silently reads `undefined`.

**`Panel` is a bare `Item`.** Bind `implicitWidth`/`implicitHeight` to the
button or the bar slot collapses to zero width and the widget never appears.

**Structural changes need `omarchy restart shell`.** Saving a file under
`~/.config/omarchy/plugins/` hot-reloads code the shell already loaded. It
does not cover a plugin newly added to the layout, nor some edits to a loaded
panel.

**First run has no Hyprland config.** `omarchy plugin add --enable` clones the
plugin and places one bar entry; it runs nothing, so no generated config
exists yet. The widget detects that (`tandem-config get` reports
`configured`), shows a button that launches the wizard in a terminal, and the
wizard writes the config and adds the second bar entry. Precedent:
`crmne.hyprmoncfg` ships the same shape, including editing Hyprland config
from the script its button runs.

**An install script must tolerate running from the installed plugin.** The
`omarchy plugin add` flow leaves the repo at
`~/.config/omarchy/plugins/<id>/`, so a script run from there has source and
destination as the same directory: skip the copy, and never wipe the
destination first, or it deletes itself mid-run.

**One plugin can supply two bar widgets.** A manifest declares a single
`barWidget` entry point, but `allowMultiple: true` lets the same id appear
twice in `shell.json`, and each entry's own keys reach the widget as
`settings`. A switch component loading one of two files by `settings.role`
keeps the repo to one `manifest.json` at its root, which `omarchy plugin add`
requires. Only the settings role instantiates `Panel`, so the two entries do
not collide over `ipcTarget`.

**Never restart the shell from a process the shell spawned.** The settings
panel runs `tandem-config` as a child of `omarchy-shell`, so an inline
`omarchy restart shell` kills the whole tree, including the script and the
restart command. Detach it:

```bash
setsid sh -c 'sleep 0.5; omarchy restart shell' >/dev/null 2>&1 < /dev/null &
```

**Bar widgets do receive right-clicks.** `Ui/WidgetButton.qml` has its own
MouseArea accepting `LeftButton | RightButton | MiddleButton`. The
`acceptedButtons: Qt.LeftButton` in `Bar.qml` is only the central dispatch.

**`omarchy plugin remove` restores a displaced widget only via
`omarchy.clonedFrom`:**

```json
"omarchy": { "clonedFrom": "omarchy.workspaces" }
```

`PluginRegistry.restoreCloneSource()` then returns the source to the same bar
slot. Without it, removal leaves no workspace indicator. Its other effects are
gated on conditions a bar-widget-only plugin does not meet: `config.bar.id`
needs `kinds: ["bar"]`, `addDisabled` needs a non-widget kind, and capability
inheritance needs a source with capabilities.

Removal never touches Hyprland, so bindings stay live in memory until a
reload. `show()` checks whether the generated `tandem.lua` still exists and
reloads once when it is gone.

## Colour roles

Defined across all 22 stock themes: `accent`, `muted`, `foreground`.
Defined in **none**: `bar.active`, `urgent`. `WidgetButton`'s default
`activeColor` resolves to `bar.active`, falls through to a hardcoded red, and
looks theme-aware while being identical on every theme.

Tandem uses `accent` for the active desktop, `muted` for the separator, and
`foreground` at 0.55 for inactive, so all three stay distinguishable.

Audit a role before trusting it:

```bash
for k in bar.active accent urgent; do
  echo "$k: $(grep -rl "^\s*\"\?$k\"\?\s*=" /usr/share/omarchy/themes/*/colors.toml | wc -l)/22"
done
```

## Generator

- **`jq`'s `//` swallows `false`.** `.numbers // true` returns `true` for a
  stored `false`. Use `if has($k) and .[$k] != null then .[$k] else $d end`.
- **`grep -vF '-- comment'` reads the pattern as an option.** Anything that can
  start with `-` goes through `-e`.
- Monitor names are interpolated into Lua source, so a name containing a quote
  is rejected.

## Validating a change

```bash
bash -n tandem-{apply,setup,config} install.sh uninstall.sh
omarchy plugin validate .
qmllint BarWidget.qml Indicator.qml Settings.qml   # qs.* import warnings are noise
HOME=/tmp/sandbox ./install.sh && HOME=/tmp/sandbox ./uninstall.sh
```

`tandem-apply` runs `luac -p` on what it generates and keeps the previous file
if it fails. `hyprctl configerrors` printing nothing is the pass condition.

Keybindings cannot be verified headlessly: `wtype` does not trigger Hyprland
binds and its virtual keyboard does not register in `is_key_down`. What can be
automated is `hyprctl dispatch` against temporary globals appended to the
generated `tandem.lua` — and test the real path (`tandem_show(2)`, what
`SUPER+2` runs), not a convenient stand-in.
