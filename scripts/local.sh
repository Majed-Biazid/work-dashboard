#!/bin/bash
# Local state for the Connections section — every minute, read-only, fast.
#   logins     — Google Cloud, GitHub, Basecamp, Linear key present
#   db proxy   — is cloud-sql-proxy running, which configured ports listen
#   kubernetes — the current kubectl context (a production context is flagged)
# Every "fix" is a command for you to copy and run; this script changes nothing.
. "$(dirname "$0")/lib.sh"; tmpdir
# the signed-in account, from gcloud's own config files: a second gcloud (Python)
# start-up every minute cost more than the token check itself
gcloud_account() {
  local d="${CLOUDSDK_CONFIG:-$HOME/.config/gcloud}" c a
  c=${CLOUDSDK_ACTIVE_CONFIG_NAME:-$(cat "$d/active_config" 2>/dev/null || echo default)}
  a=${CLOUDSDK_CORE_ACCOUNT:-$(sed -nE 's/^account *= *//p' "$d/configurations/config_$c" 2>/dev/null | head -1)}
  [ -n "$a" ] && printf '%s' "$a" || gcloud config get-value account 2>/dev/null
}
row() { jq -cn --arg n "$1" --argjson ok "$2" --arg d "$3" --arg f "$4" '{name: $n, ok: $ok, detail: $d, fix: $f}'; }
# offline, a login check can't tell "expired" from "no network": don't guess
NET=1; online || NET=0
{
  if [ $NET = 0 ]; then :
  elif have gcloud; then
    if gcloud auth print-access-token >/dev/null 2>&1; then row "Google Cloud" true "$(gcloud_account)" ""
    else start=$(cfg '.dbProxy.startCommand'); row "Google Cloud" false "Login expired — the DB proxy and pod checks stop" "gcloud auth login${start:+ && $start}"; fi
  fi
  if [ $NET = 1 ] && have gh; then
    if ghs=$(gh auth status --active 2>&1); then row "GitHub" true "Signed in" ""
    elif grep -qiE 'connect|timeout|resolve|network' <<<"$ghs"; then :   # a network error, not a signed-out account
    else row "GitHub" false "Signed out" "gh auth login"; fi
  fi
  if [ $NET = 1 ] && have basecamp; then
    bc=$(basecamp auth status -q --json 2>/dev/null)
    if jq -e '.authenticated and (.expired | not)' >/dev/null 2>&1 <<<"$bc"; then row "Basecamp" true "Signed in" ""
    else row "Basecamp" false "Signed out" "basecamp auth login"; fi
  fi
  svc=$(cfg '.linear.keychainService')
  [ -n "$svc" ] && { security find-generic-password -s "$svc" >/dev/null 2>&1 && row "Linear" true "API key in Keychain" "" \
    || row "Linear" false "No API key" "security add-generic-password -s $svc -a token -w"; }
} | jq -s '.' >"$WD_TMP/logins.json"

listening=$(lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk '{print $9}' | sed -nE 's/^127\.0\.0\.1:([0-9]+)$/\1/p' | sort -un | jq -Rcs 'split("\n") | map(select(length > 0) | tonumber)')
pgrep -xq cloud-sql-proxy && proxy=true || proxy=false
kctx=$(kubectl config current-context 2>/dev/null)

jq -n --slurpfile logins "$WD_TMP/logins.json" --slurpfile cfg "$CONFIG" --argjson listening "${listening:-[]}" \
      --argjson proxy "$proxy" --arg kctx "$kctx" --argjson net "$NET" '
  {logins: $logins[0],
   proxy: {running: $proxy,
           ports: [($cfg[0].dbProxy.ports // [])[] | . + {up: (.port as $p | $listening | index($p) != null)}]},
   kube: {context: $kctx, prod: ($kctx | test("prod"; "i"))},
   offline: ($net == 0),
   checkedAt: (now | todate)}'
