#!/bin/bash
# What I did today, for the live day summary (outside the standup window):
# PRs merged / opened / reviewed, commits, and my Basecamp posts and replies.
# Linear "done today" comes from linear.sh, Claude sessions from sessions.py,
# meetings from the calendar — the page merges them into one timeline.
. "$(dirname "$0")/lib.sh"; tmpdir
ORG=$(cfg '.github.org'); ME=$(cfg '.me.github'); BCME=$(cfg '.me.basecampPersonId')
keep_last_if_offline   # offline, every search would come back empty: "nothing done today" would be false

# the helper's own flags come first: anything after a "--" in "$@" is search text
s() { gh search prs --owner="$ORG" --json number,title,url,repository,createdAt,closedAt,updatedAt --limit 50 "$@" 2>/dev/null || echo '[]'; }
# without github.org and me.github an empty --owner/--author searches ALL of GitHub
# (strangers' PRs as "your" day): no GitHub part then, Basecamp still counts
if [ -n "$ORG" ] && [ -n "$ME" ]; then
  # full timestamps with the offset: a date alone is read as UTC by GitHub search
  s --author="$ME" --merged-at=">=$TODAY_START" >"$WD_TMP/merged.json" &
  s --author="$ME" --created=">=$TODAY_START" >"$WD_TMP/opened.json" &
  s --reviewed-by="$ME" --updated=">=$TODAY_START" -- "-author:$ME" >"$WD_TMP/review-candidates.json" &
  gh search commits --owner="$ORG" --author="$ME" --author-date=">=$TODAY_START" --json sha,commit,repository,url --limit 100 >"$WD_TMP/commits.json" 2>/dev/null || echo '[]' >"$WD_TMP/commits.json" &
else
  for f in merged opened review-candidates commits; do echo '[]' >"$WD_TMP/$f.json"; done
fi

# Basecamp: what I wrote today (comments, cards, messages, to-dos)
if [ -n "$BCME" ] && have basecamp; then
  for t in comment card message todo; do
    basecamp recordings --type "$t" --sort created_at --direction desc -n 60 -q --json 2>/dev/null \
      | jq -c --argjson me "$BCME" --arg day "$TODAY_START" --arg t "$t" \
          '[.[]? | select(.creator.id == $me) | {kind: $t, title, where: .bucket.name, at: .created_at, url: .app_url}]' >"$WD_TMP/bc-$t.json" &
  done
fi
wait
for f in "$WD_TMP"/*.json; do jq -e . "$f" >/dev/null 2>&1 || echo '[]' >"$f"; done

# "Reviewed" = a review I actually submitted today, at the time I submitted it
# (a PR I reviewed last week that someone touched today is not today's work).
# A PR's reviews change only when the PR does (a review moves updatedAt), so each PR
# is asked once per change, not every minute: the answer is kept for the day.
RC="$HOME/Library/Caches/work-dashboard/today-reviews.json"; mkdir -p "${RC%/*}"
jq -e --arg d "$TODAY" '.day == $d' "$RC" >/dev/null 2>&1 || jq -n --arg d "$TODAY" '{day: $d, prs: {}}' >"$RC"
jq -r '.[] | "\(.repository.name)\t\(.number)\t\(.updatedAt)"' "$WD_TMP/review-candidates.json" | while IFS=$'\t' read -r repo n upd; do
  at=$(jq -c --arg k "$repo#$n" --arg u "$upd" '.prs[$k] | select(. != null and .updated == $u) | .at' "$RC")
  if [ -z "$at" ]; then
    reviews=$(gh api "repos/$ORG/$repo/pulls/$n/reviews" --paginate 2>/dev/null) || continue   # not cached: a failure is asked again next time
    at=$(jq -cs --arg me "$ME" --argjson t0 "$TODAY_EPOCH" \
           '[add // [] | .[] | select(.user.login == $me and .submitted_at != null) | select((.submitted_at | fromdate) >= $t0) | .submitted_at] | max' <<<"$reviews") || continue
    jq -cn --arg k "$repo#$n" --arg u "$upd" --argjson at "$at" '{($k): {updated: $u, at: $at}}' >>"$WD_TMP/reviews-new.jsonl"
  fi
  [ "$at" != null ] && jq -cn --arg repo "$repo" --argjson n "$n" --argjson at "$at" '{repo: $repo, number: $n, at: $at}'
done | jq -s '.' >"$WD_TMP/reviewed-at.json"
[ -s "$WD_TMP/reviews-new.jsonl" ] && jq -s --slurpfile c "$RC" 'add as $new | $c[0] | .prs += $new' "$WD_TMP/reviews-new.jsonl" >"$RC.tmp" && mv "$RC.tmp" "$RC"
jq --slurpfile at "$WD_TMP/reviewed-at.json" '[.[] | . as $p | ($at[0][] | select(.repo == $p.repository.name and .number == $p.number)) as $r | $p + {reviewedAt: $r.at}]' \
  "$WD_TMP/review-candidates.json" >"$WD_TMP/reviewed.json" 2>/dev/null || echo '[]' >"$WD_TMP/reviewed.json"
cat "$WD_TMP"/bc-*.json 2>/dev/null | jq -s 'add // []' >"$WD_TMP/bc.json"

jq -n --slurpfile m "$WD_TMP/merged.json" --slurpfile o "$WD_TMP/opened.json" --slurpfile r "$WD_TMP/reviewed.json" \
      --slurpfile c "$WD_TMP/commits.json" --slurpfile bc "$WD_TMP/bc.json" --arg start "$TODAY_START" '
  def ts($t): ($t | capture("^(?<d>[0-9-]+T[0-9:]+)(\\.[0-9]+)?(?<z>Z|[+-][0-9]{2}:?[0-9]{2})?$")) as $x
    | (($x.d + "Z") | fromdate) - (if ($x.z // "Z") == "Z" then 0
        else (($x.z[1:3] | tonumber) * 3600 + ($x.z[-2:] | tonumber) * 60) * (if $x.z[0:1] == "+" then 1 else -1 end) end);
  ts($start) as $t0
  | def pr($kind; $at): {kind: $kind, title, url, repo: .repository.name, number, at: $at};
  {merged:   [$m[0][] | pr("merged"; .closedAt)],
   opened:   [$o[0][] | pr("opened"; .createdAt)],
   reviewed: [$r[0][] | pr("reviewed"; .reviewedAt)],
   commits:  [$c[0][] | {repo: .repository.name, title: (.commit.message | split("\n")[0]), at: .commit.author.date, url}]
             | map(select(.title | test("^Merge (pull request|branch)|\\[skip ci\\]|bump version"; "i") | not)),
   basecamp: [$bc[0][] | select(ts(.at) >= $t0)],
   checkedAt: (now | todate)}'
