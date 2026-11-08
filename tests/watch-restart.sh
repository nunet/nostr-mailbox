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
lock_free() { ( exec 8>"$WATCH/lock"; flock -n 8 ) && echo yes || echo no; }
ended_by() { # <pid> -> $ended: its exit code, waiting up to 5 s, or "running"
    local _; ended=running
    for _ in $(seq 50); do
        [[ "$(alive "$1")" == no ]] && { ended=0; wait "$1" || ended=$?; return 0; }
        sleep 0.1
    done
    # Still running: end it, and wait out its children's hold on the lock, so
    # the next case starts clean.
    kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true
    for _ in $(seq 30); do [[ "$(lock_free)" == yes ]] && break; sleep 0.1; done
}

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

# The rest run the watcher as its own process (its fetch fails on the dead relay
# and is only logged). Through a symlink, as `mailbox` on PATH is one: replacing
# the target is still seen.
mkdir -p "$work/run" "$work/bin"
cp "$work/mailbox" "$work/run/mailbox" && ln -s "$work/run/mailbox" "$work/bin/mailbox"
"$work/bin/mailbox" watch pane 2>/dev/null & w=$!
sleep 1.5
cp "$work/run/mailbox" "$work/run/mailbox.new" && mv "$work/run/mailbox.new" "$work/run/mailbox"
ended_by "$w"; is 0 "$ended" "started through a symlink, the target replaced: the watcher exits 0"

# Rewritten in place and longer: bash must not read on into the new text.
"$work/run/mailbox" watch pane 2>/dev/null & w=$!
sleep 1.5
printf 'echo ran > %q\n' "$work/fragment" >> "$work/run/mailbox"
ended_by "$w"; is 0 "$ended" "the file made longer in place: the watcher exits 0"
is no "$([[ -e "$work/fragment" ]] && echo yes || echo no)" "and runs nothing from the changed file"

if (( fails )); then printf '\n%d case(s) FAILED\n' "$fails"; exit 1; fi
printf 'all watch-restart cases passed\n'
