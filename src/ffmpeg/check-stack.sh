#!/bin/sh
set -eu

# readelf inspects either target architecture without executing target code.
if [ "$#" -eq 0 ]; then
    echo 'ERROR: No FFmpeg ELF files supplied for stack verification.' >&2
    exit 1
fi
for ELF do
    HEADERS="$(LC_ALL=C readelf --wide --program-headers "$ELF")"
    STACK_SIZE="$(printf '%s\n' "$HEADERS" | awk '$1 == "GNU_STACK" { print $6 }')"
    case "$STACK_SIZE" in
        0x[0-9a-fA-F]*)
            case "${STACK_SIZE#0x}" in
                *[!0-9a-fA-F]*) STACK_SIZE=invalid ;;
            esac
            ;;
        *) STACK_SIZE=invalid ;;
    esac
    if [ "$STACK_SIZE" = invalid ] || [ "$((STACK_SIZE))" -lt 2097152 ]; then
        echo "ERROR: $ELF needs a PT_GNU_STACK reservation of at least 2097152 bytes (found $STACK_SIZE)." >&2
        exit 1
    fi
    printf 'Verified PT_GNU_STACK: %s (%s bytes)\n' "$ELF" "$((STACK_SIZE))"
done
