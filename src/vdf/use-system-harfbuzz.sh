#!/bin/sh
set -eu

APP_DIR="${1:-/opt/vdf}"
NATIVE_LIBRARY="${2:-/usr/lib/libharfbuzz.so.0}"
REQUIRED_SYMBOLS="${3:-$(dirname "$0")/harfbuzz-8.3.1.3-symbols.txt}"

# GTK/Pango and HarfBuzzSharp must use one native HarfBuzz on musl. Loading
# distinct releases allows internal public-symbol calls to interpose, mixing
# private object layouts. The managed wrapper consumes HarfBuzz's stable C ABI.
# This inventory comes from the pinned managed assembly's LibraryImport methods;
# a managed-version change requires regenerating and reviewing the inventory.
jq -e '.libraries["HarfBuzzSharp/8.3.1.3"] != null' "$APP_DIR/VDF.GUI.deps.json" >/dev/null
test -r "$NATIVE_LIBRARY"
test -f "$APP_DIR/libHarfBuzzSharp.so"
test "$(wc -l < "$REQUIRED_SYMBOLS")" -eq 319

EXPORTS="$(mktemp)"
trap 'rm -f "$EXPORTS"' EXIT
readelf --dyn-syms --wide "$NATIVE_LIBRARY" | awk \
    '$4 == "FUNC" && ($5 == "GLOBAL" || $5 == "WEAK") && \
     ($6 == "DEFAULT" || $6 == "PROTECTED") && $7 != "UND" \
     { sub(/@.*/, "", $8); print $8 }' > "$EXPORTS"
test -s "$EXPORTS"
awk 'NR == FNR { exported[$1] = 1; next }
     !($1 in exported) { print "Missing HarfBuzz C ABI symbol: " $1 > "/dev/stderr"; missing = 1 }
     END { exit missing }' "$EXPORTS" "$REQUIRED_SYMBOLS"

# Replace only after the dependency and complete import checks succeed.
ln -sf "$NATIVE_LIBRARY" "$APP_DIR/libHarfBuzzSharp.so"
printf 'HarfBuzzSharp managed: 8.3.1.3\nNative library: %s\nVerified C imports: 319\n' \
    "$NATIVE_LIBRARY" > "$APP_DIR/NativeFontRuntime.txt"
echo 'Verified HarfBuzzSharp C ABI and selected the system native HarfBuzz.'
