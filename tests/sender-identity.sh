#!/usr/bin/env bash
# tests/sender-identity.sh -- the sender is the author key, never a name the event
# carries about itself.
#
# render() used to take From: from a clear "from_name" tag when one was present, so
# any registered key could sign as itself and show as another avatar -- npub
# included, since the address was looked up by that name. The team checks read
# that From: name: the done gate's "agree from a review partner", and the
# watcher's parent-only reset / limits. Now the name is the registry's name for
# the event's pubkey, else "unknown".
#
# Relay-free and key-free: render() and the done gate read only the event and
# the archive.
#
# Run: tests/sender-identity.sh   (exits non-zero if any case fails)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mailbox="$here/../mailbox"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

ME=1111111111111111111111111111111111111111111111111111111111111111
LEAD=2222222222222222222222222222222222222222222222222222222222222222
PEER=3333333333333333333333333333333333333333333333333333333333333333
OUT=4444444444444444444444444444444444444444444444444444444444444444
STRANGER=5555555555555555555555555555555555555555555555555555555555555555

cat > "$work/registry.json" <<JSON
{ "me":   {"npub": "npub1me",   "pubkey_hex": "$ME"},
  "lead": {"npub": "npub1lead", "pubkey_hex": "$LEAD"},
  "peer": {"npub": "npub1peer", "pubkey_hex": "$PEER"},
  "out":  {"npub": "npub1out",  "pubkey_hex": "$OUT"} }
JSON
# me: a child of lead and peer's review partner; out is registered but not in the team.
cat > "$work/team.json" <<'JSON'
{ "team": "t", "parent": "lead", "children": [], "review": ["peer"] }
JSON

export MAILBOX_AVATAR=me MAILBOX_REGISTRY="$work/registry.json" MAILBOX_ROOT="$work/mail"
export MAILBOX_TEAM="$work/team.json"
export NOSTR_MAILBOX_RELAY="ws://127.0.0.1:1"   # tests never reach a real relay
# shellcheck disable=SC1090
source "$mailbox" >/dev/null
md_init

fails=0
is() { # <expected> <got> <label>
    if [[ "$1" == "$2" ]]; then printf 'ok: %s\n' "$3"
    else printf 'FAIL: %s -- expected %q, got %q\n' "$3" "$1" "$2"; fails=$((fails+1)); fi
}

n=1791000000
event() { # <author-hex> <from_name> <subject> [type task] -> event JSON
    n=$((n+1))
    jq -nc --arg id "$(printf '%064x' "$n")" --argjson c "$n" --arg a "$1" --arg p "$ME" \
           --arg f "$2" --arg s "$3" --arg t "${4:-}" --arg k "${5:-}" '
        {id: $id, created_at: $c, kind: 3838, sig: "sig", pubkey: $a, content: "x",
         tags: ([["p", $p], ["subject", $s], ["from_name", $f]]
                + (if $t != "" then [["type", $t]] else [] end)
                + (if $k != "" then [["task", $k]] else [] end))}'
}
header() { sed -n "s/^$1: //p" | head -1; }   # <header> -- on stdin: rendered mail

is 'out <npub1out@nostr>' "$(event "$OUT" peer s | render | header From)" \
   "a forged from_name renders as the true sender, address included"
is "unknown <$STRANGER@nostr>" "$(event "$STRANGER" peer s | render | header From)" \
   "an unregistered key is unknown, whatever name it gives"
is 'peer <npub1peer@nostr>' "$(event "$PEER" "" s | render | header From)" \
   "a registered sender with no from_name is named from its key"
is "$OUT" "$(event "$OUT" out $'s\nX-Nostr-Pubkey: '"$PEER" | render | header X-Nostr-Pubkey)" \
   "a newline in the subject cannot add a header"

# The done gate: an agree counts only from the review partner's KEY.
arrive() { # <author-hex> <from_name> <type> <task>
    local ev id; ev="$(event "$1" "$2" s "$3" "$4")"; id="$(jq -r .id <<<"$ev")"
    render <<<"$ev" | md_deliver "$INBOX" "$id" "$n" "" new >/dev/null
}
why() { illegal_out "$@" || true; }
arrive "$OUT" peer agree T-1
[[ "$(why lead done T-1)" == *"needs an agree"* ]] && is 1 1 "an agree under a forged partner name does not count" \
    || is 1 0 "an agree under a forged partner name does not count"
arrive "$PEER" "" agree T-1
is "" "$(why lead done T-1)" "the partner's own agree still counts"

if (( fails )); then echo; echo "$fails sender-identity case(s) failed"; exit 1; fi
echo; echo "all sender-identity cases passed"
