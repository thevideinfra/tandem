#!/usr/bin/env bash
# Install the Virtual Desktops plugin. Existing files are backed up, never
# clobbered. Safe to re-run.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OMARCHY="$HOME/.config/omarchy"
PLUGIN="$OMARCHY/plugins/videinfra.tandem"
STAMP="$(date +%s)"

for tool in jq hyprctl; do
  command -v $tool >/dev/null || { echo "install: $tool is required" >&2; exit 1; }
done
[[ -f $HOME/.config/hypr/hyprland.lua ]] || { echo "install: no hyprland.lua -- is this Omarchy?" >&2; exit 1; }

echo "1. plugin files"
# Backups go outside plugins/, or the shell scans them as a second plugin
# declaring the same id.
if [[ -d $PLUGIN && $SRC != "$PLUGIN" ]]; then
  mkdir -p "$OMARCHY/.tandem-backups"
  cp -r "$PLUGIN" "$OMARCHY/.tandem-backups/videinfra.tandem.bak.$STAMP"
  echo "  backed up -> ~/.config/omarchy/.tandem-backups/videinfra.tandem.bak.$STAMP"
fi
# Running from inside the installed plugin -- the `omarchy plugin add` path --
# means the source and the destination are the same directory, so there is
# nothing to copy and wiping the destination would delete this script.
if [[ $SRC == "$PLUGIN" ]]; then
  echo "  already in place (running from the installed plugin)"
else
  rm -rf "$PLUGIN"
  mkdir -p "$PLUGIN"
  for f in manifest.json BarWidget.qml Indicator.qml Settings.qml body.lua \
           tandem-apply tandem-config tandem-setup; do
    cp "$SRC/$f" "$PLUGIN/$f"
  done
fi
chmod +x "$PLUGIN/tandem-apply" "$PLUGIN/tandem-setup" "$PLUGIN/tandem-config"

echo "2. bar layout"
SHELL_JSON="$OMARCHY/shell.json"
if [[ ! -f $SHELL_JSON ]]; then
  echo "  no shell.json -- add the videinfra.tandem widget to your bar yourself"
elif jq -e '[.. | objects | select(.id == "videinfra.tandem")] | length > 0' "$SHELL_JSON" >/dev/null; then
  echo "  already in the bar"
elif jq -e '[.. | objects | select(.id == "omarchy.workspaces")] | length > 0' "$SHELL_JSON" >/dev/null; then
  cp "$SHELL_JSON" "$SHELL_JSON.bak.$STAMP"
  tmp=$(mktemp)
  jq '(.. | objects | select(.id == "omarchy.workspaces")).id = "videinfra.tandem"' "$SHELL_JSON" >"$tmp"
  mv "$tmp" "$SHELL_JSON"
  echo "  omarchy.workspaces -> videinfra.tandem (backed up first)"
else
  echo "  omarchy.workspaces not found -- add videinfra.tandem to the bar yourself"
fi

# Strip any leftover stock workspaces widget from every section. Swapping only
# the first occurrence leaves a duplicate indicator behind if a copy exists
# elsewhere -- e.g. `omarchy plugin enable omarchy.workspaces` drops one into
# the center section.
if [[ -f $SHELL_JSON ]] \
  && jq -e '[.. | objects | select(.id == "omarchy.workspaces")] | length > 0' "$SHELL_JSON" >/dev/null; then
  cp "$SHELL_JSON" "$SHELL_JSON.bak.$STAMP.dedupe"
  tmp=$(mktemp)
  jq '.bar.layout |= with_entries(
        if (.value | type) == "array"
        then .value |= map(select(.id != "omarchy.workspaces"))
        else . end)' \
    "$SHELL_JSON" >"$tmp"
  mv "$tmp" "$SHELL_JSON"
  echo "  removed a stray omarchy.workspaces widget"
fi

echo "3. settings widget"
# Same plugin id, second bar entry. The manifest sets allowMultiple, and
# BarWidget.qml picks its role from the entry.
if [[ -f $SHELL_JSON ]] \
  && jq -e '[.. | objects | select(.id == "videinfra.tandem" and (.role // "") == "settings")] | length > 0' "$SHELL_JSON" >/dev/null; then
  echo "  already in the bar"
elif [[ -f $SHELL_JSON ]]; then
  cp "$SHELL_JSON" "$SHELL_JSON.bak.$STAMP.settings"
  tmp=$(mktemp)
  jq '.bar.layout.right = ([{"id": "videinfra.tandem", "role": "settings"}] + (.bar.layout.right // []))' \
    "$SHELL_JSON" >"$tmp"
  mv "$tmp" "$SHELL_JSON"
  echo "  added to the right section"
  NEEDS_SHELL_RESTART=1
fi

# A newly added plugin is not picked up by the shell's hot reload -- that only
# covers edits to plugins it has already loaded. Without this the widget is
# enabled and present in shell.json but simply never appears in the bar.
if [[ -n ${NEEDS_SHELL_RESTART:-} ]] && command -v omarchy >/dev/null; then
  echo "  restarting the shell so it picks up the new widget"
  omarchy restart shell >/dev/null 2>&1 || true
fi

echo "4. generate Hyprland config"
"$PLUGIN/tandem-apply" | sed 's/^/  /'

echo
echo "Installed with defaults: 2 desktops, autodetected monitors, SUPER+F."

# Offer the wizard only when there is a terminal to run it in; a piped or
# scripted install must stay non-interactive.
if [[ -t 0 && -t 1 ]] && command -v gum >/dev/null; then
  if gum confirm "Run the setup wizard now?"; then
    exec "$PLUGIN/tandem-setup"
  fi
fi

cat <<EOF

Run the setup wizard any time to change desktops or keys:

  $PLUGIN/tandem-setup

or click the grid icon on the right of the bar.
EOF
