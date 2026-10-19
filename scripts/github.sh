#!/bin/bash
# GitHub, in one GraphQL call plus one events call:
#   reviews  — open PRs waiting for my review; teammates first, then by wait time
#   mine     — my open PRs, each reduced to ONE next action (fix CI, address changes,
#              reply, merge, nudge, or nothing — waiting on someone else)
#   pushed   — branches I pushed in the last 3 days that have no PR yet
#   radar    — repos whose develop is ahead of main (what a release would ship)
# Bots (CodeRabbit, Actions, …) never count as "someone responded".
. "$(dirname "$0")/lib.sh"; tmpdir
ORG=$(cfg '.github.org'); ME=$(cfg '.me.github')
[ -z "$ORG" ] || [ -z "$ME" ] && { err_json "Set github.org and me.github in the config"; exit 0; }
keep_last_if_offline

read -r -d '' QUERY <<'GQL'
fragment PR on PullRequest {
  number title url isDraft createdAt updatedAt additions deletions headRefName body
  repository { name } author { login ... on User { name } }
  reviewDecision
  reviewRequests(first: 10) { nodes { requestedReviewer { ... on User { login name } ... on Team { name } } } }
  latestReviews(first: 10) { nodes { author { login ... on User { name } } state submittedAt } }
  commits(last: 1) { nodes { commit { committedDate statusCheckRollup { state } } } }
  comments(last: 15) { nodes { author { login } createdAt } }
  reviewThreads(last: 50) { nodes { isResolved comments(last: 1) { nodes { author { login } createdAt } } } }
  timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT], last: 10) {
    nodes { ... on ReviewRequestedEvent { createdAt requestedReviewer { ... on User { login } } } } }
}
query($reviews: String!, $mine: String!, $merged: String!) {
  reviews: search(query: $reviews, type: ISSUE, first: 30) { nodes { ...PR } }
  mine: search(query: $mine, type: ISSUE, first: 30) { nodes { ...PR } }
  merged: search(query: $merged, type: ISSUE, first: 20) { nodes { ... on PullRequest { number title url body headRefName mergedAt baseRefName repository { name } } } }
}
GQL

gh api graphql -f query="$QUERY" \
  -f reviews="is:pr is:open archived:false org:$ORG review-requested:$ME" \
  -f mine="is:pr is:open archived:false org:$ORG author:$ME" \
  -f merged="is:pr is:merged archived:false org:$ORG author:$ME merged:>=$(date -v-3d +%F)" >"$WD_TMP/gql.json" 2>"$WD_TMP/gql.err" &
gh api "users/$ME/events?per_page=100" >"$WD_TMP/events.json" 2>/dev/null &

