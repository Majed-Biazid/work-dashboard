#!/bin/bash
# What I did with Claude between two days, for the standup write-up (standup.sh):
#   standup-sessions.sh <FROM YYYY-MM-DD> <TO YYYY-MM-DD>
# My prompts in that window (from ~/.claude/history.jsonl), then per session active in
# it: its title, branches, the commands I ran, the write-actions taken (PRs, commits,
# Linear saves, Basecamp posts, artifacts…), files edited, and the PRs / issue keys it
# referenced. Reads transcript files only; prints plain text.
. "$(dirname "$0")/lib.sh"
FROM=$1; TO=${2:-$1}
[ -z "$FROM" ] && { echo "usage: $0 FROM [TO]" >&2; exit 2; }
ROOT=$(expand_path "$(cfg '.claude.projectsDir')"); ROOT=${ROOT:-$HOME/.claude/projects}
HIST="$(dirname "$ROOT")/history.jsonl"
ORG=$(cfg '.github.org')
KEYS=$(cfgj '.claude.issueKeys // [] | join("|")' | tr -d '"'); KEYS=${KEYS:-[A-Z][A-Z0-9]{1,6}}

START_S=$(date -j -f '%Y-%m-%d %H:%M:%S' "$FROM 00:00:00" +%s)
END_S=$(date -j -f '%Y-%m-%d %H:%M:%S' "$TO 23:59:59" +%s)
START_UTC=$(TZ=UTC date -r "$START_S" +%Y-%m-%dT%H:%M:%SZ)
END_UTC=$(TZ=UTC date -r "$END_S" +%Y-%m-%dT%H:%M:%SZ)
[ "$FROM" = "$TO" ] && FMT='%H:%M' || FMT='%a %H:%M'   # the weekday on multi-day windows
short() { sed "s|^$HOME|~|"; }
join_dot() { awk '{printf "%s%s", sep, $0; sep=" · "} END{if(NR)print ""}'; }
local_time() { local e; e=$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "${1%%.*}" +%s 2>/dev/null) || return; date -r "$e" +"$FMT"; }

