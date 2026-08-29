#!/usr/bin/env bash
# tests/reply-idempotent.sh -- marking a message replied is idempotent.
#
# Replying to a thread twice must not mv the Maildir file onto itself. This
# sources the tool for md_mark_replied (the BASH_SOURCE guard skips dispatch) so
# it needs no relay and no key.
#
# Run: tests/reply-idempotent.sh   (exits non-zero on failure)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mailbox="$here/../mailbox"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

cat > "$work/registry.json" <<'JSON'
{ "tester": { "npub": "npub1tester", "pubkey_hex": "1111111111111111111111111111111111111111111111111111111111111111" } }
JSON
export MAILBOX_AVATAR="tester"
export MAILBOX_REGISTRY="$work/registry.json"
export MAILBOX_ROOT="$work/mail"
export NOSTR_MAILBOX_NSEC=""

# shellcheck disable=SC1090
source "$mailbox"          # defines functions; dispatch is skipped when sourced
mkdir -p "$MAILBOX_ROOT"/{new,cur}

fails=0
check() { [[ -f "$1" ]] || { printf 'FAIL: %s\n' "$2"; fails=$((fails+1)); }; }

# unread (new/) -> cur/…:2,SR
f="$MAILBOX_ROOT/new/100.aaa.tester"; : > "$f"
md_mark_replied "$f"
check "$MAILBOX_ROOT/cur/100.aaa.tester:2,SR" "new/ was not marked replied"

# seen (cur/…:2,S) -> cur/…:2,SR
f="$MAILBOX_ROOT/cur/200.bbb.tester:2,S"; : > "$f"
md_mark_replied "$f"
check "$MAILBOX_ROOT/cur/200.bbb.tester:2,SR" "seen was not marked replied"

# already replied (cur/…:2,SR) -> no error, file stays (the bug this fixes)
f="$MAILBOX_ROOT/cur/300.ccc.tester:2,SR"; : > "$f"
md_mark_replied "$f"       # must not error on mv-onto-itself
check "$f" "replying twice lost or errored on the file"

if (( fails )); then printf '\n%d case(s) FAILED\n' "$fails"; exit 1; fi
printf 'all reply-idempotent cases passed\n'