# release radar: develop ahead of main, per repo. A compare depends only on the two
# branch heads, so one GraphQL call reads every repo's heads and the (heavy) compare
# runs only for a repo whose main or develop moved since the last run.
RADAR=$(cfgj '[.github.releaseRadar[]?]'); RADAR=${RADAR:-[]}
RCACHE="$HOME/Library/Caches/work-dashboard/github-radar.json"; mkdir -p "${RCACHE%/*}"; [ -s "$RCACHE" ] || echo '{}' >"$RCACHE"
radar_one() {   # $1 repo  $2 "main-oid..develop-oid" ("" = unknown: always compare)
  local r=$1 key=$2 out
  if [ -n "$key" ] && jq -e --arg r "$r" --arg k "$key" '.[$r].key == $k' "$RCACHE" >/dev/null 2>&1; then
    jq -c --arg r "$r" '.[$r].entry' "$RCACHE" >"$WD_TMP/radar-$r.json"; return
  fi
  out=$(gh api "repos/$ORG/$r/compare/main...develop" 2>/dev/null) &&
    jq -c --arg r "$r" '{repo: $r, ahead: .ahead_by, since: (.commits[0].commit.committer.date // null), url: .html_url,
      prs: [.commits[] | .commit.message as $m
        | if ($m | test("^Merge pull request #[0-9]+")) then {n: ($m | capture("#(?<n>[0-9]+)").n), title: (($m | split("\n") | map(select(length > 0)))[1] // "")}
          elif ($m | split("\n")[0] | test("\\(#[0-9]+\\)$")) then {n: ($m | split("\n")[0] | capture("\\(#(?<n>[0-9]+)\\)$").n), title: ($m | split("\n")[0] | sub(" \\(#[0-9]+\\)$"; ""))}
          else empty end | select(.title | test("^(Merge|Sync|Deploy) "; "i") | not)] | unique_by(.n)}' <<<"$out" >"$WD_TMP/radar-$r.json" &&
    [ -n "$key" ] && printf '%s' "$key" >"$WD_TMP/radar-$r.key"
}
[ "$RADAR" != "[]" ] && (
  HQ=$(jq -r --arg org "$ORG" 'to_entries | map("r\(.key): repository(owner: \"\($org)\", name: \"\(.value)\") { main: ref(qualifiedName: \"refs/heads/main\") { target { oid } } develop: ref(qualifiedName: \"refs/heads/develop\") { target { oid } } }") | "query { \(join(" ")) }"' <<<"$RADAR")
  heads=$(gh api graphql -f query="$HQ" 2>/dev/null | jq -c --argjson repos "$RADAR" '.data as $d | [$repos | to_entries[]
    | {key: .value, value: ($d["r\(.key)"] | if .main.target.oid and .develop.target.oid then "\(.main.target.oid)..\(.develop.target.oid)" else "" end)}] | from_entries' 2>/dev/null)
  for r in $(jq -r '.[]' <<<"$RADAR"); do radar_one "$r" "$(jq -r --arg r "$r" '.[$r] // ""' <<<"${heads:-"{}"}")" & done
  wait
) &
wait

if ! jq -e '.data' "$WD_TMP/gql.json" >/dev/null 2>&1; then
  err_json "GitHub: $(head -c 200 "$WD_TMP/gql.err")"; exit 0
fi
jq -s '.' "$WD_TMP"/radar-*.json 2>/dev/null >"$WD_TMP/radar.json" || true
for k in "$WD_TMP"/radar-*.key; do   # remember the heads each fresh compare was made for
  [ -f "$k" ] || continue; r=${k##*/radar-}; r=${r%.key}
  jq -c --arg r "$r" --rawfile k "$k" '{($r): {key: $k, entry: .}}' "$WD_TMP/radar-$r.json"
done | jq -s --slurpfile c "$RCACHE" 'add as $new | if $new then $c[0] + $new else $c[0] end' >"$RCACHE.tmp" 2>/dev/null && mv "$RCACHE.tmp" "$RCACHE"
[ -s "$WD_TMP/radar.json" ] || echo '[]' >"$WD_TMP/radar.json"
[ -s "$WD_TMP/events.json" ] && jq -e 'type == "array"' "$WD_TMP/events.json" >/dev/null 2>&1 || echo '[]' >"$WD_TMP/events.json"

jq -n --slurpfile g "$WD_TMP/gql.json" --slurpfile ev "$WD_TMP/events.json" --slurpfile radar "$WD_TMP/radar.json" \
      --slurpfile cfg "$CONFIG" --arg me "$ME" --arg org "$ORG" '
  def ts($t): if $t == null then 0 else ($t | sub("\\.[0-9]+Z$"; "Z") | fromdate) end;
  def hours($t): ((now - ts($t)) / 3600 | floor);
  def bot($l): ($l // "") | test("\\[bot\\]$|^(coderabbitai|github-actions|qodo|sonarcloud|codecov|dependabot|vercel|netlify)"; "i");
  ($cfg[0].team // []) as $team
  | ($cfg[0].github.reviewWaitHours // {amber: 24, red: 72}) as $wait
  | def teamName($l): ([$team[] | select(.github == $l) | .name] | first);
  def who($a): (teamName($a.login) // (($a.name // "") | split(" ")[0] | select(length > 0)) // $a.login);
  def base: {number, title, url, repo: .repository.name, author: (.author.login // "ghost"), draft: .isDraft,
             size: ((.additions // 0) + (.deletions // 0)), created: .createdAt, updated: .updatedAt,
             ci: (.commits.nodes[0].commit.statusCheckRollup.state // null)};

  # ── waiting for my review ──
  ([$g[0].data.reviews.nodes[] | select(.isDraft | not) | . as $pr
    # when I was asked; a team request (no event naming me) falls back to when the PR was opened
    | (([.timelineItems.nodes[] | select(.requestedReviewer.login == $me) | .createdAt] | max) // $pr.createdAt) as $asked
    | ([.latestReviews.nodes[] | select(.author.login == $me)] | first) as $mine
    | base + {
        teammate: teamName(.author.login), authorName: who(.author),
        keys: ([.title | scan("[A-Z][A-Z0-9]{1,6}-[0-9]+")] | unique),
        askedAt: $asked, waitingHours: hours($asked),
        again: ($mine != null),
        level: (if hours($asked) >= $wait.red then "red" elif hours($asked) >= $wait.amber then "amber" else "quiet" end)
      }]
   | sort_by([(if .teammate then 0 else 1 end), -.waitingHours])) as $reviews

  # ── my PRs → one action each ──
  | ([$g[0].data.mine.nodes[] | . as $pr
    | (.commits.nodes[0].commit.committedDate) as $push
    | ([.comments.nodes[] | select(.author.login != $me and (bot(.author.login) | not) and ts(.createdAt) > ts($push))] | length) as $newComments
    | ([.latestReviews.nodes[] | select(.author.login != $me and (bot(.author.login) | not))]) as $reviews
    | ([.reviewThreads.nodes[] | select(.isResolved | not) | .comments.nodes[0] | select(.author.login != $me)]) as $openThreads
    | ([$openThreads[] | select(bot(.author.login) | not)] | length) as $humanThreads
    | ([$openThreads[] | select(bot(.author.login))] | length) as $botThreads
    | ([.reviewRequests.nodes[].requestedReviewer | select(. != null) | (if .login then who(.) else .name end)]) as $pending
    | ([$reviews[] | select(.state == "CHANGES_REQUESTED") | who(.author)]) as $changers
    | ([$reviews[] | select(.state == "APPROVED") | who(.author)]) as $approvers
    | base + {
        keys: ([(.title + " " + (.body // "") + " " + .headRefName) | scan("[A-Z][A-Z0-9]{1,6}-[0-9]+")] | unique),
        branch: .headRefName,
        pushed: $push, newComments: $newComments, openThreads: $humanThreads, botThreads: $botThreads,
        pending: $pending, approvedBy: $approvers,
        action: (
          if .isDraft then {kind: "draft", level: "quiet", text: "Draft"}
          elif (.commits.nodes[0].commit.statusCheckRollup.state // "") | test("FAILURE|ERROR") then {kind: "ci", level: "red", text: "Fix CI — checks are failing"}
          elif ($changers | length) > 0 or .reviewDecision == "CHANGES_REQUESTED" then {kind: "changes", level: "red", text: "Address changes from \($changers | join(", "))"}
          elif $humanThreads > 0 then {kind: "reply", level: "amber", text: "Reply to \($humanThreads) open thread\(if $humanThreads == 1 then "" else "s" end)"}
          elif $newComments > 0 then {kind: "read", level: "amber", text: "\($newComments) new comment\(if $newComments == 1 then "" else "s" end) since your last push"}
          elif .reviewDecision == "APPROVED" or (($approvers | length) > 0 and ($pending | length) == 0) then {kind: "merge", level: "go", text: "Approved by \($approvers | join(", ")) — merge"}
          elif ($pending | length) > 0 and hours($push) >= 72 then {kind: "nudge", level: "amber", text: "Waiting on \($pending | join(", ")) for \(hours($push) / 24 | floor) days — nudge"}
          elif ($pending | length) > 0 then {kind: "wait", level: "quiet", text: "Waiting on \($pending | join(", "))"}
          else {kind: "noreviewer", level: "amber", text: "No reviewer requested"} end)
      }]
   | sort_by([({red: 0, amber: 1, go: 2, quiet: 3}[.action.level]), -ts(.updated)])) as $mine

  # ── pushed without a PR (last 3 days) ──
  | ([$mine[] | "\(.repo)|\(.number)"]) as $mineKeys
  | ([$g[0].data.mine.nodes[] | "\(.repository.name)|\(.headRefName)"]) as $prBranches
  | ([$ev[0][] | select(.type == "PushEvent") | select(.repo.name | startswith($org + "/"))
      | select((now - ts(.created_at)) < 3 * 86400)
      | {repo: (.repo.name | split("/")[1]), branch: (.payload.ref | sub("^refs/heads/"; "")), at: .created_at, commits: (.payload.size // 0)}
      | select(.branch | test("^(main|master|develop|staging|release.*)$") | not)]
     | group_by("\(.repo)|\(.branch)") | map({repo: .[0].repo, branch: .[0].branch, at: (map(.at) | max), commits: (map(.commits) | add)})
     | map(select(("\(.repo)|\(.branch)") as $k | $prBranches | index($k) | not))
     | map(. + {url: "https://github.com/\($org)/\(.repo)/compare/\(.branch)?expand=1"})
     | sort_by(.at) | reverse) as $pushed

  # merged in the last 3 days (not release PRs), so their issues never read "No PR yet"
  | ([$g[0].data.merged.nodes[] | select(.headRefName | test("^(develop|main|master)$") | not)
      | {number, title, url, repo: .repository.name, mergedAt, base: .baseRefName,
         keys: ([(.title + " " + (.body // "") + " " + .headRefName) | scan("[A-Z][A-Z0-9]{1,6}-[0-9]+")] | unique)}]) as $merged
  | {reviews: $reviews, mine: $mine, merged: $merged, pushed: $pushed,
     radar: [$radar[0][] | select(.ahead > 0)] | sort_by(-.ahead),
     checkedAt: (now | todate)}' >"$WD_TMP/out.json" || { err_json "GitHub: the response couldn't be read"; exit 0; }

# A branch whose PR was already merged or closed is not "pushed without a PR".
jq -r '.pushed[] | "\(.repo)\t\(.branch)"' "$WD_TMP/out.json" | while IFS=$'\t' read -r repo branch; do
  n=$(gh pr list -R "$ORG/$repo" --head "$branch" --state all --limit 1 --json number --jq 'length' 2>/dev/null || echo 0)
  [ "${n:-0}" -gt 0 ] && printf '%s|%s\n' "$repo" "$branch"
done >"$WD_TMP/has-pr.txt"
jq --rawfile has "$WD_TMP/has-pr.txt" '.pushed |= map(select(("\(.repo)|\(.branch)") as $k | ($has | split("\n") | index($k)) | not) | del(.commits))' "$WD_TMP/out.json" \
  || err_json "GitHub: the response couldn't be read"
