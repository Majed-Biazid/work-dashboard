#!/bin/bash
# The standup. On a working day (from 05:00) the first run writes today's: the work
# from the previous working day up to yesterday (Sunday covers Thursday to Saturday),
# from the day records the app keeps (days/<date>/), filled in from GitHub, Linear,
# Basecamp, the past week's meetings and the Claude session digest
# (standup-sessions.sh), and turned into the spoken list by `claude -p` with no
# tools and no saved session. Every other run reads it back from the cache.
#   WD_STANDUP_ENRICH=1    gather again and add what today's list is missing, keeping it as
#                          it is (the panel's Enrich); with no list yet, write it
#   WD_DAY / WD_CACHE / WD_CLAUDE   replay another day, against another cache, with another writer (testing)
. "$(dirname "$0")/lib.sh"; tmpdir
CACHE="${WD_CACHE:-$HOME/Library/Caches/work-dashboard}"; OUT="$CACHE/standup"; DAYS="$CACHE/days"
mkdir -p "$OUT"
WORKDAYS=$(cfgj '.workday.days // [0,1,2,3,4]')
plus() { local n=$2; [ "$n" -ge 0 ] && n="+$n"; date -j -v"${n}d" -f %F "$1" +%F; }   # plus 2026-10-21 -1 → 2026-10-20
is_workday() { jq -e --argjson d "$(date -j -f %F "$1" +%w)" 'index($d) != null' <<<"$WORKDAYS" >/dev/null; }
long() { date -j -f %F "$1" "+%A $(date -j -f %F "$1" +%e | tr -d ' ') %B"; }   # Wednesday 21 October

