#!/bin/bash
# System health, one verdict per configured system:
#   • HTTP health endpoints — status code, latency, and the checks inside the body
#     ({"database":"ok","redis":true,…}); anything not ok becomes a reason
#   • Kubernetes pods (read-only `get pods`) — not ready, crash loops, recent restarts
#   • the last deploy workflow on GitHub Actions
#   • frontends (kind "frontend"): the site answers, and the build it serves
#     (/version.json buildId) is the commit the last successful deploy shipped
#   • Better Stack monitors and open incidents, when a key is in Keychain
# Verdicts: ok · warn (amber: degraded, look soon) · down (red: act now) · unknown.
. "$(dirname "$0")/lib.sh"; tmpdir

NSYS=$(cfgj '.systems | length')
[ -z "$NSYS" ] || [ "$NSYS" = 0 ] && { echo '{"systems":[]}'; exit 0; }
offline_json() { jq -cn '{offline: true, error: "No network — systems not checked", systems: [], checkedAt: (now | todate)}'; }
online || { offline_json; exit 0; }

# ── pods: one call per distinct context + namespace ─────────────────────────
pods_for() {   # $1 context  $2 namespace  → slim JSON
  local out errf; errf=$(mktemp "$WD_TMP/kerr.XXXX")
  # stderr apart: auth-plugin / deprecation warnings must not end up inside the JSON
  if out=$(kubectl --context "$1" -n "$2" get pods -o json --request-timeout=15s 2>"$errf") && jq -e '.items' >/dev/null 2>&1 <<<"$out"; then
    jq -c '{items: [.items[] | select(.status.phase != "Succeeded") | {
      name: .metadata.name, phase: .status.phase, created: .metadata.creationTimestamp,
      ready: ([.status.containerStatuses[]? | .ready] | (length > 0 and all)),
      restarts: ([.status.containerStatuses[]? | .restartCount] | add // 0),
      lastRestart: ([.status.containerStatuses[]? | .lastState.terminated.finishedAt // empty] | max),
      waiting: ([.status.containerStatuses[]? | .state.waiting.reason // empty] | unique)
    }]}' <<<"$out"
  else
    out="$(cat "$errf")$out"
    if grep -qiE 'gcloud|token|unauthor|credential|reauth|login' <<<"$out"; then
      err_json "Google login expired — run: gcloud auth login"
    else
      err_json "$(head -c 160 <<<"$out")"
    fi
  fi
}
i=0
while IFS=$'\t' read -r ctx ns; do
  [ -z "$ctx" ] && continue
  pods_for "$ctx" "$ns" >"$WD_TMP/pods-$i.json" &
  printf '%s\t%s\t%s\n' "$ctx" "$ns" "$WD_TMP/pods-$i.json" >>"$WD_TMP/pods.index"
  i=$((i + 1))
done < <(jq -r '[.systems[].pods | select(. != null) | [.context, (.namespace // "default")]] | unique[] | @tsv' "$CONFIG")

# ── HTTP checks ─────────────────────────────────────────────────────────────
http_one() {   # $1 url → {url, code, ms, checks}
  local body="$WD_TMP/body-$RANDOM$RANDOM" meta
  meta=$(curl -s -L -m 10 -o "$body" -w '%{http_code} %{time_total}' -H 'Accept: application/json' "$1" 2>/dev/null || echo "000 0")
  local code=${meta%% *} secs=${meta##* }
  jq -cn --arg url "$1" --argjson code "${code:-0}" --arg secs "$secs" --rawfile body "$body" '
    ($body | try fromjson catch null) as $j
    | {url: $url, code: $code, ms: (($secs | tonumber) * 1000 | floor),
       checks: (if ($j | type) == "object" then
                  ([($j.checks // {}), ($j | with_entries(select(.key | test("^(database|db|redis|cache|queue|storage)$"))))]
                   | add | with_entries(.value |= (if . == true or . == "ok" or . == "up" or . == "healthy" then "ok" else tostring end)))
                else {} end)}' 2>/dev/null || jq -cn --arg url "$1" '{url: $url, code: 0, ms: 0, checks: {}}'
}
while read -r url; do
  [ -n "$url" ] && { http_one "$url" >"$WD_TMP/http-$(printf '%s' "$url" | shasum | cut -c1-12).json" & }
done < <(jq -r '.systems[].health[]?.url' "$CONFIG" | sort -u)
# the build a frontend is serving right now
while IFS=$'\t' read -r name vurl; do
  [ -z "$name" ] && continue
  ( v=$(curl -s -L -m 10 -H 'Cache-Control: no-cache' "$vurl" 2>/dev/null)
    jq -cn --arg n "$name" --arg v "$v" '{system: $n, live: ($v | try fromjson catch null)}' >"$WD_TMP/ver-$RANDOM$RANDOM.json" ) &
done < <(jq -r '.systems[] | select(.version) | [.name, .version] | @tsv' "$CONFIG")
# a release PR (develop → main) waiting, for every deployed repo in ONE GraphQL call
# (it was one `gh pr list` per system, every minute)
ORG=$(cfg '.github.org')
DREPOS=$(cfgj '[.systems[] | select(.deploy) | .deploy.repo] | unique')
RELQ=$(jq -r --arg org "$ORG" 'to_entries | map("r\(.key): repository(owner: \"\($org)\", name: \"\(.value)\") { pullRequests(baseRefName: \"main\", headRefName: \"develop\", states: OPEN, first: 1, orderBy: {field: CREATED_AT, direction: DESC}) { nodes { number title url createdAt } } }") | "query { \(join(" ")) }"' <<<"${DREPOS:-[]}")
[ "${DREPOS:-[]}" != "[]" ] && { gh api graphql -f query="$RELQ" 2>/dev/null | jq -c --argjson repos "$DREPOS" \
  '.data as $d | [$repos | to_entries[] | {key: .value, value: ($d["r\(.key)"].pullRequests.nodes // [])}] | from_entries' >"$WD_TMP/release-prs.json" 2>/dev/null & }
wait   # pods + http + release PRs in flight together (all started from THIS shell, so wait sees them)
[ -s "$WD_TMP/release-prs.json" ] || echo '{}' >"$WD_TMP/release-prs.json"
cat "$WD_TMP"/ver-*.json 2>/dev/null | jq -s '.' >"$WD_TMP/versions.json" 2>/dev/null || echo '[]' >"$WD_TMP/versions.json"
[ -s "$WD_TMP/versions.json" ] || echo '[]' >"$WD_TMP/versions.json"

# Every endpoint unreachable at once is this Mac's network, not every product
# going down together (e.g. just after waking, before Wi-Fi is back).
if [ -n "$(ls "$WD_TMP"/http-*.json 2>/dev/null)" ] && ! jq -s -e 'any(.[]; .code != 0)' "$WD_TMP"/http-*.json >/dev/null 2>&1; then
  offline_json; exit 0
fi

# ── releases per system: last release, a deploy running now, a release PR waiting
while IFS=$'\t' read -r name repo wf; do
  [ -z "$name" ] && continue
  ( runs=$(gh run list -R "$ORG/$repo" --branch main --workflow "$wf" --limit 6 \
           --json status,conclusion,createdAt,updatedAt,url,displayTitle,headSha 2>/dev/null) || runs='[]'
    pr=$(jq -c --arg r "$repo" '.[$r] // []' "$WD_TMP/release-prs.json")
    jq -c --arg n "$name" --arg repo "$repo" --argjson pr "${pr:-[]}" '
      def prn: (.displayTitle // "" | capture("#(?<n>[0-9]+)").n // null);
      {system: $n, repo: $repo,
       run: (.[0] // null),
       running: ([.[] | select(.status != "completed")] | first // null | if . then {since: .createdAt, url, status, pr: prn} else null end),
       last: ([.[] | select(.conclusion == "success")] | first // null
              | if . then {at: .updatedAt, url, pr: prn, title: .displayTitle, sha: .headSha} else null end),
       pending: ($pr[0] // null | if . then {number, title, url, since: .createdAt} else null end)}' <<<"${runs:-[]}" >"$WD_TMP/dep-$RANDOM$RANDOM.json" ) &
done < <(jq -r '.systems[] | select(.deploy) | [.name, .deploy.repo, .deploy.workflow] | @tsv' "$CONFIG")
wait
cat "$WD_TMP"/dep-*.json 2>/dev/null >"$WD_TMP/deploys.jsonl" || : >"$WD_TMP/deploys.jsonl"

# ── Better Stack (optional) ─────────────────────────────────────────────────
BS_KEY=$(keychain "$(cfg '.betterstack.keychainService')")
if [ -n "$BS_KEY" ]; then
  # the key goes in on stdin, never on the command line (ps shows arguments)
  curl -s -m 15 -H @- "https://uptime.betterstack.com/api/v2/monitors?per_page=100" >"$WD_TMP/bs-monitors.json" <<<"Authorization: Bearer $BS_KEY" &
  curl -s -m 15 -H @- "https://uptime.betterstack.com/api/v2/incidents?resolved=false&per_page=20" >"$WD_TMP/bs-incidents.json" <<<"Authorization: Bearer $BS_KEY" &
  wait
fi
[ -s "$WD_TMP/bs-monitors.json" ] || echo '{}' >"$WD_TMP/bs-monitors.json"
[ -s "$WD_TMP/bs-incidents.json" ] || echo '{}' >"$WD_TMP/bs-incidents.json"

# ── assemble ────────────────────────────────────────────────────────────────
jq -s '.' "$WD_TMP"/http-*.json 2>/dev/null >"$WD_TMP/http.json" || echo '[]' >"$WD_TMP/http.json"
[ -s "$WD_TMP/http.json" ] || echo '[]' >"$WD_TMP/http.json"
# one object per context; an empty or broken file becomes an error entry, never broken JSON
[ -f "$WD_TMP/pods.index" ] && while IFS=$'\t' read -r ctx ns f; do
  jq -c --arg c "$ctx" --arg n "$ns" '{context: $c, namespace: $n} + .' "$f" 2>/dev/null \
    || jq -cn --arg c "$ctx" --arg n "$ns" '{context: $c, namespace: $n, error: "pods unreadable"}'
done <"$WD_TMP/pods.index" | jq -s '.' >"$WD_TMP/pods.json"
[ -s "$WD_TMP/pods.json" ] || echo '[]' >"$WD_TMP/pods.json"
jq -s '.' "$WD_TMP/deploys.jsonl" >"$WD_TMP/deploys.json"

jq -n --slurpfile cfg "$CONFIG" --slurpfile http "$WD_TMP/http.json" --slurpfile pods "$WD_TMP/pods.json" \
  --slurpfile deploys "$WD_TMP/deploys.json" --slurpfile versions "$WD_TMP/versions.json" --slurpfile bsm "$WD_TMP/bs-monitors.json" --slurpfile bsi "$WD_TMP/bs-incidents.json" --arg bsteam "$(cfg '.betterstack.team // "0"')" '
  def ago_min($t): if $t == null then 1e9 else ((now - ($t | sub("\\.[0-9]+Z$"; "Z") | fromdate)) / 60) end;
  ($bsm[0].data // []) as $monitors
  | ($bsi[0].data // []) as $incidents
  | {systems: [ $cfg[0].systems[] as $s
    | ([$http[0][] | select(.url as $u | [$s.health[]?.url] | index($u))]) as $h
    | (if $s.pods then ($pods[0][] | select(.context == $s.pods.context and .namespace == ($s.pods.namespace // "default"))) else null end) as $pset
    | ($pset.items // [] | map(select(.name | startswith($s.pods.prefix // "")))) as $p
    | ([$deploys[0][] | select(.system == $s.name)] | first) as $D
    | ($D.run // null) as $dep
    | ([$versions[0][] | select(.system == $s.name)] | first | .live // null) as $live
    | ($live.buildId // null) as $build
    | ([$monitors[] | select(.attributes.url as $u | [$s.health[]?.url] | map(rtrimstr("/")) | index($u | rtrimstr("/")))]) as $bs
    | ( [ $h[] | select(.code < 200 or .code >= 400) | {level: "down", text: "Health check \(if .code == 0 then "timed out" else "returned \(.code)" end)", where: .url} ]
      + [ $h[] | select(.code >= 200 and .code < 400) | .checks | to_entries[] | select(.value != "ok") | select(.value != "not_configured")
          | {level: "warn", text: (($s.checkLabels // {})[.key] // "Reports \(.key) as \(.value)")} ]
      + [ $h[] | select(.code >= 200 and .code < 400 and .ms > 3000) | {level: "warn", text: "Health check slow (\(.ms / 1000 | floor)s)", where: .url} ]
      + (if $pset.error then [{level: "unknown", text: "Pods unreadable: \($pset.error)"}] else [] end)
      + (if ($p | length) > 0 and ([$p[] | select(.ready)] | length) == 0 then [{level: "down", text: "No pod is ready"}] else [] end)
      + [ $p[] | select(.waiting | map(select(test("CrashLoop|ImagePull|ErrImage|Error|CreateContainer"))) | length > 0)
          | {level: "down", text: "\(.name | sub("-[a-z0-9]+-[a-z0-9]+$"; "")) is failing (\(.waiting | join(", ")))"} ]
      + [ $p[] | select(.ready | not) | select(.waiting | length == 0) | select(ago_min(.created) > 10)
          | {level: "warn", text: "\(.name | sub("-[a-z0-9]+-[a-z0-9]+$"; "")) not ready"} ]
      + ([ $p[] | select(ago_min(.lastRestart) < 60) ] | if length > 0 then [{level: "warn", text: "\(length) pod\(if length == 1 then "" else "s" end) restarted in the last hour"}] else [] end)
      + (if $dep and $dep.conclusion == "failure" then [{level: "warn", text: "Last deploy failed", url: $dep.url}] else [] end)
      + [ $bs[] | select(.attributes.status == "down") | {level: "down", text: "Better Stack: \(.attributes.pronounceable_name) is down",
                                                           url: "https://uptime.betterstack.com/team/\($bsteam)/monitors/\(.id)"} ]
      + (if $s.version and $build == null then [{level: "warn", text: "Live build unreadable (version.json)"}]
         elif $build and $D.last.sha and $build != $D.last.sha and ($D.running | not) and ago_min($D.last.at) > 20
         then [{level: "warn", text: "Live site is not serving the last deploy (CDN or upload problem?)"}] else [] end)
      ) as $reasons
    | {
        name: $s.name, detail: ($s.detail // ""), kind: ($s.kind // "backend"),
        live: (if $s.version then {build: ($build // null | if . then .[0:7] else null end), version: ($live.version // null),
               current: ($build != null and $build == $D.last.sha)} else null end),
        status: (if any($reasons[]; .level == "down") then "down"
                 elif any($reasons[]; .level == "warn") then "warn"
                 elif ($h | length) == 0 and ($p | length) == 0 then "unknown"
                 elif any($reasons[]; .level == "unknown") and ($h | length) == 0 then "unknown"
                 else "ok" end),
        reasons: $reasons,
        http: [$h[] | {url, code, ms}],
        pods: {total: ($p | length), ready: ([$p[] | select(.ready)] | length),
               restartsToday: ([$p[] | select(ago_min(.lastRestart) < 1440)] | length),
               rollingOut: ([$p[] | select(ago_min(.created) < 15 and (.ready | not))] | length),
               lastRollout: ([$p[].created] | max), error: ($pset.error // null)},
        deploy: (if $dep then {status: $dep.status, conclusion: $dep.conclusion, at: $dep.createdAt, url: $dep.url} else null end),
        release: (if $D then {repo: $D.repo, last: $D.last, running: $D.running, pending: $D.pending} else null end)
      } ],
    # url opens the incident in Better Stack (team 0 = your current team after sign-in); target is what it watches
    incidents: [$incidents[] | {id, name: .attributes.name, cause: .attributes.cause, started: .attributes.started_at,
                                url: "https://uptime.betterstack.com/team/\($bsteam)/incidents/\(.id)", target: .attributes.url}],
    betterstack: ($bsm[0] | has("data")),
    checkedAt: (now | todate) }'