echo "## My prompts (what I asked for, local time)"
jq -r --argjson s "$((START_S * 1000))" --argjson e "$((END_S * 1000))" '
  select(.timestamp >= $s and .timestamp <= $e)
  | [(.timestamp / 1000 | floor | tostring), (.project // "?"), (.sessionId // "-")[0:8],
     (.display // "" | gsub("\\s+"; " ") | .[0:400])] | @tsv' "$HIST" 2>/dev/null \
| while IFS=$'\t' read -r ep proj sid text; do
    [ -z "${text// }" ] && continue
    printf '%s  [%s] (%s)  %s\n' "$(date -r "$ep" +"$FMT")" "$(short <<<"$proj")" "$sid" "$text"
  done
echo

echo "## Sessions active in that window — what got done in them"
find "$ROOT" -name '*.jsonl' -not -path '*/subagents/*' -newermt "$FROM 00:00:00" 2>/dev/null \
| while read -r f; do
    TS=$(jq -r --arg s "$START_UTC" --arg e "$END_UTC" 'select(.timestamp != null and .timestamp >= $s and .timestamp <= $e) | .timestamp' "$f" 2>/dev/null | sort)
    [ -z "$TS" ] && continue
    printf '%s\t%s\t%s\n' "$(head -1 <<<"$TS")" "$(tail -1 <<<"$TS")" "$f"
  done | sort | while IFS=$'\t' read -r FIRST LAST f; do
  SID=$(basename "$f" .jsonl)
  CWD=$(jq -r 'select(.cwd) | .cwd' "$f" 2>/dev/null | tail -1 | short)
  TITLE=$(jq -r 'select(.type == "custom-title") | .customTitle' "$f" 2>/dev/null | tail -1)
  [ -z "$TITLE" ] && TITLE=$(jq -r 'select(.type == "ai-title") | .aiTitle' "$f" 2>/dev/null | tail -1)
  BR=$(jq -r 'select(.gitBranch != null and .gitBranch != "" and .gitBranch != "HEAD") | .gitBranch' "$f" 2>/dev/null | sort -u | head -5 | join_dot)

  echo "### [$(local_time "$FIRST")–$(local_time "$LAST")]  ${CWD:-?}  (${SID:0:8})"
  [ -n "$TITLE" ] && echo "title: $TITLE"
  [ -n "$BR" ] && echo "branches: $BR"

  CMDS=$(jq -r --arg s "$START_UTC" --arg e "$END_UTC" '
      select(.type == "user" and .timestamp >= $s and .timestamp <= $e and (.isMeta | not))
      | (if (.message.content | type) == "string" then .message.content else "" end)
      | select(test("<command-name>"))
      | (capture("<command-name>(?<c>[^<]*)</command-name>").c) + " " + ((capture("<command-args>(?<a>[^<]*)</command-args>").a) // "")
    ' "$f" 2>/dev/null | sed 's/ *$//' | sort -u | head -20)
  [ -n "$CMDS" ] && { echo "commands run:"; sed 's/^/  - /' <<<"$CMDS"; }

  # write-actions only: what changed something somewhere, not the reading around it
  ACTS=$(jq -r --arg s "$START_UTC" --arg e "$END_UTC" '
      select(.type == "assistant" and .timestamp >= $s and .timestamp <= $e and (.isSidechain | not))
      | .message.content[]? | select(.type == "tool_use")
      | if   .name == "Bash"     then "bash: " + ((.input.command // "") | gsub("\\s+"; " ") | .[0:200])
        elif .name == "Skill"    then "skill: /" + (.input.skill // "") + " " + ((.input.args // "") | .[0:140])
        elif .name == "Artifact" then "artifact: " + (.input.action // "publish") + " " + ((.input.title // (.input.file_path // "" | split("/") | last) // "") | .[0:100])
        elif (.name | startswith("mcp__")) then "mcp: " + (.name | sub("^mcp__"; "")) + " " + ((.input | tostring) | gsub("\\s+"; " ") | .[0:170])
        else empty end
    ' "$f" 2>/dev/null \
    | grep -Ei 'gh (pr|issue|api|release|run|repo|workflow)|git (commit|push|merge|tag|revert|cherry)|basecamp |linear-server__(save|create|submit|merge|resolve|share|mark)|notion-(create|update)|__(create|update|copy|share|trash|respond|delete)|^skill: |^artifact: |psql|kubectl|gcloud' \
    | grep -Ev 'gh (pr|issue|run|release) (view|list|diff|checks|status|logs)|gh search|kubectl (get|logs|describe)|gcloud [a-z-]* (list|describe)' \
    | awk '!seen[$0]++' | head -22)
  [ -n "$ACTS" ] && { echo "actions taken:"; sed 's/^/  - /' <<<"$ACTS"; }

  FILES=$(jq -r --arg s "$START_UTC" --arg e "$END_UTC" '
      select(.type == "assistant" and .timestamp >= $s and .timestamp <= $e and (.isSidechain | not))
      | .message.content[]? | select(.type == "tool_use" and (.name == "Edit" or .name == "Write" or .name == "NotebookEdit"))
      | .input.file_path // .input.notebook_path // empty
    ' "$f" 2>/dev/null \
    | grep -Ev '^/private/tmp/|^/tmp/|/scratchpad/|/\.claude/(projects|todos|shell-snapshots)/' \
    | short | sort -u | head -12 | join_dot)
  [ -n "$FILES" ] && echo "files edited: $FILES"

  REFS=$(jq -r --arg s "$START_UTC" --arg e "$END_UTC" 'select(.timestamp >= $s and .timestamp <= $e) | tostring' "$f" 2>/dev/null \
    | grep -oE "github\.com/${ORG:-[a-zA-Z0-9-]+}/[a-z0-9._-]+/pull/[0-9]+|\b($KEYS)-[0-9]{1,5}\b|basecamp\.com/[0-9]+/buckets/[0-9]+/[a-z_/]+/[0-9]+" \
    | sed -E 's|github\.com/[^/]+/([a-z0-9._-]+)/pull/([0-9]+)|\1#\2|' | sort -u)
  if [ -n "$REFS" ]; then
    N=$(wc -l <<<"$REFS" | tr -d ' ')
    echo "referenced ($N): $(head -14 <<<"$REFS" | join_dot)$([ "$N" -gt 14 ] && echo ' …')"
  fi
  echo
done
