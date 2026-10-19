#!/bin/bash
# Sentry error signals for the configured projects (backend first): per project, the
# hourly error count over the last 15 days, and the same for each of the error titles
# busiest in the last 24 hours or the last 7 days. The page compares every hour with that title's own
# usual rate to find spikes (core.js sentrySignals). Counting by TITLE, not by issue,
# matters: an error whose fingerprint changes every time (one issue per event) is a
# spike of one-event issues, invisible to an issue-by-issue view.
# Plus Sentry's own verdicts: issues it marks escalating, and issues that came back
# after they were resolved. Read-only: GET calls with a read-only token.
#   WD_SENTRY_FIXTURES=<dir>   read the API answers from <dir>/<name>.json (testing)
. "$(dirname "$0")/lib.sh"; tmpdir

N=$(cfgj '.sentry.projects // [] | length')
[ -z "$N" ] || [ "$N" = 0 ] && { echo '{"projects":[]}'; exit 0; }
FIX="$WD_SENTRY_FIXTURES"
[ -n "$FIX" ] || keep_last_if_offline
ORG=$(cfg '.sentry.org'); API="$(cfg '.sentry.region')"; API="${API:-https://sentry.io}"
TOKEN=""; [ -n "$FIX" ] || TOKEN=$(keychain "$(cfg '.sentry.keychainService')")
# no token yet is a setup step, not a failure: the card says how, nothing alerts
[ -z "$FIX" ] && [ -z "$TOKEN" ] && { jq -cn --arg k "$(cfg '.sentry.keychainService')" '{projects: [], setup: "Add a read-only Sentry token to see error spikes: security add-generic-password -s \($k) -a token -w"}'; exit 0; }
ENVS=$(cfgj '.sentry.environments // ["production", "prod"]')
TOP=$(cfg '.sentry.titles'); TOP=${TOP:-10}

get() {   # $1 name  $2 path?query → $WD_TMP/$1.json (never fails; an error answer is kept for the check below)
  if [ -n "$FIX" ]; then cp "$FIX/$1.json" "$WD_TMP/$1.json" 2>/dev/null || echo '{}' >"$WD_TMP/$1.json"; return; fi
  # the token goes in on stdin, never on the command line (ps shows arguments)
  local try
  for try in 1 2 3; do
    curl -s -m 30 "$API/api/0/organizations/$ORG/$2" -H @- <<<"Authorization: Bearer $TOKEN" >"$WD_TMP/$1.json" \
      || echo '{"detail":"no answer"}' >"$WD_TMP/$1.json"
    # Sentry allows 15 requests at once per endpoint: when it says so, wait and ask again
    grep -q 'concurrency' "$WD_TMP/$1.json" 2>/dev/null || return 0
    sleep "$try"
  done
}
enc() { jq -rn --arg v "$1" '$v | @uri'; }
ENVQ=$(jq -r 'map("environment=" + @uri) | join("&")' <<<"$ENVS")

get projects "projects/?all_projects=1"
APIERR=$(jq -r 'if type == "object" then (.detail // empty) else empty end' "$WD_TMP/projects.json" 2>/dev/null)
if [ -n "$APIERR" ] || ! jq -e 'type == "array"' "$WD_TMP/projects.json" >/dev/null 2>&1; then
  grep -qiE 'token|auth|credential|permission' <<<"$APIERR" && APIERR="the Sentry token was refused — make a new one (see README: Sentry)"
  err_json "Sentry: ${APIERR:-no answer}"; exit 0
fi
# the configured projects, with Sentry's numeric id
jq -c --slurpfile cfg "$CONFIG" '(map({key: .slug, value: .id}) | from_entries) as $ids
  | [$cfg[0].sentry.projects[] | . + {id: $ids[.slug]} | select(.id != null)]' "$WD_TMP/projects.json" >"$WD_TMP/want.json"
jq -e 'length > 0' "$WD_TMP/want.json" >/dev/null || { err_json "Sentry: none of the projects in sentry.projects exist in $ORG"; exit 0; }

