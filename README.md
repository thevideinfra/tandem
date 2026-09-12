# Tandem

KDE-style virtual desktops for [Omarchy](https://omarchy.org/) / Hyprland.

Every monitor switches workspace **together**, instead of Omarchy's default of
independent per-monitor workspaces. The bar shows `D1 D2` instead of
workspaces `1-5`.

Built with Claude Code.

## Why

I like the way KDE handled this with virtual desktops as opposed to independent workspaces. I typically only have 2 "workspaces" that I swap back and forth between with SUPER + F and I wanted this ability in Omarchy.

## Model

A desktop owns one workspace per monitor:

```
workspace = (desktop - 1) * #MONITORS + monitor_index
```

Two monitors, two desktops:

| Desktop | Monitor 1 | Monitor 2 |
|---------|-----------|-----------|
| D1      | ws 1      | ws 2      |
| D2      | ws 3      | ws 4      |

A persistent workspace rule pins each workspace to its monitor, so nothing
drifts between screens.

## Install

```bash
./install.sh          # copies the plugins, swaps the bar widget, generates config
./uninstall.sh        # removes everything, restores stock workspaces
```

`install.sh` works with no input: 2 desktops, autodetected monitors, `SUPER+F`.
It then offers the setup wizard, but only when a terminal is attached, so
piped installs stay non-interactive.

Run the wizard later:

```bash
~/.config/omarchy/plugins/videinfra.tandem/tandem-setup
```

It asks for monitor order, desktop count, names and keys, writes them to
`shell.json`, and regenerates the Hyprland config.

The **settings panel** (grid icon, right of the bar) edits desktop count,
names, keybindings and the `|` separator, and lists the detected monitors.
Edits are **staged** until you press Apply — each write regenerates and
reloads the Hyprland config, too disruptive to do per click. Revert discards
staged edits; so does closing the panel.

## Layout

```
omarchy/plugins/videinfra.tandem/
  manifest.json     bar-widget plugin
  BarWidget.qml     the D1/D2 indicator
  body.lua          the logic, hand-maintained
  tandem-apply      generates tandem.lua from settings, installs the loader
  tandem-setup      gum wizard; writes settings, then calls tandem-apply
  tandem-config     get / set / set-json; the panel's back end
  tandem.lua        GENERATED -- not in git

omarchy/plugins/videinfra.tandem-settings/
  manifest.json     settings widget, bar's right section
  Panel.qml         settings panel; thin front-end over tandem-config
```

## Settings

Settings are **flat keys on the plugin's bar entry** in
`~/.config/omarchy/shell.json` — the shape the stock clock uses, because the
bar hands a widget every key on its entry except `id`:

```json
{ "id": "videinfra.tandem",
  "monitors": ["DP-1", "DP-2"],
  "desktops": 2,
  "labels":   ["desktop1", "desktop2"],
  "toggle":   "SUPER + F",
  "send":     "SUPER + SHIFT + F",
  "numbers":  true,
  "tab":      true,
  "scroll":   true,
  "separator": false }
```

- `monitors` — omit to autodetect, ordered top-to-bottom then left-to-right.
- `labels` — desktop names. Omit or use `[]` for the `D1`..`Dn` default; a
  short list names only the desktops it covers.
- `separator` — draws a `|` between bar entries.

`labels` and `separator` are cosmetic, so changing only those skips the
Hyprland regenerate-and-reload.

Edit by hand and re-run `tandem-apply`, or use the panel or wizard.

`tandem-apply` writes `tandem.lua` (config block plus `body.lua`),
syntax-checks it with `luac -p` before replacing the previous file, and
appends one line to `hyprland.lua`:

```lua
pcall(dofile, (os.getenv("HOME") or "") .. "/.config/omarchy/plugins/videinfra.tandem/tandem.lua")
```

## Keys

Defaults; all configurable.

| Key | Action |
|-----|--------|
| `SUPER + F` | Next desktop |
| `SUPER + SHIFT + F` | Send window to next desktop |
| `SUPER + 1`..`n` | Jump to desktop |
| `SUPER + SHIFT + 1`..`n` | Send window to desktop |
| `SUPER + TAB` / `SHIFT + TAB` | Next / previous desktop |
| `SUPER + scroll` | Next / previous desktop |
| `SUPER + drag`, then a keyboard switch | Carry the dragged window one desktop |
| `SUPER + drag`, then `SUPER + scroll` | Carry it across any number of desktops |

Clicking `D1` / `D2` switches desktop. The grid icon opens the settings panel.

`tandem.lua` retires the stock per-monitor workspace bindings, which move one
screen at a time and desync the desktops.

> **Carrying differs by switch type.** `SUPER+scroll` carries a dragged window
> across any number of desktops and drops it on release — Hyprland does that
> itself. A keyboard switch carries it **one desktop per grab**; grab again to
> go further. Nothing reports the mouse button coming up, so the keyboard path
> cannot safely do more. See [NOTES.md](NOTES.md).

## Uninstalling

```bash
./uninstall.sh
```

Removes both plugins, restores `omarchy.workspaces` to the slot the widget
occupied, and strips the loader line from `hyprland.lua`.

`omarchy plugin remove videinfra.tandem` works too — the manifest declares
`"omarchy": { "clonedFrom": "omarchy.workspaces" }`, so the stock widget comes
back — but it leaves things behind: `videinfra.tandem-settings` stays
installed with a panel that can no longer reach `tandem-config`, and the
loader line stays in `hyprland.lua` (inert, it is a `pcall`). Tandem reloads
Hyprland itself on the next desktop switch so the stock bindings return.

## Is this really all one plugin?

Two plugins, and neither can declare Hyprland config. Omarchy manifests only
accept Quickshell kinds, so there is no *declarative* hook — but plugin QML is
not sandboxed (`authentication` is the registry's only gated capability), so
Tandem does it imperatively: the widget shells out, the wizard writes
settings, and `tandem-apply` generates the Lua.

The alternative, injecting binds at runtime via `hyprctl eval`, works but is
wiped by every `hyprctl reload` and would need a service re-applying on
`configreloaded`. Generating real config is sturdier.

## Notes

[NOTES.md](NOTES.md) documents the Hyprland Lua API traps this is built
around. Read it before touching drag-carry.
