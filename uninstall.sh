#!/usr/bin/env bash
# Remove the Virtual Desktops plugin completely.
#
# `omarchy plugin remove videinfra.tandem` does most of this on its own -- it
# deletes the plugin directory (taking the generated tandem.lua with it) and
# drops the widget from the bar. The loader line in hyprland.lua is a pcall, so
# it goes inert by itself and needs no cleanup. This script exists only to tidy
# that last dead line away.
set -euo pipefail

OMARCHY="$HOME/.config/omarchy"
PLUGIN="$OMARCHY/plugins/videinfra.tandem"
HYPRLAND_LUA="$HOME/.config/hypr/hyprland.lua"
SHELL_JSON="$OMARCHY/shell.json"
STAMP="$(date +%s)"

echo "1. plugin directories"
if [[ -d $PLUGIN ]]; then rm -rf "$PLUGIN"; echo "  removed videinfra.tandem"; fi

echo "2. bar layout"
# Drop the settings widget from wherever it ended up.
if [[ -f $SHELL_JSON ]] && command -v jq >/dev/null \
  && jq -e '[.. | objects | select(.id == "videinfra.tandem" and (.role // "") == "settings")] | length > 0' "$SHELL_JSON" >/dev/null; then
  cp "$SHELL_JSON" "$SHELL_JSON.bak.$STAMP.settings"
  tmp=$(mktemp)
  jq '.bar.layout |= with_entries(
        if (.value | type) == "array"
        then .value |= map(select((.id != "videinfra.tandem") or ((.role // "") != "settings")))
        else . end)' "$SHELL_JSON" >"$tmp"
  mv "$tmp" "$SHELL_JSON"
  echo "  removed the settings widget"
  command -v omarchy >/dev/null && omarchy restart shell >/dev/null 2>&1 || true
fi
if [[ ! -f $SHELL_JSON ]] || ! command -v jq >/dev/null; then
  echo "  no shell.json to fix up"
elif jq -e '[.. | objects | select(.id == "videinfra.tandem" and (.role // "") != "settings")] | length > 0' "$SHELL_JSON" >/dev/null; then
  # Rename in place so the widget keeps its position in the bar.
  cp "$SHELL_JSON" "$SHELL_JSON.bak.$STAMP"
  tmp=$(mktemp)
  # Keep only the id: Tandem's settings are flat keys on the entry, and
  # leaving them behind would resurrect old values on the next install.
  jq '(.. | objects | select(.id == "videinfra.tandem" and (.role // "") != "settings")) |= {id: "omarchy.workspaces"}' \
    "$SHELL_JSON" >"$tmp"
  mv "$tmp" "$SHELL_JSON"
  echo "  restored omarchy.workspaces in place (backed up first)"
elif jq -e '[.. | objects | select(.id == "omarchy.workspaces")] | length > 0' "$SHELL_JSON" >/dev/null; then
  echo "  omarchy.workspaces already in the bar"
else
  # `omarchy plugin remove` deletes the entry outright rather than restoring
  # the stock widget, which leaves the bar with no workspace indicator at all.
  cp "$SHELL_JSON" "$SHELL_JSON.bak.$STAMP"
  tmp=$(mktemp)
  jq '.bar.layout.left += [{"id": "omarchy.workspaces"}]' "$SHELL_JSON" >"$tmp"
  mv "$tmp" "$SHELL_JSON"
  command -v omarchy >/dev/null && omarchy plugin enable omarchy.workspaces >/dev/null 2>&1 || true
  echo "  bar had no workspace widget; added omarchy.workspaces to the left section"
fi

echo "3. loader line in hyprland.lua"
if [[ -f $HYPRLAND_LUA ]] && grep -qF 'videinfra.tandem/tandem.lua' "$HYPRLAND_LUA"; then
  cp "$HYPRLAND_LUA" "$HYPRLAND_LUA.bak.$STAMP"
  # Drop the loader and its comment. Both patterns go through -e: the comment
  # starts with "--", which grep would otherwise read as an option.
  tmp=$(mktemp)
  grep -vF -e 'videinfra.tandem/tandem.lua' \
           -e '-- Virtual desktops (videinfra.tandem)' "$HYPRLAND_LUA" >"$tmp"
  # Collapse the blank line the removal leaves at the end of the file.
  awk 'BEGIN{n=0} {lines[NR]=$0} END{last=NR; while(last>0 && lines[last]~/^[[:space:]]*$/) last--; for(i=1;i<=last;i++) print lines[i]}' \
    "$tmp" >"$tmp.trimmed" && mv "$tmp.trimmed" "$tmp"
  mv "$tmp" "$HYPRLAND_LUA"
  echo "  removed (backed up first)"
else
  echo "  not present"
fi

if command -v hyprctl >/dev/null && [[ -n ${HYPRLAND_INSTANCE_SIGNATURE:-} ]]; then
  hyprctl reload >/dev/null
  errors=$(hyprctl configerrors 2>&1 || true)
  [[ -n ${errors//[[:space:]]/} ]] && { echo "hyprctl configerrors:" >&2; echo "$errors" >&2; exit 1; }
  echo "4. reloaded, config clean"
fi

echo
echo "Stock per-monitor workspaces are back."
