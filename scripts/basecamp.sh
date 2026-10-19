#!/bin/bash
# Basecamp (read-only):
#   issues — open cards in the configured ticket column(s), each with a
#            needs-attention level from priority, age, idle time and who spoke last
#   inbox  — only what is said TO you: unread @mentions and private chats (pings)
#   errors — prod lines in the error-log chat: last hour vs the 24 h hourly average
. "$(dirname "$0")/lib.sh"; tmpdir
have basecamp || { err_json "basecamp CLI not found"; exit 0; }
keep_last_if_offline   # the last issues and mentions stay on screen
CACHE="$HOME/Library/Caches/work-dashboard"; mkdir -p "$CACHE"
P=$(cfg '.basecamp.issues.project'); TABLE=$(cfg '.basecamp.issues.cardTable'); TEAMP=$(cfg '.basecamp.issues.teamProject')
ME=$(cfg '.me.basecampPersonId')

# ── issues ──────────────────────────────────────────────────────────────────
if [ -n "$P" ] && [ "$P" != 0 ]; then
  for col in $(jq -r '.basecamp.issues.columns[]?' "$CONFIG"); do
    # a failed read must not look like "no open issues": stop and say so
    if ! basecamp cards list -p "$P" --card-table "$TABLE" -c "$col" --all -q --json >"$WD_TMP/col.json" 2>"$WD_TMP/col.err" \
       || ! jq -e 'type == "array"' "$WD_TMP/col.json" >/dev/null 2>&1; then
      err_json "Basecamp: couldn't read the ticket column — $(head -c 120 "$WD_TMP/col.err")"; exit 0
    fi
    jq -c '.[]? | select(.completed | not) | {id, title, created: .created_at, updated: .updated_at, due: .due_on,
                comments: .comments_count, url: .app_url, creator: .creator.id, assignees: [.assignees[]?.id]}' "$WD_TMP/col.json"
  done >"$WD_TMP/cards.jsonl"

  # who is "us": the team project's people, refreshed once a day
  ROSTER="$CACHE/basecamp-roster.json"
  if [ -n "$TEAMP" ] && { [ ! -s "$ROSTER" ] || [ $(( $(date +%s) - $(stat -f %m "$ROSTER") )) -gt 86400 ]; }; then
    basecamp people list -p "$TEAMP" -q --json 2>/dev/null | jq -ce '[.[].id] | select(length > 0)' >"$ROSTER.tmp" \
      && mv "$ROSTER.tmp" "$ROSTER" || rm -f "$ROSTER.tmp"   # a failed fetch keeps yesterday's roster
  fi
  [ -s "$ROSTER" ] || echo '[]' >"$ROSTER"

  # last commenter — one call per card, only when the card changed since last time
  LAST="$CACHE/basecamp-last-comment.json"; [ -s "$LAST" ] || echo '{}' >"$LAST"
  cp "$LAST" "$WD_TMP/last.json"
  while read -r id updated comments; do
    [ "$comments" = 0 ] && continue
    known=$(jq -r --arg id "$id" '.[$id].updated // ""' "$WD_TMP/last.json")
    [ "$known" = "$updated" ] && continue
    lc=$(basecamp comments list "$id" -p "$P" -q --json 2>/dev/null | jq -c 'max_by(.created_at) | {at: .created_at, by: .creator.id}' 2>/dev/null)
    [ -n "$lc" ] && jq --arg id "$id" --arg u "$updated" --argjson lc "$lc" '.[$id] = ($lc + {updated: $u})' "$WD_TMP/last.json" >"$WD_TMP/l2" && mv "$WD_TMP/l2" "$WD_TMP/last.json"
  done < <(jq -r '"\(.id) \(.updated) \(.comments)"' "$WD_TMP/cards.jsonl")
  cp "$WD_TMP/last.json" "$LAST"

  # Ticket titles: an optional regex (issues.titlePattern) with a named group "p" for the
  # priority word, mapped by issues.priorityLabels, e.g. {"High": "high"}. The matched
  # prefix is removed from the shown title. Without them, titles are shown as they are.
  jq -s --slurpfile last "$WD_TMP/last.json" --slurpfile roster "$ROSTER" --argjson me "${ME:-0}" \
     --arg pat "$(cfg '.basecamp.issues.titlePattern')" --argjson labels "$(cfgj '.basecamp.issues.priorityLabels // {}')" '
    # any ISO 8601 time (Z or ±hh:mm, with or without fractions) → epoch seconds
    def ts($t): ($t | capture("^(?<d>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")) as $m
      | (($m.d + "Z") | fromdate)
        - (if ($m.z // "Z") == "Z" then 0
           else (($m.z[1:3] | tonumber) * 3600 + ($m.z[-2:] | tonumber) * 60) * (if $m.z[0:1] == "+" then 1 else -1 end) end);
    def hrs($t): ((now - ts($t)) / 3600);
    [ .[] | . as $c
      | (if $pat == "" then "" else (($c.title | try capture($pat).p catch null) // "") end) as $p
      | ($labels[$p] // "normal") as $prio
      | ($last[0][($c.id | tostring)] // null) as $lc
      | ($lc != null and ($roster[0] | index($lc.by)) != null) as $ours
      | hrs($c.created) as $age | hrs($c.updated) as $idle
      | ($c.assignees == [$me]) as $onlyMe
      | (if $prio == "high" and $c.comments == 0 and $age > 1 then {level: "red", why: "High priority and nobody has replied"}
         elif $lc != null and ($ours | not) and $idle > (if $prio == "high" then 2 else 8 end) then {level: "red", why: "Waiting on us for \($idle | floor) hours"}
         elif $prio == "high" and $age > 24 then {level: "red", why: "High priority, open \($age / 24 | floor) days"}
         elif $onlyMe and $idle > 4 then {level: "red", why: "Only you are assigned"}
         elif $age < 2 then {level: "amber", why: "New"}
         elif $lc != null and ($ours | not) then {level: "amber", why: "Requester replied"}
         elif ($prio == "medium" and $age > 48) then {level: "amber", why: "Open \($age / 24 | floor) days"}
         elif $ours and $idle > 72 then {level: "amber", why: "We replied \($idle / 24 | floor) days ago — close it?"}
         elif $ours then {level: "quiet", why: "Waiting on requester"}
         else {level: "quiet", why: "" } end) as $verdict
      | {id: $c.id, title: (if $pat == "" then $c.title else ($c.title | try sub($pat; "") catch $c.title) end), raw: $c.title, priority: $prio,
         created: $c.created, updated: $c.updated, comments: $c.comments, url: $c.url,
         lastBy: (if $lc == null then null elif $ours then "us" else "requester" end),
         assignedToMe: ($c.assignees | index($me) != null)} + $verdict ]
    | sort_by([({red: 0, amber: 1, quiet: 2}[.level]), .created]) ' "$WD_TMP/cards.jsonl" >"$WD_TMP/issues.json"
else
  echo '[]' >"$WD_TMP/issues.json"
fi

# ── inbox and error chat (in parallel) ──────────────────────────────────────
basecamp notifications list -q --json >"$WD_TMP/notif.json" 2>/dev/null &
EP=$(cfg '.basecamp.errorChat.project'); ER=$(cfg '.basecamp.errorChat.room')
# enough lines to cover 24 h on a busy day (config errorChat.lines, default 600)
[ -n "$EP" ] && basecamp chat messages -p "$EP" -r "$ER" -n "$(cfg '.basecamp.errorChat.lines // 600')" -q --json >"$WD_TMP/chat.json" 2>/dev/null &
wait
for f in notif chat; do jq -e . "$WD_TMP/$f.json" >/dev/null 2>&1 || echo 'null' >"$WD_TMP/$f.json"; done

jq -n --slurpfile issues "$WD_TMP/issues.json" --slurpfile n "$WD_TMP/notif.json" --slurpfile chat "$WD_TMP/chat.json" \
      --arg match "$(cfg '.basecamp.errorChat.match')" --arg me "$(cfg '.me.name')" --slurpfile cfg "$CONFIG" \
      --arg group "$(cfg '.basecamp.errorChat.groupPattern')" '
  def ts($t): ($t | capture("^(?<d>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")) as $m
    | (($m.d + "Z") | fromdate)
      - (if ($m.z // "Z") == "Z" then 0
         else (($m.z[1:3] | tonumber) * 3600 + ($m.z[-2:] | tonumber) * 60) * (if $m.z[0:1] == "+" then 1 else -1 end) end);
  {issues: $issues[0],
   inbox: (if $n[0] then {
     items: [$n[0].unreads[]? | select(.section == "pings" or .type == "Mention")
             | {kind: (if .section == "pings" then "ping" else "mention" end),
                title: (.title | sub("^@?mentioned you:\\s*"; "")),
                excerpt: ((.content_excerpt // "") | gsub("<[^>]+>"; " ") | gsub("\\s+"; " ") | .[0:160]),
                # a ping room is named after its people: show the others, not you
                who: (if .section == "pings" then (.bucket_name | split(" + ") | map(select(. != $me)) | join(", ")) else null end),
                where: .bucket_name, url: .app_url, at: (.unread_at // .updated_at), count: (.unread_count // 1)}]
            | sort_by(.at) | reverse} else {error: "Basecamp notifications unavailable"} end),
   errors: (if $chat[0] == null or $match == "" then null else
     ([$chat[0][] | select((.content // "") | try test($match; "i") catch false)]) as $prod
     | {label: ($cfg[0].basecamp.errorChat.label // "Error log"),
        lastHour: ([$prod[] | select(ts(.created_at) > now - 3600)] | length),
        last24h: ([$prod[] | select(ts(.created_at) > now - 86400)] | length),
        top: ([$prod[] | select(ts(.created_at) > now - 86400) | (.content | gsub("<[^>]+>"; " ") | if $group == "" then (gsub("\\s+"; " ") | .[0:60]) else (try capture($group).t catch null // "other") end) | gsub("^\\s+|\\s+$"; "")]
              | group_by(.) | map({title: .[0], count: length}) | sort_by(-.count) | .[0:3]),
        url: "https://3.basecamp.com/\($cfg[0].basecamp.account)/buckets/\($cfg[0].basecamp.errorChat.project)/chats/\($cfg[0].basecamp.errorChat.room)"} end),
   checkedAt: (now | todate)}'
