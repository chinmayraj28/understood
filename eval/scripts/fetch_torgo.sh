#!/bin/bash
# Downloads the TORGO subset used by the evaluation into eval/data/torgo/ (gitignored), then
# builds eval/data/torgo/manifest.json with `hf-understand manifest`.
#
# TORGO (University of Toronto) is free for academic, non-profit use only. We use it to
# evaluate, never to train, and never put its audio in git. See eval/README.md.
#
# How it stays small: each archive is downloaded to a temporary file (resuming when the server
# drops the connection, which it often does), then only the audio (wav_arrayMic, wav_headMic),
# the prompt texts and the speaker notes are extracted, and the archive is deleted. The
# articulograph data, phoneme files and video notes are skipped. For the control speakers only
# the start of each archive is downloaded, which holds the first control speakers.
#
# Plain HTTP is used on purpose: the server's HTTPS is throttled to a few hundred bytes a second
# from some networks, while HTTP runs at 2 to 4 MB/s. The files are audio and text, never run.
#
# Usage:  eval/scripts/fetch_torgo.sh            (about 4.4 GB downloaded; under 1 GB kept)
#         CONTROL_BYTES=200000000 eval/scripts/fetch_torgo.sh   (smaller control sample)
#         ARCHIVES="F" eval/scripts/fetch_torgo.sh               (dysarthric women only, 1.1 GB)
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEST="$ROOT/eval/data/torgo"
BASE="http://www.cs.toronto.edu/~complingweb/data/TORGO"
# F: women with dysarthria (F01, F03, F04). M: men with dysarthria (M01 to M05).
# FC, MC: control speakers, only the first CONTROL_BYTES of each archive.
ARCHIVES="${ARCHIVES:-F M FC MC}"
CONTROL_BYTES="${CONTROL_BYTES:-400000000}"

mkdir -p "$DEST/raw"

size_of() { [ -f "$1" ] && stat -f%z "$1" || echo 0; }

# Downloads the first $2 bytes of an archive (or all of it when $2 is empty) into a temporary
# file, resuming after the dropped connections the server is prone to, then extracts only the
# audio, prompts and notes, and deletes the archive.
fetch() {
    local name="$1" limit="$2"
    local marker="$DEST/raw/.done-$name"
    local part="$DEST/$name.tar.bz2.part"
    if [ -f "$marker" ]; then
        echo "== $name: already fetched (delete $marker to fetch again)"
        return
    fi
    local total
    total=$(curl -sI "$BASE/$name.tar.bz2" | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r')
    if [ -z "$total" ]; then echo "== $name: server did not answer; try again later"; exit 1; fi
    local target="$total"
    if [ -n "$limit" ] && [ "$limit" -lt "$total" ]; then target="$limit"; fi
    echo "== $name: downloading $((target / 1000000)) MB of $((total / 1000000)) MB"

    local tries=0
    while [ "$(size_of "$part")" -lt "$target" ]; do
        tries=$((tries + 1))
        if [ "$tries" -gt 60 ]; then echo "== $name: gave up after 60 tries"; exit 1; fi
        local have
        have=$(size_of "$part")
        # Abort a stalled connection (under 20 kB/s for 20 s) and resume from where it stopped.
        curl -sS --fail --speed-limit 20000 --speed-time 20 \
            -r "$have-$((target - 1))" "$BASE/$name.tar.bz2" >> "$part" || sleep 3
        echo "   $name: $(( $(size_of "$part") / 1000000 )) MB"
    done

    # A partial archive (controls) ends with a bzip2/tar "truncated" error; that is expected,
    # and the manifest step drops any WAV file cut short at the end.
    bzip2 -dc "$part" 2>/dev/null \
        | tar -xf - -C "$DEST/raw" \
            --include='*/prompts/*' \
            --include='*/wav_arrayMic/*' \
            --include='*/wav_headMic/*' \
            --include='*/Notes/*' 2>/dev/null
    rm -f "$part"
    touch "$marker"
    echo "== $name: done"
}

for archive in $ARCHIVES; do
    case "$archive" in
        F|M) fetch "$archive" "" ;;
        FC|MC) fetch "$archive" "$CONTROL_BYTES" ;;
        *) echo "unknown archive $archive (use F, M, FC, MC)"; exit 1 ;;
    esac
done

echo "== kept on disk: $(du -sh "$DEST/raw" | cut -f1)"
echo "== speakers: $(ls "$DEST/raw" | tr '\n' ' ')"

echo "== building manifest"
cd "$ROOT/Packages/HFUnderstand" \
    && swift run -c release hf-understand manifest "$DEST/raw" --out "$DEST/manifest.json"
