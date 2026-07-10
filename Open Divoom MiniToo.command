#!/bin/zsh
# Convenience helper for this alpha release. It deliberately changes only the
# quarantine attribute on the adjacent app bundle (or its Applications copy).
set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
bundled_app="$script_dir/Divoom MiniToo.app"
installed_app="/Applications/Divoom MiniToo.app"

if [[ -d "$installed_app" ]]; then
  app="$installed_app"
elif [[ -d "$bundled_app" ]]; then
  app="$bundled_app"
else
  /usr/bin/osascript -e 'display alert "Divoom MiniToo was not found" message "Keep this helper next to Divoom MiniToo.app, or move the app to Applications and try again." as warning'
  exit 1
fi

if ! /usr/bin/osascript \
  -e 'display dialog "This alpha helper will remove macOS’s download-quarantine flag from only this copy of Divoom MiniToo, then open it.\n\nIt does not disable Gatekeeper globally or change any other app. Continue only if you downloaded this release from the project’s GitHub page." with title "Open Divoom MiniToo" buttons {"Cancel", "Open App"} default button "Open App" with icon caution'; then
  exit 0
fi

if ! /usr/bin/xattr -dr com.apple.quarantine "$app"; then
  # A copy made by the current user normally does not need elevation. If file
  # ownership differs, request macOS authentication only for this one command.
  escaped_app="$(/usr/bin/osascript -e "return quoted form of \"$app\"")"
  /usr/bin/osascript -e "do shell script \"/usr/bin/xattr -dr com.apple.quarantine $escaped_app\" with administrator privileges"
fi

/usr/bin/open "$app"
