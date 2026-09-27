#!/bin/bash
# Motion event hook.
#
# A motion trigger creates (or extends) an event capture window. The active
# event receives up to 12 completed 30-second segments immediately before
# the trigger (pre-roll), then the current segment plus 12 more completed
# 30-second segments after it (13 post-trigger files total). This guarantees
# at least six minutes of post-trigger coverage even when motion fires near a
# segment boundary.
#
# Segment files are immutable once closed. We use hard links instead of cp:
# the saved event gets its own directory entry without copying the video
# data a second time. Removing the ring's old filename therefore cannot
# destroy an already-saved event.
set -euo pipefail

umask 077

STORAGE_ROOT="/var/lib/security-cam"
RING_DIR="$STORAGE_ROOT/ring"
SEGMENT_LIST="$RING_DIR/segments.list"
SAVED_DIR="$STORAGE_ROOT/saved_events"
STATE_FILE="$STORAGE_ROOT/.current_event"
LOCK_FILE="$STORAGE_ROOT/.event.lock"
PRUNE_SCRIPT="/opt/security-cam/prune-saved-events.sh"
POST_SEGMENTS=13
PREROLL_SEGMENTS=12
MAX_GRACE_SECONDS=900
POLL_SECONDS=2

MODE="${1:-}"

# Motion hooks must never create event state or recordings on the eMMC when
# the removable recording filesystem is missing.
if ! /usr/bin/mountpoint -q "$STORAGE_ROOT"; then
    logger -t security-cam -- "recording storage is not mounted at $STORAGE_ROOT; ignoring event hook"
    exit 1
fi

mkdir -p "$RING_DIR" "$SAVED_DIR"
exec 9>"$LOCK_FILE"

log_msg() {
    logger -t security-cam -- "$*"
}

list_indices() {
    [[ -r "$SEGMENT_LIST" ]] || return 0
    sed -n 's#^segment-\([0-9][0-9]*\)\.avi$#\1#p' "$SEGMENT_LIST"
}

latest_completed_index() {
    list_indices | tail -n 1
}

latest_ring_index() {
    find "$RING_DIR" -maxdepth 1 -type f -name 'segment-*.avi' -printf '%f\n' \
        | sed -n 's#^segment-\([0-9][0-9]*\)\.avi$#\1#p' \
        | LC_ALL=C sort -n | tail -n 1
}

link_if_absent() {
    local src="$1" dest_dir="$2" base
    base="$(basename "$src")"
    # ln is intentional: the ring and saved-event tree share one filesystem.
    # An event therefore gets a second directory entry for the same immutable
    # video inode without copying the video payload again.
    ln -- "$src" "$dest_dir/$base" 2>/dev/null || true
}

link_preroll() {
    local dest="$1" base_index="$2"
    local -a candidates
    mapfile -t candidates < <(
        list_indices | awk -v base="$base_index" '$1 < base' | tail -n "$PREROLL_SEGMENTS"
    )

    local idx src
    for idx in "${candidates[@]}"; do
        src="$RING_DIR/segment-${idx}.avi"
        [[ -f "$src" ]] && link_if_absent "$src" "$dest"
    done
}

write_state() {
    local ts="$1" dest="$2" base="$3" deadline="$4"
    local tmp="${STATE_FILE}.tmp.$$"
    printf '%s\n%s\n%s\n%s\n' "$ts" "$dest" "$base" "$deadline" > "$tmp"
    chmod 0600 "$tmp"
    mv -f -- "$tmp" "$STATE_FILE"
}

