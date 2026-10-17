#!/bin/sh
# macOS-native installer: no Python, Node, package manager, or agent required.
set -eu
resource_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
config_dir=${1:-${XDG_CONFIG_HOME:-"$HOME/.config"}/opencode}
opencode_bin=${2:-}
if [ -z "$opencode_bin" ]; then
    opencode_bin=$(command -v opencode || true)
    if [ ! -f "$opencode_bin" ] || [ ! -x "$opencode_bin" ]; then
        for directory in /opt/homebrew/bin /usr/local/bin "$HOME/.opencode/bin" "$HOME/.local/bin"; do
            if [ -f "$directory/opencode" ] && [ -x "$directory/opencode" ]; then
                opencode_bin="$directory/opencode"
                break
            fi
        done
    fi
fi
if [ ! -f "$opencode_bin" ] || [ ! -x "$opencode_bin" ]; then
    echo '{"status":"skipped","reason":"opencode-not-installed"}'
    exit 0
fi
mkdir -p "$config_dir"
# Kernel lock is released even if installation is interrupted.
/usr/bin/lockf -k -t 0 "$config_dir/.captions-navigation-install.lock" \
    /usr/bin/osascript -l JavaScript "$resource_dir/install.js" "$resource_dir/captions-navigation.mjs" "$config_dir"
