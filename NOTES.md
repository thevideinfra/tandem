# Notes

Hyprland Lua / Omarchy API behaviour, verified by probing the live compositor
with `hyprctl dispatch`. Most of these are not documented anywhere obvious and
each one caused a real bug during development.

## Keybindings

**Omarchy binds workspace keys as `SUPER + code:10`..`code:19`, never as
`SUPER + 1`.** So `hl.unbind("SUPER + 1")` silently matches nothing. An earlier
version of this config used that form, left all the stock per-monitor
workspace bindings live, and desynced the two screens. Unbind the `code:` form:

```lua
for id = 1, 10 do
  hl.unbind("SUPER + code:" .. tostring(id + 9))
end
```

Other bindings that desync synced desktops and must also be retired:
`SUPER+TAB`, `SUPER+SHIFT+TAB`, `SUPER+CTRL+TAB`, `SUPER+mouse_down/up`, and
`SUPER+SHIFT+ALT+arrows`.

## Selectors

`hl.get_window(addr)` returns **nil for a bare address**. The selector must be
prefixed:

```lua
hl.get_window("address:0x55971ab8d2b0")   -- works
hl.get_window("0x55971ab8d2b0")           -- always nil
```

A dead address returns nil rather than erroring, which makes it a good way to
hold a weak reference to a window.

## hyprctl dispatch is a Lua bridge

`hyprctl dispatch <expr>` wraps the argument as `return hl.dispatch(<expr>)`
and evaluates it **in the config's own global scope**. It must be handed a
dispatcher back.

So a global function that does arbitrary work and returns `hl.dsp.no_op()` is
a clean one-call bridge from a Quickshell bar widget into config Lua — which
is how the widget switches desktops without duplicating any of the math:

```lua
function tandem_show(desk)
  show(desk)
  return hl.dsp.no_op()
end
```

```qml
bar.run("hyprctl dispatch " + Util.shellQuote("tandem_show(2)"))
```

## There is no way to ask whether a drag is in progress

All three routes are closed:

- `hl.is_key_down` takes **keysyms only**; `"mouse:272"` fails with
  "Unknown keysym", so it cannot see mouse buttons at all.
- `HL.Window` has no drag/moving field.
- The event list has no mouse-button event (`hl.on` covers windows,
  workspaces, monitors, layers, config — not pointer buttons).

So a drag has to be recorded on press. **The hard part is clearing it again.**

### A `{ mouse = true }` bind swallows the button-up that ends a real drag

A paired `{ release = true }` handler therefore fires dependably only after a
plain *click*, not after an actual drag. Do not rely on it alone.

The rules that make the record safe:

1. **A carry consumes the record** — one grab moves the window once. This is
   the only clear that always fires.
2. The record is an address, re-resolved on every use, so a closed window
   resolves to nothing.
3. The window must still be focused.
4. Focus landing on any other window clears it.

### Do not re-arm the record after a carry

It looks correct — the button really is still down, so the drag really is
still going. But it overwrites the release handler's clear, and the result is
a window that ping-pongs between desktops on every later `SUPER+F`. This was
shipped once and had to be reverted.

### Target the window's own monitor

`send()` must read `window.monitor`, not `hl.get_active_monitor()`. Using the
focused monitor means clicking on the other screen and hitting `SUPER+F` drags
the window onto that screen. The window and the focus are not always on the
same monitor.

## Testing

`wtype` **cannot** trigger Hyprland keybinds, and its virtual keyboard does not
register in `is_key_down`. There is no ydotool here and the user is not in the
`input` group, so keybinding behaviour cannot be verified headlessly — it needs
a human at the machine.

What *can* be automated: `hyprctl dispatch` against temporary global test hooks
appended to the generated `tandem.lua`, which is how the carry, the consume, the dead-window
case and the cross-monitor case were all verified. Remember to strip the hooks
and reload afterwards.

## Validating changes