# 15 days of hours: the longest window (7 days) plus the week before it, its baseline
PERIOD=15d
RUNNING=0
FIELDS='field=title&field=count()&field=count_unique(issue)&field=count_unique(user)&field=max(timestamp)&sort=-count'
while IFS=$'\t' read -r slug id; do
  (
    get "total-$slug" "events-stats/?dataset=errors&project=$id&$ENVQ&yAxis=count()&interval=1h&statsPeriod=$PERIOD"
    get "top-$slug" "events/?dataset=errors&project=$id&$ENVQ&$FIELDS&per_page=$TOP&statsPeriod=24h" &
    get "week-$slug" "events/?dataset=errors&project=$id&$ENVQ&$FIELDS&per_page=$TOP&statsPeriod=7d" &
    wait
    # the busiest titles of the day and of the week; each one's own hours, ten titles per call (Sentry's limit)
    jq -s -c '[.[] | (.data // [])[].title] | reduce .[] as $t ([]; if index([$t]) then . else . + [$t] end)' \
      "$WD_TMP/top-$slug.json" "$WD_TMP/week-$slug.json" >"$WD_TMP/names-$slug.json" 2>/dev/null || echo '[]' >"$WD_TMP/names-$slug.json"
    for part in 0 1; do
      Q=$(jq -r --argjson p "$part" '.[$p * 10:($p + 1) * 10] | map(gsub("\\\\"; "\\\\") | gsub("\""; "\\\"") | "\"" + . + "\"")
        | if length == 0 then "" else "title:[" + join(",") + "]" end' "$WD_TMP/names-$slug.json")
      if [ -n "$Q" ]; then
        get "titles-$slug-$part" "events-stats/?dataset=errors&project=$id&$ENVQ&yAxis=count()&field=title&field=count()&orderby=-count()&topEvents=10&excludeOther=1&interval=1h&statsPeriod=$PERIOD&query=$(enc "$Q")"
        # one title: Sentry answers without the title key
        jq -c --argjson p "$part" --slurpfile n "$WD_TMP/names-$slug.json" 'if (.data | type) == "array" then {($n[0][$p * 10]): .} else . end' \
          "$WD_TMP/titles-$slug-$part.json" >"$WD_TMP/t.$slug.$part" 2>/dev/null && mv "$WD_TMP/t.$slug.$part" "$WD_TMP/titles-$slug-$part.json"
      else echo '{}' >"$WD_TMP/titles-$slug-$part.json"; fi
    done
    jq -s 'map(objects) | add // {}' "$WD_TMP/titles-$slug-0.json" "$WD_TMP/titles-$slug-1.json" >"$WD_TMP/titles-$slug.json"
  ) &
  # three projects at a time (each asks up to two things at once): under Sentry's limit of 15
  (( ++RUNNING % 3 == 0 )) && wait
done < <(jq -r '.[] | "\(.slug)\t\(.id)"' "$WD_TMP/want.json")
wait
PIDS=$(jq -r 'map("project=\(.id)") | join("&")' "$WD_TMP/want.json")
get escalating "issues/?$PIDS&$ENVQ&query=$(enc 'is:unresolved is:escalating')&statsPeriod=24h&limit=10&sort=freq" &
get regressed "issues/?$PIDS&$ENVQ&query=$(enc 'is:unresolved is:regressed lastSeen:-7d')&statsPeriod=7d&limit=15&sort=date" &
wait
for f in "$WD_TMP"/*.json; do jq -e . "$f" >/dev/null 2>&1 || echo '{}' >"$f"; done

WEB=$(cfg '.sentry.web'); WEB="${WEB:-https://$ORG.sentry.io}"
# the answers, in project order (3 per project), as one array
for s in $(jq -r '.[].slug' "$WD_TMP/want.json"); do cat "$WD_TMP/total-$s.json" "$WD_TMP/top-$s.json" "$WD_TMP/week-$s.json" "$WD_TMP/titles-$s.json"; done | jq -s '.' >"$WD_TMP/all.json"
jq -cn --slurpfile want "$WD_TMP/want.json" --arg web "$WEB" --slurpfile files "$WD_TMP/all.json" \
      --slurpfile esc "$WD_TMP/escalating.json" --slurpfile reg "$WD_TMP/regressed.json" '
  # events-stats data: [[epoch, [{count: n}]], ...] → [[epoch, n], ...]
  def series: [(.data // [])[] | [.[0], ((.[1] // []) | map(.count // 0) | add // 0)]];
  def issue: {id: .shortId, title, culprit, project: .project.slug, events: ((.count // "0") | tonumber), users: (.userCount // 0),
              firstSeen, lastSeen, url: .permalink, substatus};
  ($want[0] | length) as $n
  | {org: $web, checkedAt: (now | todate), step: 3600,
     projects: [range(0; $n) as $i | $want[0][$i] as $p
       | $files[0][$i * 4] as $total | $files[0][$i * 4 + 1] as $top | $files[0][$i * 4 + 2] as $week | $files[0][$i * 4 + 3] as $titles
       | (($top.data // []) | map({key: .title, value: .}) | from_entries) as $d
       | (($week.data // []) | map({key: .title, value: .}) | from_entries) as $w
       | {slug: $p.slug, name: ($p.name // $p.slug), kind: ($p.kind // "backend"), id: $p.id,
          error: ([$total, $top] | map(select(type == "object") | .detail // empty | tostring) | first),
          total: ($total | series),
          titles: [(($top.data // []) + ($week.data // []) | map(.title) | reduce .[] as $t ([]; if index([$t]) then . else . + [$t] end))[] as $t
            | {title: $t, events24h: ($d[$t]["count()"] // 0), issues24h: ($d[$t]["count_unique(issue)"] // 0), users24h: ($d[$t]["count_unique(user)"] // 0),
               events7d: ($w[$t]["count()"] // 0), issues7d: ($w[$t]["count_unique(issue)"] // 0), users7d: ($w[$t]["count_unique(user)"] // 0),
               last: ($d[$t] // $w[$t])["max(timestamp)"], series: (($titles[$t] // {}) | series)}]}],
     escalating: [($esc[0] | if type == "array" then .[] else empty end) | issue],
     regressed: [($reg[0] | if type == "array" then .[] else empty end) | issue]}'