show() {   # $1 a standup file (or ""), $2 an error to show beside it
  if [ -n "$1" ] && [ -s "$1" ]; then
    jq -n --rawfile notes "$1" --arg day "$(basename "$1" .md)" --arg err "$2" \
          --arg written "$(date -r "$(stat -f %m "$1")" +%Y-%m-%dT%H:%M:%S%z)" \
      '{notes: $notes, day: $day, written: $written} + (if $err == "" then {} else {error: $err} end)'
  else
    jq -n --arg err "$2" '{notes: null} + (if $err == "" then {} else {error: $err} end)'
  fi
}
latest() { ls "$OUT"/*.md 2>/dev/null | sort | tail -1; }

FILE="$OUT/$TODAY.md"; FAILED="$OUT/.failed-$TODAY"
# Enrich: today's list becomes the starting point, then it is written again below
CURRENT=""
[ "$WD_STANDUP_ENRICH" = 1 ] && { [ -s "$FILE" ] && CURRENT=$(sed -n '/^- /,$p' "$FILE"); rm -f "$FILE" "$FAILED"; }
[ -s "$FILE" ] && { show "$FILE"; exit 0; }
# (Write now / Enrich don't wait for 05:00)
if ! is_workday "$TODAY" || { [ "$(date +%-H)" -lt 5 ] && [ "$WD_STANDUP_ENRICH" != 1 ]; }; then show "$(latest)"; exit 0; fi
# a failed write is tried again after 30 minutes, not on every run
if [ -f "$FAILED" ] && [ $(( $(date +%s) - $(stat -f %m "$FAILED") )) -lt 1800 ]; then show "$(latest)" "$(cat "$FAILED")"; exit 0; fi
fail() { printf '%s' "$1" >"$FAILED"; show "$(latest)" "$1"; exit 0; }

# ── the window: from the previous working day up to yesterday ────────────────
TO=$(plus "$TODAY" -1); FROM=$TO
for _ in 1 2 3 4 5 6 7; do is_workday "$FROM" && break; FROM=$(plus "$FROM" -1); done
COVER=$(long "$FROM"); [ "$FROM" != "$TO" ] && COVER="$COVER to $(long "$TO")"
# Manara's own record of those days (and this morning's, for a late evening)
FOLDERS=(); d=$FROM
while [[ ! "$d" > "$TODAY" ]]; do [ -d "$DAYS/$d" ] && FOLDERS+=("$DAYS/$d"); d=$(plus "$d" 1); done
src() { for f in "${FOLDERS[@]}"; do [ -s "$f/$1.json" ] && cat "$f/$1.json"; done | jq -s -c '.' 2>/dev/null || echo '[]'; }
src today >"$WD_TMP/today.json"; src linear >"$WD_TMP/linear.json"; src calendar >"$WD_TMP/calendar.json"

# ── filled in from the sources themselves, for anything the record missed ────
# (a day Manara wasn't running, a merge after the Mac went to sleep): GitHub,
# Linear and Basecamp searched over the window, the past week's meetings, and
# what I did in Claude sessions. Read-only, like every collector.
at() { date -j -f '%Y-%m-%d %H:%M:%S' "$1 $2" +%Y-%m-%dT%H:%M:%S%z | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/'; }
S=$(at "$FROM" 00:00:00); E=$(at "$TO" 23:59:59)
ORG=$(cfg '.github.org'); ME=$(cfg '.me.github'); BCME=$(cfg '.me.basecampPersonId')
LIVE=$WD_TMP/live; mkdir -p "$LIVE"
if online; then
  if [ -n "$ORG" ] && [ -n "$ME" ]; then
    q() { gh search prs --owner="$ORG" --json number,title,url,repository,createdAt,closedAt,updatedAt --limit 100 "$@" 2>/dev/null || echo '[]'; }
    q --author="$ME" --merged-at="$S..$E" >"$LIVE/merged.json" &
    q --author="$ME" --created="$S..$E" >"$LIVE/opened.json" &
    q --reviewed-by="$ME" --updated=">=$S" -- "-author:$ME" >"$LIVE/review-candidates.json" &
    gh search commits --owner="$ORG" --author="$ME" --author-date="$S..$E" --json sha,commit,repository,url --limit 100 >"$LIVE/commits.json" 2>/dev/null || echo '[]' >"$LIVE/commits.json" &
  fi
  KEY=$(keychain "$(cfg '.linear.keychainService')")
  [ -n "$KEY" ] && curl -sS --max-time 20 https://api.linear.app/graphql -H "Content-Type: application/json" -H @- \
    -d "$(jq -cn --arg s "$S" --arg e "$E" '{query: "query { viewer { assignedIssues(first: 50, filter: { completedAt: { gte: \"\($s)\", lte: \"\($e)\" } }) { nodes { identifier title url completedAt } } } }"}')" \
    <<<"Authorization: $KEY" 2>/dev/null | jq -c '{done: [.data.viewer.assignedIssues.nodes[]? | {id: .identifier, title, url, at: .completedAt}]}' >"$LIVE/linear.json" 2>/dev/null &
  if [ -n "$BCME" ] && have basecamp; then
    for t in comment card message todo; do
      basecamp recordings --type "$t" --sort created_at --direction desc -n 200 -q --json 2>/dev/null \
        | jq -c --argjson me "$BCME" --arg t "$t" '[.[]? | select(.creator.id == $me) | {kind: $t, title, where: .bucket.name, at: .created_at, url: .app_url}]' >"$LIVE/bc-$t.json" &
    done
  fi
fi
"$(dirname "$0")/standup-sessions.sh" "$FROM" "$TO" >"$WD_TMP/sessions.txt" 2>/dev/null &
wait
for f in "$LIVE"/*.json; do [ -e "$f" ] && { jq -e . "$f" >/dev/null 2>&1 || echo '[]' >"$f"; }; done
# a review counts on the day I submitted it, not the day the PR last moved
if [ -s "$LIVE/review-candidates.json" ]; then
  jq -r '.[] | "\(.repository.name)\t\(.number)"' "$LIVE/review-candidates.json" | head -40 | while IFS=$'\t' read -r repo n; do
    gh api "repos/$ORG/$repo/pulls/$n/reviews" --paginate 2>/dev/null \
      | jq -cs --arg me "$ME" --arg repo "$repo" --argjson n "$n" \
          '[add // [] | .[] | select(.user.login == $me and .submitted_at != null) | .submitted_at] | {repo: $repo, number: $n, at: (max // null)}'
  done | jq -s '.' >"$LIVE/reviewed-at.json"
fi
[ -s "$LIVE/reviewed-at.json" ] || echo '[]' >"$LIVE/reviewed-at.json"
jq -n --slurpfile m <(cat "$LIVE/merged.json" 2>/dev/null || echo '[]') --slurpfile o <(cat "$LIVE/opened.json" 2>/dev/null || echo '[]') \
      --slurpfile r <(cat "$LIVE/review-candidates.json" 2>/dev/null || echo '[]') --slurpfile ra "$LIVE/reviewed-at.json" \
      --slurpfile c <(cat "$LIVE/commits.json" 2>/dev/null || echo '[]') --slurpfile bc <(cat "$LIVE"/bc-*.json 2>/dev/null | jq -s 'add // []') '
  def pr($at): {title, url, repo: .repository.name, number, at: $at};
  {merged: [$m[0][] | pr(.closedAt)], opened: [$o[0][] | pr(.createdAt)],
   reviewed: [$r[0][] | . as $p | ($ra[0][] | select(.repo == $p.repository.name and .number == $p.number and .at != null)) as $x | ($p | pr($x.at))],
   commits: [$c[0][] | {repo: .repository.name, title: (.commit.message | split("\n")[0]), at: .commit.author.date, url}]
            | map(select(.title | test("^Merge (pull request|branch)|\\[skip ci\\]|bump version"; "i") | not)),
   basecamp: $bc[0]}' >"$LIVE/today.json" 2>/dev/null || echo '{}' >"$LIVE/today.json"
jq -s 'add' "$WD_TMP/today.json" <(jq -c '[.]' "$LIVE/today.json") >"$WD_TMP/t.json" && mv "$WD_TMP/t.json" "$WD_TMP/today.json"
[ -s "$LIVE/linear.json" ] && jq -s 'add' "$WD_TMP/linear.json" <(jq -c '[.]' "$LIVE/linear.json") >"$WD_TMP/l.json" && mv "$WD_TMP/l.json" "$WD_TMP/linear.json"
PAST="$CACHE/calendar-past.json"
[ -s "$PAST" ] && jq -s 'add' "$WD_TMP/calendar.json" <(jq -c '[.]' "$PAST") >"$WD_TMP/c.json" && mv "$WD_TMP/c.json" "$WD_TMP/calendar.json"
for f in today linear calendar; do jq -e . "$WD_TMP/$f.json" >/dev/null 2>&1 || echo '[]' >"$WD_TMP/$f.json"; done

# ── the record: one line per thing done, grouped by day ──────────────────────
jq -r -n --slurpfile t "$WD_TMP/today.json" --slurpfile l "$WD_TMP/linear.json" \
         --slurpfile c "$WD_TMP/calendar.json" --arg from "$FROM" --arg to "$TO" '
  def ts($x): ($x | capture("^(?<d>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")) as $m
    | (($m.d + "Z") | fromdate) - (if ($m.z // "Z") == "Z" then 0
        else (($m.z[1:3] | tonumber) * 3600 + ($m.z[-2:] | tonumber) * 60) * (if $m.z[0:1] == "+" then 1 else -1 end) end);
  def day($x): ts($x) | strflocaltime("%Y-%m-%d");
  def hm($x): ts($x) | strflocaltime("%H:%M");
  def inwin($x): $x != null and (day($x) as $d | $d >= $from and $d <= $to);
  def latest: group_by(.id) | map(max_by(.at));
  ($t[0] | map(select(type == "object"))) as $T
  | ([ ($T[] | (.merged // [])[]   | select(inwin(.at)) | {id: "m\(.url)", at, line: "Merged PR \(.repo)#\(.number): \(.title)"}),
       ($T[] | (.opened // [])[]   | select(inwin(.at)) | {id: "o\(.url)", at, line: "Opened PR \(.repo)#\(.number): \(.title)"}),
       ($T[] | (.reviewed // [])[] | select(inwin(.at)) | {id: "r\(.url)", at, line: "Reviewed PR \(.repo)#\(.number): \(.title)"}),
       ($T[] | (.basecamp // [])[] | select(inwin(.at)) | {id: "b\(.url)", at,
          line: "\(if .kind == "comment" then "Replied" else "Posted a \(.kind)" end) on Basecamp (\(.where)): \(.title)"}),
       ($l[0][] | (.done? // [])[] | select(inwin(.at)) | {id: "l\(.id)", at, line: "Closed Linear \(.id): \(.title)"}),
       ($c[0][] | (.events? // [])[] | select((.allDay | not) and inwin(.start) and (.title | test("standup"; "i") | not))
          | {id: "c\(.id)\(.start)", at: .start, line: "Meeting \(hm(.start))–\(hm(.end)): \(.title)\(if (.notes // "") != "" then " — notes: \(.notes)" else "" end)"})
     ] | latest) as $done
  | ([$T[] | (.commits // [])[] | select(inwin(.at)) | {id: .url, at, repo, title}] | latest
     | group_by([day(.at), .repo]) | map(sort_by(.at) | {at: .[-1].at,
         line: "\(length) commit\(if length > 1 then "s" else "" end) in \(.[0].repo): \(map(.title) | unique | .[0:4] | join("; "))"})) as $commits
  | ($done + $commits | sort_by(.at) | group_by(day(.at))
     | map("\(day(.[0].at) | strptime("%Y-%m-%d") | mktime | strftime("%A %d %B"))\n" + (map("- \(.line)") | join("\n")))
     | join("\n\n")) as $body
  | ([$l[0][] | select(type == "object" and .active)] | last | (.active // [])[0:8]
     | map("- \(.id): \(.title) (\(.state))") | join("\n")) as $open
  | if $body == "" then "" else "## What the systems show (GitHub, Linear, Basecamp, meetings)\n\n" + $body
      + (if $open != "" then "\n\nStill in progress in Linear (mention only if the record shows work on it):\n" + $open else "" end) end
' >"$WD_TMP/record.txt" 2>"$WD_TMP/jq.err" || fail "Could not read the day records: $(head -c 160 "$WD_TMP/jq.err")"

# what I did in Claude sessions, when there was any
grep -q '^### ' "$WD_TMP/sessions.txt" 2>/dev/null && { printf '\n\n# What I did in Claude sessions\n\n'; cat "$WD_TMP/sessions.txt"; } >>"$WD_TMP/record.txt"
NOTE=""; online || NOTE=" (offline: from Manara's own record only)"
write() { { echo "# Standup $TODAY ($(date -j -f %F "$TODAY" +%A))"; echo "_Covering ${COVER}${NOTE}_"; echo; cat; } >"$FILE.tmp" && mv "$FILE.tmp" "$FILE"; }

if ! grep -q '[^[:space:]]' "$WD_TMP/record.txt"; then   # nothing to write up: no need to ask Claude
  printf -- '- Nothing was recorded for these days.\n' | write
else
  MODEL=$(cfg '.standup.model')
  { cat "$(dirname "$0")/standup-prompt.md"
    [ -n "$CURRENT" ] && printf '\n\nThis is my current list. ENRICH it, do not rewrite it: keep every item and its wording exactly as it is, add new items for anything in the record it misses (meetings included), and change a line only where the record shows it is wrong. Output the whole list.\n\n%s\n' "$CURRENT"
    printf '\n\nThe record — %s:\n\n' "$COVER"; cat "$WD_TMP/record.txt"; } >"$WD_TMP/prompt.txt"
  # no tools, no MCP servers, no hooks, nothing saved: a plain write-up
  ( cd "$WD_TMP" && "${WD_CLAUDE:-claude}" -p --no-session-persistence --tools "" --strict-mcp-config --disable-slash-commands \
      --setting-sources "" ${MODEL:+--model "$MODEL"} <"$WD_TMP/prompt.txt" >"$WD_TMP/out.md" 2>"$WD_TMP/err" ) \
    || fail "Claude could not write the standup: $(tail -c 160 "$WD_TMP/err" "$WD_TMP/out.md" 2>/dev/null | tr '\n' ' ')"
  grep -q '^- ' "$WD_TMP/out.md" || fail "Claude's answer was not a list: $(head -c 120 "$WD_TMP/out.md" | tr '\n' ' ')"
  sed -n '/^- /,$p' "$WD_TMP/out.md" | grep -v '^```' | write
fi
rm -f "$FAILED"
find "$OUT" -name '*.md' -mtime +21 -delete 2>/dev/null
show "$FILE"
