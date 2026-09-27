#!/bin/bash
# Enforce age, total saved-event size, and minimum free-space limits.
set -euo pipefail

umask 077

STORAGE_ROOT="/var/lib/security-cam"
SAVED_DIR="$STORAGE_ROOT/saved_events"
CONFIG="/etc/security-cam/storage.conf"

MAX_EVENT_GIB=8
MAX_EVENT_AGE_DAYS=14
MIN_FREE_GIB=2

# Refuse to create/prune directories on the eMMC if removable storage is not
# mounted. This also protects manual invocations of the script.
if ! /usr/bin/mountpoint -q "$STORAGE_ROOT"; then
    logger -t security-cam -- "recording storage is not mounted at $STORAGE_ROOT; prune skipped"
    exit 1
fi

if [[ -r "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG"
fi

MAX_EVENT_BYTES=$((MAX_EVENT_GIB * 1024 * 1024 * 1024))
MIN_FREE_BYTES=$((MIN_FREE_GIB * 1024 * 1024 * 1024))

mkdir -p "$SAVED_DIR"

ACTIVE_DEST=""
STATE_FILE="/var/lib/security-cam/.current_event"
if [[ -r "$STATE_FILE" ]]; then
    mapfile -t state < "$STATE_FILE"
    if ((${#state[@]} >= 2)); then
        ACTIVE_DEST="${state[1]}"
    fi
fi

is_active_path() {
    [[ -n "$ACTIVE_DEST" && "$1" == "$ACTIVE_DEST" ]]
}

# Age-based cleanup first. Never remove the currently active event.
while IFS= read -r dir; do
    [[ -d "$dir" ]] || continue
    is_active_path "$dir" && continue
    rm -rf -- "$dir"
done < <(
    find "$SAVED_DIR" -mindepth 1 -maxdepth 1 -type d \
        -mtime "+$MAX_EVENT_AGE_DAYS" -print
)

# Repeatedly remove the oldest inactive event until both the configured
# total-event cap and the free-space floor are satisfied.
while :; do
    total_bytes="$(du -s -B1 "$SAVED_DIR" 2>/dev/null | awk '{print $1}')"
    free_bytes="$(df -B1 --output=avail "$SAVED_DIR" | tail -n 1 | tr -d ' ' )"

    if (( total_bytes <= MAX_EVENT_BYTES && free_bytes >= MIN_FREE_BYTES )); then
        break
    fi

    oldest=""
    while IFS= read -r candidate; do
        if ! is_active_path "$candidate"; then
            oldest="$candidate"
            break
        fi
    done < <(
        find "$SAVED_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' \
            | LC_ALL=C sort -n \
            | sed 's/^[^ ]* //'
    )

    if [[ -z "$oldest" ]]; then
        # Only the active event remains, so there is nothing safe to prune.
        break
    fi

    rm -rf -- "$oldest"
done
