#!/usr/bin/env bash
# tests/body-guards.sh -- the body is a file, and a bad body is refused, not sent.
#
# These cases all fail BEFORE any relay call (the guard runs before publish), so
# the test needs no relay and no real key. The happy path -- a good body file
# actually publishing -- needs the relay and is covered by live QA, not here.
#
# Run: tests/body-guards.sh   (exits non-zero if any case fails)
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
mailbox="$here/../mailbox"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Minimal registry fixture: this avatar + one recipient, both with a pubkey_hex
# (any 64-hex value -- the guards never sign, so the key is never used).
cat > "$work/registry.json" <<'JSON'
{
  "tester":    { "npub": "npub1tester", "pubkey_hex": "1111111111111111111111111111111111111111111111111111111111111111" },
  "recipient": { "npub": "npub1recip",  "pubkey_hex": "2222222222222222222222222222222222222222222222222222222222222222" }
}
JSON

export MAILBOX_AVATAR="tester"
export MAILBOX_REGISTRY="$work/registry.json"
export MAILBOX_ROOT="$work/mail"
export NOSTR_MAILBOX_NSEC=""   # unused: the guard fires before any signing

fails=0
# assert the command fails AND its message contains an expected fragment
refuses() { # <expected-fragment> -- <mailbox args...>
    local want="$1"; shift; [[ "$1" == "--" ]] && shift
    local out rc=0
    out="$("$mailbox" "$@" </dev/null 2>&1)" && rc=0 || rc=$?
    if (( rc == 0 )); then
        printf 'FAIL: expected non-zero exit for: %s\n' "$*"; fails=$((fails+1)); return
    fi
    if ! grep -qF "$want" <<<"$out"; then
        printf 'FAIL: exit %d but message missing %q\n  got: %s\n' "$rc" "$want" "$out"; fails=$((fails+1)); return
    fi
    printf 'ok: refuses (%s)\n' "$want"
}

printf '' > "$work/empty"
printf '   \n\t\n' > "$work/whitespace"

refuses "no --body-file"                        -- send recipient --subject s
refuses "body file not found"                   -- send recipient --subject s --body-file "$work/nope"
refuses "body file is empty"                    -- send recipient --subject s --body-file "$work/empty"
refuses "body is only whitespace"               -- send recipient --subject s --body-file "$work/whitespace"
refuses "unexpected argument"                   -- send recipient --subject s "an inline body is no longer allowed"

if (( fails )); then
    printf '\n%d case(s) FAILED\n' "$fails"; exit 1
fi
printf '\nall body-guard cases passed\n'
