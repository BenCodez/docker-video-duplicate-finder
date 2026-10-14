#!/bin/sh

set -e # Exit immediately if a command exits with a non-zero status.
set -u # Treat unset variables as an error.

# Install defaults only for a new configuration. Recreating missing established
# settings would discard saved cleanup protections before the app can detect it.
if [ ! -f /config/Settings.json ]; then
    for STATE_FILE in /config/.vdf-settings-initialized /config/Settings.* \
        /config/ScannedFiles.db* /config/ReviewedFiles.json* \
        /config/SelectionPlan.json* /config/QuarantineHistory.json* \
        /config/CleanupProtectionPolicy.json* /config/BlacklistedGroups.json* \
        /config/backup.scanresults* /config/log.txt
    do
        if [ -e "$STATE_FILE" ] || [ -L "$STATE_FILE" ]; then
            echo "Settings.json is missing or unreadable in an existing configuration; restore it before starting." >&2
            exit 1
        fi
    done
    cp /defaults/Settings.json /config/Settings.json
fi

# Handle dark mode.
# ThemeMode: 1 = Light, 2 = Dark. DarkMode is the legacy switch and is ignored
# once ThemeMode is set.
if is-bool-val-true "${DARK_MODE:-0}"; then
    THEME_VAL=2
else
    THEME_VAL=1
fi
# Validate before atomically replacing: a corrupt settings file must not be
# silently truncated or reset, and unknown/new settings must survive startup.
SETTINGS_TMP="$(mktemp /config/.vdf-settings.XXXXXX)"
trap 'rm -f "$SETTINGS_TMP"' EXIT HUP INT TERM
cp -p /config/Settings.json "$SETTINGS_TMP"
jq -e -s -c -M --argjson theme "$THEME_VAL" \
    'if length != 1 or (.[0] | type) != "object" then error("Settings.json must contain exactly one object") else .[0] | del(.DarkMode) | .ThemeMode = $theme end' \
    /config/Settings.json > "$SETTINGS_TMP"
mv -f "$SETTINGS_TMP" /config/Settings.json
touch /config/.vdf-settings-initialized

# vim:ft=sh:ts=4:sw=4:et:sts=4