```bash
bash -n omarchy/plugins/videinfra.tandem/tandem-{apply,setup,config} install.sh uninstall.sh
omarchy plugin validate omarchy/plugins/videinfra.tandem
qmllint omarchy/plugins/videinfra.tandem/BarWidget.qml   # ignore qs.* import warnings
HOME=/tmp/sandbox ./install.sh && HOME=/tmp/sandbox ./uninstall.sh
```

`tandem-apply` runs `luac -p` on what it generates and refuses to install a
file that fails.

`hyprctl configerrors` printing nothing is the pass condition.

## Packaging it as a plugin

Verified while deciding whether the whole thing could ship as one plugin:

- **Plugin QML is not sandboxed.** `PluginRegistry.trustedCapabilities` gates
  exactly one capability, `authentication` (lock screen, polkit), and it is
  first-party only. Nothing restricts file writes or process execution, and
  `bar.run(...)` already runs shell commands from a third-party widget.
- **Plugins receive a `settings` object** from their entry in `shell.json`, so
  configuration needs no separate file.
- **`hyprctl keyword` is dead** ("keyword can't work with non-legacy parsers.
  Use eval."), but **`hyprctl eval` works** and can register both keybinds and
  workspace rules at runtime.
- **Runtime injection does not survive `hyprctl reload`** — verified: a bind
  added via `eval` is gone after a reload. Quickshell *can* watch for it
  (`configreloaded`, as `KeyboardLayout.qml` does) and re-apply, but generating
  real config avoids needing a daemon to re-assert itself.
- **There is no plugin uninstall hook.** `omarchy-plugin-remove` is `rm -rf`
  plus a `shell.json` edit; the manifest schema validates only `id`, `name`,
  `version`, `kinds`, `entryPoints`; and the hook events are `battery-low`,
  `font-set`, `post-boot`, `post-update`, `pre-refresh-pacman`, `theme-set`.
  Hence `pcall(dofile, ...)` — inert on removal beats cleanup that cannot run.

## Generator gotchas

- **`jq`'s `//` swallows `false`.** `.numbers // true` returns `true` when the
  setting is `false`, silently re-enabling every disabled option. Use
  `if has($k) and .[$k] != null then .[$k] else $d end`.
- **`grep -vF '-- comment'` parses the pattern as an option.** Any pattern that
  can start with `-` must go through `-e`.
- Monitor names are interpolated into Lua source, so they are rejected if they
  contain a quote.

## Test tooling

- `luac -p` syntax-checks generated Lua (the generator refuses to install a
  file that fails, keeping the previous one).
- `qmllint` cannot resolve the `qs.*` Quickshell modules, so its import
  warnings are noise — but it still catches real QML syntax errors, which
  makes it a usable gate.
- Install/uninstall are testable headlessly with a sandboxed `HOME`, which is
  how the two bugs above were found.

## The shell must be restarted for structural plugin changes

Saving a file under `~/.config/omarchy/plugins/` hot-reloads plugin *code* that
the shell has already loaded. It does **not** cover:

- a plugin newly added to the bar layout -- it stays invisible, with no error,
  while `omarchy plugin list` cheerfully reports it as `enabled`;
- some edits to an already-loaded panel, which kept rendering the previous
  component until a restart.

Both need `omarchy restart shell`. This cost real time to find: a brand new
widget rendered nothing at all, and swapping the entire panel for a plain
40x26 red `Rectangle` *also* rendered nothing -- which is what proved the
problem was not in the QML. `install.sh` restarts the shell when it adds the
widget.

## Bar widgets do receive right-clicks

An earlier note here claimed otherwise, on the strength of
`acceptedButtons: Qt.LeftButton` at Bar.qml:1646 and :1913. That is only the
bar's *central* click dispatch. `WidgetButton` has its own MouseArea
(`Ui/WidgetButton.qml:98`) accepting `LeftButton | RightButton | MiddleButton`
and forwarding the button to `triggerPress`, which is how the volume widget
mutes on right-click. Panels still open on left click, matching the
first-party widgets.

The practical cost of getting this wrong: a right-click handler written while
believing right-click was dead turned out to be very much alive, so
right-clicking a desktop button launched the setup wizard. The indicator now
handles left-click only, and setup lives in the settings panel.

## Panel is a bare Item

`Ui/Panel.qml` sets no implicit size, so a panel widget must bind
`implicitWidth`/`implicitHeight` to its button or the bar slot collapses to
zero width and the widget silently never appears.

## Widget settings are flat keys on the bar entry

`BarModel.entrySettings()` copies **every key on the entry except `id`** and
hands that to the widget as `settings`. So a widget's configuration belongs
directly on its bar entry, exactly like the stock clock:

```json
{ "id": "omarchy.clock", "format": "dddd h:mm AP", "formatAlt": "..." }
```

Nesting it under a `settings` object instead produces `settings.settings.x`
in the widget and every lookup silently reads `undefined` -- no error, the
widget just renders its fallbacks forever. That is exactly how custom desktop
labels appeared to do nothing while sitting correctly in `shell.json`.

Diagnose this in one step by rendering `JSON.stringify(root.settings)` into
the widget text; the nesting is then obvious.

`tandem-config` migrates any legacy nested object up to flat on its next
write, so the mistake is self-healing.

## `bar.active` is not a theme colour in practice

`Color.bar.active` resolves as `pick("bar.active", root.urgent)`, and `urgent`
itself defaults to a hardcoded `#a55555`. **No stock theme defines either key**
— 0 of 22 set `bar.active`, 0 set `urgent` — so `WidgetButton`'s default
`activeColor` paints the same red on every theme. It looks theme-aware and is
not.

`accent` is the key every one of the 22 stock themes actually defines, so an
"active item" highlight should use `Color.accent`:

```qml
active: root.desk === modelData
activeColor: Color.accent
```

Confirmed by switching themes: gruvbox renders `#7daea3`, dracula `#8be9fd`.

Check a colour role before trusting it:

```bash
for k in bar.active accent urgent; do
  echo "$k: $(grep -rl "^\s*\"\?$k\"\?\s*=" /usr/share/omarchy/themes/*/colors.toml | wc -l)/22"
done
```

## Colour roles that are actually safe to use

Checked across all 22 stock themes:

| role | defined in | use for |
|---|---|---|
| `accent` | 22/22 | the active/selected item |
| `muted` | 22/22 | rules, separators, de-emphasised text |
| `foreground` | 22/22 | normal text |
| `bar.active` | 0/22 | nothing — falls through to a hardcoded red |
| `urgent` | 0/22 | nothing — same |

The indicator uses all three real roles at once so the active entry, the
separator and the inactive entries stay distinguishable on any theme:
`accent` for active, `muted` for the `|`, `foreground` at 0.55 for inactive.

## Drag-carry: mouse and keyboard switches differ

**A mouse-driven switch carries a dragged window; a keyboard one does not.**
`SUPER+scroll` keeps Hyprland's pointer grab alive, so the compositor carries
the window itself across any number of desktops until the button comes up. A
keyboard bind drops the grab, so Tandem has to move the window explicitly.

The scroll path must therefore stay a plain `show()`: calling `send()` there
moves the window a second time and ends the drag. Only the keyboard paths go
through `go()`.

The difference is not stale pointer state — switching with a plain `show()`
from a keyboard bind does not carry, and nudging the cursor afterwards
(`hl.dsp.cursor.move`, which is absolute, not relative) does not either. The
interactive move appears bound to the mouse event path, which no keybind can
enter.

Constraints on the keyboard path:

- Hyprland does **not** re-press while the button stays down. One physical
  click gives one `PRESS`, so consuming the record on carry limits a grab to a
  single hop.
- **No release event arrives after a real drag.** Neither
  `{ mouse = true, release = true }` nor a plain `{ release = true }` bind
  fires; both were measured. `RELEASE` only appears after a plain click.

- **`is_key_down` cannot see mouse buttons.** Measured against a physically
  held button: codes 272, 0x110, 1, 2, 3 and 0x120 all read `false`.

So nothing reports that the button came up. Multi-hop and no-runaway are
mutually exclusive, and the runaway is the worse failure: a record that
survives a carry stays armed after the drop, so the next SUPER+F moves a
window nobody is holding — and the pointer is usually still over it, so the
cursor check does not catch the common case.

Tandem consumes the record on carry: one keyboard switch moves it one desktop.
Grab again, or use `SUPER+scroll`, to go further.

Re-attaching the drag (`hl.dsp.window.drag()` after the move) makes the window
stay glued to the pointer, but suppresses the press that re-arms the record —
one press then produced unbounded carries. Do not do it.

Pinning (`float` + `pin` on press) also works — a pinned window rides every
switch with no per-hop logic — but unpinning needs the same button-up nobody
reports, and a missed unpin leaves the window on every desktop. Worse failure
than a missed carry. Tried and reverted.

## Never restart the shell from a process the shell spawned

The settings panel runs `tandem-config` as a child of `omarchy-shell`. A
cosmetic-only change has to restart the shell — labels and the separator live
only in injected settings, which the bar refreshes when it rebuilds the widget
— but doing it inline kills the whole process tree: the shell, `tandem-config`
itself, and the `omarchy restart shell` command.

The result is a race, not a clean failure. An applied name or separator would
flash and vanish, or not apply at all, while the *same* change made alongside a
desktop-count change stuck every time — that path reloads Hyprland instead and
never restarts the shell.

Detach it, and run it after this script has exited:

```bash
setsid sh -c 'sleep 0.5; omarchy restart shell' >/dev/null 2>&1 < /dev/null &
```

`setsid` moves it to a new session, so killing the shell's tree no longer takes
the restart down with it.

Note the symptom shape: the disk write was always correct. Checking
`shell.json` after a failed apply showed the right value, which points at the
display when the fault is really in the process that refreshes it.

## Superseding a built-in widget: `omarchy.clonedFrom`

`omarchy-plugin-remove` restores the widget a plugin displaced only when the
manifest names it:

```json
"omarchy": { "clonedFrom": "omarchy.workspaces" }
```

`PluginRegistry.restoreCloneSource()` then puts the source back in the same
bar slot on removal. Without the field, removal deletes the entry and leaves
the bar with no workspace indicator, recoverable only by hand (`plugin enable`
drops it into the center section, so it also needs `omarchy bar move`).

The field is meant for `omarchy plugin clone`, and Tandem shares no code with
`omarchy.workspaces` — it is off-label. Measured, and nothing else it drives
applies here:

- `config.bar.id = clonedFrom` — only for `kinds: ["bar"]` whole-bar plugins.
- `addDisabled(config, clonedFrom)` — only when the plugin has a non-widget
  kind.
- `stampHostCapabilities` — inherits the source's capabilities;
  `omarchy.workspaces` has none.

Install is unaffected: the layout swap in `install.sh` is still needed, and no
duplicate entry appears. Verified over a full uninstall / install /
`plugin remove` cycle — removal printed "Restored omarchy.workspaces." and the
stock widget came back in its original slot.

Removal still leaves Hyprland untouched, so the bindings persist in memory
after the plugin directory is gone — `SUPER+2` keeps jumping to a Tandem
desktop while the stock bindings stay unbound. `body.lua` repairs this: it
checks whether its own generated file still exists on `workspace.active` and
`window.open`, and runs `hyprctl reload` once when the file is gone. The
loader is a `pcall`, so after that reload the file is simply not loaded.

Hooked to events rather than `hl.timer` deliberately: no idle cost, and the
repair fires exactly when the stale bindings are used.

Testing note: `workspace.active` only fires on an actual change. Dispatching
to the workspace already showing produces no event, which looked twice like
the heal was broken when the test was.
