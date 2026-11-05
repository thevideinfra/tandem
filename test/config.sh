#!/usr/bin/env bash
# Checks the size settings of tandem-config against a scratch shell.json, so
# nothing touches the real one.
#   bash test/config.sh
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export OMARCHY_SHELL_JSON="$TMP/shell.json"
failures=0
checks=0

fresh() {
  jq -nc --argjson extra "${1:-{\}}" \
    '{bar: {layout: {left: [({id: "videinfra.tandem", desktops: 2} + $extra)]}}}' >"$OMARCHY_SHELL_JSON"
}

get() { "$HERE/tandem-config" get | jq -r "$1"; }

eq() {
  checks=$((checks + 1))
  if [[ $1 != "$2" ]]; then
    failures=$((failures + 1))
    echo "FAIL $3: expected '$2', got '$1'"
  fi
}

rejects() {
  checks=$((checks + 1))
  if "$HERE/tandem-config" set "$1" "$2" >/dev/null 2>&1; then
    failures=$((failures + 1))
    echo "FAIL $1=$2 should be rejected"
  fi
}

# Defaults: the slider style at 100%, with the classic presets as they were.
fresh
eq "$(get .scale)" 100 "default scale"
eq "$(get .presets)" false "presets off by default"
eq "$(get .density)" normal "default density preset"
eq "$(get .fontSize)" normal "default fontSize preset"

# The classic presets keep their names; the old alias still reads as roomy.
fresh '{"density": "comfortable", "fontSize": "large"}'
eq "$(get .density)" roomy "comfortable reads as roomy"
eq "$(get .fontSize)" large "fontSize large kept"

# A number left by the earlier slider build is not a preset name.
fresh '{"density": 85, "fontSize": 120}'
eq "$(get .density)" normal "numeric density reads as normal"
eq "$(get .fontSize)" normal "numeric fontSize reads as normal"

# A number saved under `density` by the earlier slider build is the scale.
fresh '{"density": 85}'
eq "$(get .scale)" 85 "numeric density carries over as scale"
fresh '{"density": 85, "scale": 70}'
eq "$(get .scale)" 70 "scale wins over a numeric density"

# The slider value: a whole number from 60 to 140, anything else reads as 100.
fresh '{"scale": 75}'
eq "$(get .scale)" 75 "scale 75 kept"
fresh '{"scale": 20}'
eq "$(get .scale)" 100 "scale out of range resets"
fresh '{"scale": "big"}'
eq "$(get .scale)" 100 "scale string resets"

# set stores the right types.
fresh
"$HERE/tandem-config" set scale 80 >/dev/null
"$HERE/tandem-config" set presets true >/dev/null
"$HERE/tandem-config" set density compact >/dev/null
"$HERE/tandem-config" set fontSize small >/dev/null
eq "$(jq -r '.bar.layout.left[0].scale | type' "$OMARCHY_SHELL_JSON")" number "scale stored as number"
eq "$(jq -r '.bar.layout.left[0].presets | type' "$OMARCHY_SHELL_JSON")" boolean "presets stored as boolean"
eq "$(get .scale)" 80 "scale 80 saved"
eq "$(get .presets)" true "presets saved"
eq "$(get .density)" compact "density preset saved"
eq "$(get .fontSize)" small "fontSize preset saved"
for v in 60 140; do
  "$HERE/tandem-config" set scale "$v" >/dev/null 2>&1; eq "$(get .scale)" "$v" "scale $v accepted"
done

for v in 59 141 0 -5 80.5 abc compact "" 1e2; do rejects scale "$v"; done
for v in 100 abc yes ""; do rejects presets "$v"; done
for v in 80 tiny ""; do rejects density "$v"; rejects fontSize "$v"; done
eq "$(get .scale)" 140 "rejections leave scale alone"

echo "$checks checks, $failures failed"
exit $((failures == 0 ? 0 : 1))