read_state() {
    [[ -f "$STATE_FILE" ]] || return 1
    mapfile -t STATE < "$STATE_FILE"
    ((${#STATE[@]} >= 4)) || return 1
    STATE_TS="${STATE[0]}"
    STATE_DEST="${STATE[1]}"
    STATE_BASE="${STATE[2]}"
    STATE_DEADLINE="${STATE[3]}"
}

run_worker() {
    local dest base base_num deadline target idx idx_num src post_count now hard_deadline latest_deadline latest_base current_ring current_num

    while :; do
        flock -x 9
        if ! read_state; then
            flock -u 9
            exit 0
        fi
        dest="$STATE_DEST"
        base="$STATE_BASE"
        deadline="$STATE_DEADLINE"
        flock -u 9

        [[ -d "$dest" ]] || exit 0

        # If an event fires during the first segment after boot, there may be
        # no completed segment in the FFmpeg list yet. Wait for that first
        # completion, then treat it as the current segment (base = first-1).
        if [[ "$base" == "WAITING" ]]; then
            current_ring="$(latest_ring_index || true)"
            if [[ -z "$current_ring" ]]; then
                now="$(date +%s)"
                hard_deadline=$((deadline + MAX_GRACE_SECONDS))
                if (( now >= hard_deadline )); then
                    flock -x 9
                    if read_state && [[ "$STATE_BASE" == "WAITING" ]]; then
                        rm -f -- "$STATE_FILE"
                        log_msg "event $STATE_TS timed out before the ring created its first segment"
                    fi
                    flock -u 9
                    "$PRUNE_SCRIPT" || true
                    exit 0
                fi
                sleep "$POLL_SECONDS"
                continue
            fi

            # The newest ring filename is created as soon as FFmpeg starts a
            # segment. If no completed-list entry existed at trigger time,
            # treat that open filename as the segment containing the trigger.
            current_num=$((10#$current_ring))
            base_num=$((current_num - 1))
            flock -x 9
            if read_state && [[ "$STATE_BASE" == "WAITING" ]]; then
                write_state "$STATE_TS" "$STATE_DEST" "$base_num" "$STATE_DEADLINE"
                base="$base_num"
                deadline="$STATE_DEADLINE"
            else
                base="$STATE_BASE"
                deadline="$STATE_DEADLINE"
            fi
            flock -u 9
        fi

        base_num=$((10#$base))
        target=$((base_num + POST_SEGMENTS))

        # FFmpeg's segment list is updated only for completed segments.
        # Therefore anything present in this list is safe to hard-link; the
        # currently-open file is not listed yet.
        while read -r idx; do
            [[ -n "$idx" ]] || continue
            idx_num=$((10#$idx))
            (( idx_num > base_num && idx_num <= target )) || continue
            src="$RING_DIR/segment-${idx}.avi"
            [[ -f "$src" ]] || continue
            link_if_absent "$src" "$dest"
        done < <(list_indices)

        post_count="$(find "$dest" -maxdepth 1 -type f -name 'segment-*.avi' -printf '%f\n' \
            | sed -n 's/^segment-\([0-9][0-9]*\)\.avi$/\1/p' \
            | awk -v base="$base_num" '$1 > base && $1 <= base + 13' | wc -l)"

        if (( post_count >= POST_SEGMENTS )); then
            flock -x 9
            if read_state; then
                latest_deadline="$STATE_DEADLINE"
                latest_base="$STATE_BASE"
                if [[ "$latest_deadline" == "$deadline" && "$latest_base" == "$base" ]]; then
                    rm -f -- "$STATE_FILE"
                    log_msg "event $STATE_TS complete: $post_count post-trigger segments plus pre-roll in $dest"
                    flock -u 9
                    "$PRUNE_SCRIPT" || log_msg "warning: event pruning failed"
                    exit 0
                fi
            fi
            flock -u 9
        fi

        now="$(date +%s)"
        hard_deadline=$((deadline + MAX_GRACE_SECONDS))
        if (( now >= hard_deadline )); then
            flock -x 9
            if read_state; then
                latest_deadline="$STATE_DEADLINE"
                latest_base="$STATE_BASE"
                if [[ "$latest_deadline" == "$deadline" && "$latest_base" == "$base" ]]; then
                    rm -f -- "$STATE_FILE"
                    log_msg "event $STATE_TS timed out: saved $post_count post-trigger segments plus pre-roll in $dest"
                    flock -u 9
                    "$PRUNE_SCRIPT" || log_msg "warning: event pruning failed"
                    exit 0
                fi
            fi
            flock -u 9
        fi

        sleep "$POLL_SECONDS"
    done
}

case "$MODE" in
    start)
        TS="${2:?missing timestamp argument}"
        flock -x 9

        BASE="$(latest_completed_index || true)"
        now="$(date +%s)"
        new_deadline=$((now + POST_SEGMENTS * 30 + 60))

        if read_state; then
            DEST="$STATE_DEST"
            # A later trigger extends the existing capture so another six
            # minutes of post-trigger coverage are retained after that
            # newer trigger. If the ring has not produced a completed
            # segment yet, preserve the WAITING state.
            deadline="$STATE_DEADLINE"
            (( new_deadline > deadline )) && deadline="$new_deadline"
            state_base="$STATE_BASE"
            if [[ -n "$BASE" ]]; then
                link_preroll "$DEST" "$BASE"
                state_base="$BASE"
            fi
            write_state "$STATE_TS" "$DEST" "$state_base" "$deadline"
            log_msg "event $STATE_TS extended by trigger $TS; base=$state_base deadline=$deadline"
        else
            DEST="$SAVED_DIR/$TS"
            mkdir -p "$DEST"
            chmod 0700 "$DEST"
            if [[ -n "$BASE" ]]; then
                link_preroll "$DEST" "$BASE"
                write_state "$TS" "$DEST" "$BASE" "$new_deadline"
                log_msg "event $TS started; base=$BASE destination=$DEST"
            else
                CURRENT_RING="$(latest_ring_index || true)"
                if [[ -n "$CURRENT_RING" ]]; then
                    CURRENT_NUM=$((10#$CURRENT_RING))
                    BASE=$((CURRENT_NUM - 1))
                    write_state "$TS" "$DEST" "$BASE" "$new_deadline"
                    log_msg "event $TS started during first ring segment; base=$BASE destination=$DEST"
                else
                    write_state "$TS" "$DEST" "WAITING" "$new_deadline"
                    log_msg "event $TS started before the ring created its first segment; collector is waiting"
                fi
            fi
            nohup "$0" worker >/dev/null 2>&1 &
        fi

        flock -u 9
        ;;

    end)
        # Do not end the collector. Motion's event ending only means that
        # event_gap expired; the security-camera requirement is to retain
        # the post-trigger six-minute recording window.
        TS="${2:-unknown}"
        log_msg "Motion event ended at $TS; post-trigger collector continues independently"
        ;;

    worker)
        run_worker
        ;;

    *)
        echo "usage: save-event.sh start|end [timestamp]" >&2
        exit 2
        ;;
esac
