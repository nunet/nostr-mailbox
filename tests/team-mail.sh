#!/usr/bin/env bash
# tests/team-mail.sh -- the lead claims the team's own mail.
#
# Relay-free: throwaway keys and real nak for the crypto; nak_fetch and
# nak_fetch_team are replaced after sourcing, so "the relay" is a file. The
# claimant is whoever holds NOSTR_TEAM_NSEC -- the view is shape, the key is
# the grant -- and claimed team mail lands in the ordinary maildir with To:
# the team.
#
# Run: tests/team-mail.sh   (exits non-zero if any case fails)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mailbox="$here/../mailbox"

work="$(mktemp -d)"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT

key() { local s; s="$(nak key generate)"; printf '%s %s' "$s" "$(printf %s "$s" | nak key public)"; }
read -r ME_SEC ME <<<"$(key)"; read -r KID_SEC KID <<<"$(key)"; read -r TEAM_SEC TEAM <<<"$(key)"

cat > "$work/registry.json" <<JSON
{ "me":  {"npub": "npub1me",  "pubkey_hex": "$ME"},
  "kid": {"npub": "npub1kid", "pubkey_hex": "$KID"},
  "t":   {"npub": "npub1t",   "pubkey_hex": "$TEAM"} }
JSON
# me: the team's lead (a top: no parent, a child under it).
cat > "$work/team.json" <<'JSON'
{ "team": "t", "parent": null, "children": ["kid"], "review": [] }
JSON

export MAILBOX_AVATAR=me MAILBOX_REGISTRY="$work/registry.json" MAILBOX_ROOT="$work/mail"
export MAILBOX_TEAM="$work/team.json"
export NOSTR_MAILBOX_RELAY="ws://127.0.0.1:1"   # tests never reach a real relay
export NOSTR_MAILBOX_NSEC="$ME_SEC"
export NOSTR_TEAM_NSEC="$TEAM_SEC"
# shellcheck disable=SC1090
source "$mailbox" >/dev/null
md_init

fails=0
is() { # <expected> <got> <label>
    if [[ "$1" == "$2" ]]; then printf 'ok: %s\n' "$3"
    else printf 'FAIL: %s -- expected %q, got %q\n' "$3" "$1" "$2"; fails=$((fails+1)); fi
}

# ── the claimant is the key holder ───────────────────────────────────────────
is "$TEAM" "$TEAM_HEX" "holding NOSTR_TEAM_NSEC makes this avatar the team's claimant"
no_key_hex="$(env -u NOSTR_TEAM_NSEC bash -c 'source "$1" >/dev/null 2>&1; echo "${TEAM_HEX:-}"' _ "$mailbox")"
is "" "$no_key_hex" "without the key there is no claim, whatever the view says"

# ── a member writes to the team; the lead's fetch claims it ──────────────────
ct="$(NOSTR_SECRET_KEY="$KID_SEC" seal "$TEAM" "to the team" "report body")"
team_ev="$(NOSTR_SECRET_KEY="$KID_SEC" nak event -k "$KIND_MESSAGE" \
    --tag "p=$TEAM" --tag "encrypted=nip44" -c "$ct" 2>/dev/null </dev/null)"
printf '%s\n' "$team_ev" > "$work/on-relay"

nak_fetch() { :; }                                  # nothing on the avatar's own address
nak_fetch_team() { cat "$work/on-relay"; }
ack_claim() { echo 0; }

out="$(cmd_fetch 2>&1)"
[[ "$out" == *"claimed 1 new"* ]] && is 1 1 "the lead's fetch claims the team's mail" \
                                  || is 1 0 "the lead's fetch claims the team's mail ($out)"
id="$(jq -r '.id' <<<"$team_ev")"
f="$(md_find "$id")"
is 1 "$([[ -n "$f" ]] && echo 1 || echo 0)" "the claimed message is in the ordinary maildir"
is "t <npub1t@nostr>" "$(hdr "$f" To)" "To: is the team, read from the registry"
is "kid <npub1kid@nostr>" "$(hdr "$f" From)" "From: is the member that wrote"
is "report body" "$(sed '1,/^$/d' "$f" | head -1)" "the body opened with the team's key"

out="$(cmd_fetch 2>&1)"
[[ "$out" == *"skipped 1 already held"* ]] && is 1 1 "a second fetch dedupes the team's mail" \
                                           || is 1 0 "a second fetch dedupes the team's mail ($out)"

# ── our own copy of mail TO the team opens without the team key ──────────────
own_ct="$(seal "$TEAM" "from the lead" "own copy")"
own_ev="$(jq -nc --arg a "$ME" --arg p "$TEAM" --arg c "$own_ct" \
    '{id:"e-own",created_at:1,kind:3838,sig:"s",pubkey:$a,content:$c,tags:[["p",$p],["encrypted","nip44"]]}')"
opened="$(printf '%s' "$own_ev" | open_event | jq -r '.content')"
is "own copy" "$opened" "a sent copy to the team opens symmetrically, with our own key"

# ── a failed team read warns, and costs nothing already claimed ──────────────
nak_fetch_team() { return "$RC_REFUSED"; }
out="$(cmd_fetch 2>&1)"
[[ "$out" == *"team mail could not be read"* && "$out" == *"claimed 0 new"* ]] \
    && is 1 1 "a failed team read warns and leaves the own-mail claim intact" \
    || is 1 0 "a failed team read warns and leaves the own-mail claim intact ($out)"

# ── doctor: the team key must derive the registry's entry ────────────────────
out="$(cmd_doctor 2>&1 || true)"
[[ "$out" == *"team key: derives $TEAM"* ]] && is 1 1 "doctor accepts the right team key" \
                                            || is 1 0 "doctor accepts the right team key"
out="$(NOSTR_TEAM_NSEC="$KID_SEC" bash -c 'source "$1" >/dev/null 2>&1; cmd_doctor 2>&1 || true' _ "$mailbox")"
[[ "$out" == *"WRONG TEAM KEY"* ]] && is 1 1 "doctor rejects a team key that derives another pubkey" \
                                   || is 1 0 "doctor rejects a team key that derives another pubkey"

echo
(( fails == 0 )) && echo "team-mail: all green" || echo "team-mail: $fails FAILED"
exit "$fails"
