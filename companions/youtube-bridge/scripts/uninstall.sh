#!/usr/bin/env bash
set -euo pipefail

host_name="com.ethan.youtube_spotify_media_key"
manifest_path="$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/$host_name.json"
launch_agent_label="com.ethan.youtubeSpotifyMediaKey"
launch_agent_path="$HOME/Library/LaunchAgents/$launch_agent_label.plist"
installed_menu_bar_app="$HOME/Applications/YouTube Spotify Media Key.app"

rm -f "$manifest_path"
launchctl bootout "gui/$(id -u)" "$launch_agent_path" >/dev/null 2>&1 || true
rm -f "$launch_agent_path"
pkill -f "youtube-spotify-media-key-app" >/dev/null 2>&1 || true
rm -rf "$installed_menu_bar_app"

echo "Removed Chrome native messaging host manifest:"
echo "$manifest_path"
echo
echo "Removed menu bar app launch agent:"
echo "$launch_agent_path"
echo
echo "Removed menu bar app:"
echo "$installed_menu_bar_app"
