#!/usr/bin/env bash
# Install the Instabox bar widget into the user's Omarchy shell config.
set -euo pipefail

src="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
config="${XDG_CONFIG_HOME:-$HOME/.config}"
dest="$config/omarchy/plugins/ak.instabox"
dest_real="$(readlink -f "$dest" 2>/dev/null || true)"

if [[ "$src" == "$dest_real" ]]; then
  echo "Already installed from this directory: $dest -> $src"
else
  mkdir -p "$dest"
  for file in manifest.json BarWidget.qml Panel.qml README.md LICENSE; do
    if [[ -f "$src/$file" ]]; then
      cp "$src/$file" "$dest/$file"
    fi
  done
  echo "Installed to $dest"
fi

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
omarchy plugin enable ak.instabox --section right
echo "Enabled ak.instabox on the right side of the bar."
