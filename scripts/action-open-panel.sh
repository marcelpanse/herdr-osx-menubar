#!/bin/bash
# Plugin action: show HerdrBar's agents panel.
#
# The panel is what a left click on the menu bar icon opens; this lets it be
# reached from a herdr key too, e.g. in config.toml:
#   [[keys.command]]
#   key = "prefix+a"
#   type = "plugin_action"
#   command = "herdr-topbar.open-panel"
set -euo pipefail
APP="${HERDR_TOPBAR_APP:-$HOME/Applications/HerdrBar.app}"
HELPER="$APP/Contents/MacOS/herdrbar-open"

if [ ! -x "$HELPER" ]; then
    echo "HerdrBar is not built yet. Run scripts/build.sh first." >&2
    exit 1
fi

exec "$HELPER" --panel
