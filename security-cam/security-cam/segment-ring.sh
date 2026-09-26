#!/bin/bash
# Keep a rolling set of immutable 30-second MJPEG segments.
#
# Motion remains the only process that opens /dev/video0. ffmpeg only reads
# Motion's local multipart-MJPEG stream and remuxes the frames with -c:v copy.
#
# IMPORTANT: unlike the previous version, files are never overwritten in
# place. Each segment gets a unique filename. The cleanup loop only unlinks
# old, completed segment names; hard links held by an event remain valid.
set -euo pipefail

umask 077

STREAM_URL="http://127.0.0.1:8081/"
STORAGE_ROOT="/var/lib/security-cam"
RING_DIR="$STORAGE_ROOT/ring"
SEGMENT_SECONDS=30
KEEP_COMPLETED_SEGMENTS=13
# Keep one extra filename for the currently-open segment. This gives the
# event collector enough margin to preserve the current segment plus the
# next 12 full segments without racing ring cleanup.
KEEP_FILENAMES=$((KEEP_COMPLETED_SEGMENTS + 1))
SEGMENT_LIST="$RING_DIR/segments.list"
CLEANUP_INTERVAL=5

# Never fall back to the BBB eMMC if the removable recording filesystem is
# absent. This check is intentionally inside the script in addition to the
# systemd mount condition so manual execution is protected too.
if ! /usr/bin/mountpoint -q "$STORAGE_ROOT"; then
    logger -t security-cam -- "recording storage is not mounted at $STORAGE_ROOT; refusing to start ring writer"
    echo "ERROR: $STORAGE_ROOT is not a mount point; refusing to write to eMMC." >&2
    exit 1
fi

mkdir -p "$RING_DIR"

cleanup_ring() {
    local -a files
    mapfile -t files < <(
        find "$RING_DIR" -maxdepth 1 -type f -name 'segment-*.avi' -printf '%f\n' \
            | LC_ALL=C sort -r
    )

    local count=${#files[@]}
    local i
    if (( count > KEEP_FILENAMES )); then
        for ((i=KEEP_FILENAMES; i<count; i++)); do
            rm -f -- "$RING_DIR/${files[$i]}"
        done
    fi
}

# Start each ffmpeg instance with a unique, monotonically increasing-ish
# starting index. The timestamp component prevents normal service restarts
# from reusing old filenames.
START_INDEX="$(date +%s)"
# FFmpeg's segment_start_number is a signed 32-bit integer on the
# packaged builds this project targets. Unix seconds are safely within that
# range for the lifetime of Debian 12 and still give a practically unique
# starting index across service restarts.
START_INDEX=$((START_INDEX + (BASHPID % 1000)))

/usr/bin/ffmpeg \
    -nostdin \
    -y \
    -hide_banner \
    -loglevel warning \
    -reconnect 1 \
    -reconnect_streamed 1 \
    -reconnect_delay_max 5 \
    -i "$STREAM_URL" \
    -map 0:v:0 \
    -c:v copy \
    -an \
    -f segment \
    -segment_time "$SEGMENT_SECONDS" \
    -segment_start_number "$START_INDEX" \
    -reset_timestamps 1 \
    -segment_list "$SEGMENT_LIST" \
    -segment_list_flags +live \
    -segment_list_size "$KEEP_COMPLETED_SEGMENTS" \
    -segment_list_type flat \
    "$RING_DIR/segment-%016d.avi" &

FFMPEG_PID=$!

terminate() {
    kill -TERM "$FFMPEG_PID" 2>/dev/null || true
    wait "$FFMPEG_PID" 2>/dev/null || true
    exit 143
}
trap terminate INT TERM

while kill -0 "$FFMPEG_PID" 2>/dev/null; do
    cleanup_ring
    sleep "$CLEANUP_INTERVAL"
done

wait "$FFMPEG_PID"
