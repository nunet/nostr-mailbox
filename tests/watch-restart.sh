#!/usr/bin/env bash
# tests/watch-restart.sh -- the watcher ends itself when its file is replaced.
#
# An install swaps the mailbox file, but a running `mailbox watch` keeps the code
# it loaded. It must notice, end at an idle point with its lock released, and
# leave the restart to mailbox-watch-start. Relay-free, like team-and-watch.sh:
# it sources a COPY of the mailbox (so the copy can be replaced), with cmd_fetch
# stubbed, typing into a pane on a PRIVATE tmux socket.
#
# Run: tests/watch-restart.sh   (exits non-zero if any case fails)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
sock="mbtest$$"
w=""
cleanup() { [[ -z "$w" ]] || kill "$w" 2>/dev/null || true; tmux -L "$sock" kill-session -t pane 2>/dev/null || true; rm -rf "$work"; }
trap cleanup EXIT

cp "$here/../mailbox" "$work/mailbox"
sec="$(nak key generate)"
printf '{ "me": {"npub": "npub1me", "pubkey_hex": "%s"} }\n' "$(printf %s "$sec" | nak key public)" > "$work/registry.json"
export MAILBOX_AVATAR=me MAILBOX_REGISTRY="$work/registry.json" MAILBOX_ROOT="$work/mail"
export MAILBOX_WATCH_TMUX_SOCKET="$sock" MAILBOX_WATCH_INTERVAL=1
export NOSTR_MAILBOX_RELAY="ws://127.0.0.1:1"   # tests never reach a real relay
export NOSTR_MAILBOX_NSEC="$sec"
# shellcheck disable=SC1090
source "$work/mailbox" >/dev/null
md_init
cmd_fetch() { :; }
tmux -L "$sock" new-session -d -s pane -x 200 -y 20 'cat'

fails=0
is() { # <expected> <got> <label>
    if [[ "$1" == "$2" ]]; then printf 'ok: %s\n' "$3"
    else printf 'FAIL: %s -- expected %q, got %q\n' "$3" "$1" "$2"; fails=$((fails+1)); fi
}
alive() { # a zombie (ended, not yet waited for) counts as ended
    local s; s="$(cat "/proc/$1/stat" 2>/dev/null)" || { echo no; return; }
    [[ "${s##*) }" == Z* ]] && echo no || echo yes
}
ended_by() { # <pid> -> $ended: its exit code, waiting up to 5 s, or "running"
    local _; ended=running
    for _ in $(seq 50); do
        [[ "$(alive "$1")" == no ]] && { ended=0; wait "$1" || ended=$?; return 0; }
        sleep 0.1
    done
}
lock_free() { ( exec 8>"$WATCH/lock"; flock -n 8 ) && echo yes || echo no; }

# Unchanged: it keeps watching.
( cmd_watch pane ) 2>/dev/null & w=$!
sleep 2.5
is yes "$(alive "$w")" "an unchanged file: the watcher keeps running"

# Replaced the way install does it (copy, then rename over): new inode.
cp "$work/mailbox" "$work/mailbox.new" && mv "$work/mailbox.new" "$work/mailbox"
ended_by "$w"; is 0 "$ended" "the file replaced: the watcher exits 0, so the wrapper restarts it"
is yes "$(lock_free)" "and its lock is free for the new one"
is 1 "$(grep -c 'changed on disk' "$WATCH/log")" "and it says why in the watch log"

# Rewritten in place: same inode, new mtime.
( cmd_watch pane ) 2>/dev/null & w=$!
sleep 1.5
touch -d '+5 seconds' "$work/mailbox"
ended_by "$w"; is 0 "$ended" "the file rewritten in place: the watcher exits 0 too"

if (( fails )); then printf '\n%d case(s) FAILED\n' "$fails"; exit 1; fi
printf 'all watch-restart cases passed\n'
