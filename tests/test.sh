#!/usr/bin/env bash
# ot end to end, in a throwaway HOME: every command, once with
# `emacs --batch` (OT_DAEMON=0) and once through a daemon ot starts itself.
# Then Emacs itself reads the file ot wrote. Needs ot, emacs and jq on PATH.
set -euo pipefail

t=$(mktemp -d)
export HOME=$t/home XDG_RUNTIME_DIR=$t/run TMPDIR=$t
mkdir -p "$HOME" "$XDG_RUNTIME_DIR"
here=$(cd "$(dirname "$0")" && pwd)

pass=0
no() {
  echo "not ok - $1" >&2
  exit 1
}
ok() {
  echo "ok - $1"
  pass=$((pass + 1))
}
same() {
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1: expected [$2], got [$3]"; fi
}

for mode in 0 auto; do
  export OT_DAEMON=$mode OT_FILE=$t/$mode/jdex.org
  mkdir -p "$t/$mode"
  cp "$here/jdex.org" "$OT_FILE"
  chmod u+w "$OT_FILE"
  m="[$mode]"

  ot add Call the bank >/dev/null
  same "$m add without --under goes in the inbox" Inbox "$(ot ls --json | jq -r '.[0].under')"
  OT_INBOX=11.01 ot add File the receipt >/dev/null
  same "$m OT_INBOX names the inbox by number" 11.01 \
    "$(ot ls --json | jq -r '.[] | select(.title == "File the receipt") | .under')"

  ot add Renew it --under 11.11 --due 2026-12-01 >/dev/null
  same "$m --under an ID, with a deadline" '11.11 <2026-12-01 Tue>' \
    "$(ot ls --under 11.11 --json | jq -r '.[0] | "\(.under) \(.deadline)"')"

  ot add 'Say "hi" \ back' --under W0011 --state NEXT >/dev/null
  same "$m --under a work package, quotes kept" 'W0011 NEXT Say "hi" \ back' \
    "$(ot ls --under W0011 --json | jq -r '.[0] | "\(.under) \(.state) \(.title)"')"
  ot add Pack --under W0012~11.11 >/dev/null
  same "$m --under W0012~11.11 finds it by its title" W0012~11.11 \
    "$(ot ls --under W0012 --json | jq -r '.[0].under')"

  err=$(ot add x --under W0011~12.11 2>&1) && no "$m wrong address accepted"
  same "$m --under refuses a work package from another ID" \
    'ot: W0011 is "W0011~11.11 Renew passport", not under 12.11' "$err"
  err=$(ot add x --under 99.99 2>&1) && no "$m missing heading accepted"
  ok "$m --under refuses a missing heading"
  err=$(ot add x --state NOPE 2>&1) && no "$m bad state accepted"
  ok "$m add refuses an unknown state"

  same "$m ls lists the open tasks" 5 "$(ot ls --json | jq length)"
  same "$m ls --state" 1 "$(ot ls --state NEXT --json | jq length)"
  same "$m ls of an empty subtree is []" '[]' "$(ot ls --under 11.01 --state WAIT --json)"

  id=$(ot ls --under W0011 --json | jq -r '.[0].id')
  same "$m ids are 8 characters" 8 "${#id}"
  ot set "$id" WAIT >/dev/null
  same "$m set changes the state" WAIT "$(ot ls --under W0011 --json | jq -r '.[0].state')"
  ot "done" "$id" >/dev/null
  same "$m done hides it from ls" 0 "$(ot ls --under W0011 --json | jq length)"
  same "$m ls --all shows it" DONE "$(ot ls --under W0011 --all --json | jq -r '.[0].state')"

  where=$(ot where "$id")
  same "$m where gives the heading's line" '*** DONE Say "hi" \ back' \
    "$(sed -n "${where##*:}p" "$OT_FILE")"
  same "$m open runs OT_EDITOR with +LINE FILE" "+${where##*:} $OT_FILE" \
    "$(OT_EDITOR="echo" ot open "$id")"

  # Emacs, not ot, reads what ot wrote
  got=$(emacs -Q --batch "$OT_FILE" --eval '(progn (require (quote org-lint))
    (princ (format "%d %S" (length (org-map-entries t "TODO=\"TODO\"")) (org-lint))))' 2>/dev/null)
  same "$m Org reads the file, and org-lint finds nothing" '4 nil' "$got"
done

ot stop
emacsclient -s ot --eval t >/dev/null 2>&1 && no "stop left the daemon running"
ok "stop stops the daemon"

# auto mode used a daemon, and one on an absolute socket path, as the
# service runs it, works the same
export OT_DAEMON=auto OT_SOCKET=$t/sock/server
ot ls >/dev/null
emacsclient -s "$OT_SOCKET" --eval t >/dev/null 2>&1 || no "no daemon on $OT_SOCKET"
ok "ot starts a daemon on OT_SOCKET"
same "and it serves the same tasks" 4 "$(ot ls --json | jq length)"
ot stop
echo "$pass passed"
