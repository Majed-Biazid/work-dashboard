#!/bin/bash
# Linear, assigned to me:
#   active — started (In Progress, In Review…): what I am working on now
#   next   — triage and urgent/high to-do: what is about to need me
#   done   — completed today (feeds the day summary)
#   all    — every open issue assigned to me, for the filterable list
. "$(dirname "$0")/lib.sh"
KEY=$(keychain "$(cfg '.linear.keychainService')")
[ -z "$(cfg '.linear.keychainService')" ] && { err_json "Set linear.keychainService in the config"; exit 0; }
[ -z "$KEY" ] && { err_json "No Linear API key in Keychain (service: $(cfg '.linear.keychainService'))"; exit 0; }
keep_last_if_offline

read -r -d '' Q <<GQL
query {
  viewer {
    open: assignedIssues(first: 150, orderBy: updatedAt,
      filter: { state: { type: { in: ["started", "unstarted", "triage", "backlog"] } } }) {
      nodes { identifier title url priority updatedAt startedAt dueDate
              state { name type } project { name } cycle { number endsAt }
              team { key name } labels { nodes { name } } }
    }
    done: assignedIssues(first: 30, filter: { completedAt: { gte: "$TODAY_START" } }) {
      nodes { identifier title url completedAt state { name } }
    }
  }
}
GQL

out=$(curl -sS --max-time 20 https://api.linear.app/graphql -H "Content-Type: application/json" -H @- \
      -d "$(jq -cn --arg q "$Q" '{query: $q}')" <<<"Authorization: $KEY" 2>&1)   # the key on stdin, not in ps
if ! jq -e '.data.viewer' >/dev/null 2>&1 <<<"$out"; then
  err_json "Linear: $(jq -r '.errors[0].message // empty' <<<"$out" 2>/dev/null || head -c 150 <<<"$out")"; exit 0
fi
jq -c '.data.viewer as $v
  | def slim: {id: .identifier, title, url, priority, state: .state.name, stateType: .state.type,
               updated: .updatedAt, started: .startedAt, due: .dueDate, project: (.project.name // null),
               team: (.team.key // null), teamName: (.team.name // null), labels: [.labels.nodes[]?.name]};
  {active: [$v.open.nodes[] | select(.state.type == "started") | slim] | sort_by(.priority == 0, .priority, .updated),
   next:   [$v.open.nodes[] | select(.state.type == "triage" or (.priority >= 1 and .priority <= 2)) | select(.state.type != "started" and .state.type != "backlog") | slim]
           | sort_by(.priority == 0, .priority),
   openCount: ($v.open.nodes | length),
   all:    [$v.open.nodes[] | slim],
   done:   [$v.done.nodes[] | {id: .identifier, title, url, at: .completedAt}],
   checkedAt: (now | todate)}' <<<"$out"
