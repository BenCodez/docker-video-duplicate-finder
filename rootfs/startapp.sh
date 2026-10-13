#!/bin/sh
set -eu

# The desktop process and its scheduler run independently of browser/VNC clients.
export DOTNET_RUNNING_IN_CONTAINER=true
export XDG_CONFIG_HOME=/config/.config
export XDG_STATE_HOME=/config/.local/state
export XDG_CACHE_HOME=/config/.cache
export TMPDIR=/config/.cache/vdf/tmp
mkdir -p "$XDG_CONFIG_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME" "$TMPDIR"
cd /storage
exec /opt/vdf/VDF.GUI --settings /config/Settings.json
# vim:ft=sh:ts=4:sw=4:et:sts=4
