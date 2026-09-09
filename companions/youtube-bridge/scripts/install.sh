#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
host_name="com.ethan.youtube_spotify_media_key"
extension_id="kjcofljkanbdomkahdicnibojcoagmjl"
binary_path="$repo_root/dist/native-host/youtube-spotify-media-key-host"
menu_bar_app="$repo_root/dist/menu-bar/YouTube Spotify Media Key.app"
installed_menu_bar_app="$HOME/Applications/YouTube Spotify Media Key.app"
launch_agent_label="com.ethan.youtubeSpotifyMediaKey"
launch_agent_path="$HOME/Library/LaunchAgents/$launch_agent_label.plist"
manifest_dir="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
manifest_path="$manifest_dir/$host_name.json"

"$repo_root/scripts/build.sh"

mkdir -p "$manifest_dir"
mkdir -p "$(dirname "$launch_agent_path")"
mkdir -p "$HOME/Applications"

pkill -f "youtube-spotify-media-key-app" >/dev/null 2>&1 || true
rm -rf "$installed_menu_bar_app"
/usr/bin/ditto "$menu_bar_app" "$installed_menu_bar_app"

# Serialize paths instead of interpolating them into JSON/XML: spaces, quotes and
# ampersands in a checkout or account name must not corrupt the registration.
python3 - "$manifest_path" "$binary_path" "$host_name" "$extension_id" "$launch_agent_path" "$launch_agent_label" "$installed_menu_bar_app" <<'PYCONFIG'
import json, plistlib, sys
manifest, binary, host, extension, agent, label, app = sys.argv[1:]
with open(manifest, 'w') as out:
    json.dump({'name': host, 'description': 'VoiceInk YouTube Bridge native host.',
               'path': binary, 'type': 'stdio',
               'allowed_origins': ['chrome-extension://' + extension + '/']}, out, indent=2)
with open(agent, 'wb') as out:
    plistlib.dump({'Label': label, 'ProgramArguments': ['/usr/bin/open', '-g', app],
                  'RunAtLoad': True}, out)
PYCONFIG

launchctl bootout "gui/$(id -u)" "$launch_agent_path" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$launch_agent_path" >/dev/null 2>&1 || true
if ! open -g "$installed_menu_bar_app"; then
  executable_path="$installed_menu_bar_app/Contents/MacOS/youtube-spotify-media-key-app"
  if ! pgrep -f "$executable_path" >/dev/null 2>&1; then
    "$executable_path" >/dev/null 2>&1 & # Bug fix: LaunchServices can return -600 even after the launch agent starts the helper; repro by install exiting after build with "_LSOpenURLsWithCompletionHandler() failed".
  fi
fi

echo
echo "Installed Chrome native messaging host:"
echo "$manifest_path"
echo
echo "Installed menu bar app:"
echo "$installed_menu_bar_app"
echo
echo "Installed menu bar app launch agent:"
echo "$launch_agent_path"
echo
echo "Load this folder in chrome://extensions:"
echo "$repo_root/dist/extension"
echo
echo "Hardware media-key routing is disabled by design; Accessibility is not required for VoiceInk YouTube auto-pause."
