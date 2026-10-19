#!/bin/bash
# Cloud SQL load, per configured instance, over the last `databases.hours` (24):
#   CPU, memory, disk, open connections, up/down, and (on replicas) replica lag —
#   from Cloud Monitoring, in 5-minute buckets, plus the connection limit.
# Read-only: one `gcloud sql instances list` (tiers, flags, which is a replica) and
# GET timeSeries calls. It never connects to a database.
. "$(dirname "$0")/lib.sh"; tmpdir

N=$(cfgj '.databases.instances // [] | length')
[ -z "$N" ] || [ "$N" = 0 ] && { echo '{"instances":[]}'; exit 0; }
keep_last_if_offline
have gcloud || { err_json "gcloud is not installed"; exit 0; }
PROJECT=$(cfg '.databases.project'); PROJECT=${PROJECT:-$(gcloud config get-value project 2>/dev/null)}
HOURS=$(cfg '.databases.hours'); HOURS=${HOURS:-24}
STEP=300

TOKEN=$(gcloud auth print-access-token 2>/dev/null) || TOKEN=""
[ -z "$TOKEN" ] && { err_json "Google login expired — run: gcloud auth login"; exit 0; }

END=$(date -u +%Y-%m-%dT%H:%M:%SZ); START=$(date -u -v-"${HOURS}"H +%Y-%m-%dT%H:%M:%SZ)
IDS=$(jq -r --arg p "$PROJECT" '[.databases.instances[].id | "\"\($p):\(.)\""] | join(",")' "$CONFIG")

series() {   # $1 key  $2 metric  $3 aligner  $4 start  [$5 reducer] → $WD_TMP/m-$1.json
  local args=(--data-urlencode "filter=metric.type=\"cloudsql.googleapis.com/database/$2\" AND resource.label.database_id=one_of($IDS)"
              --data-urlencode "interval.startTime=$4" --data-urlencode "interval.endTime=$END"
              --data-urlencode "aggregation.alignmentPeriod=${STEP}s" --data-urlencode "aggregation.perSeriesAligner=$3")
  [ -n "$5" ] && args+=(--data-urlencode "aggregation.crossSeriesReducer=$5" --data-urlencode "aggregation.groupByFields=resource.label.database_id")
  # the token goes in on stdin, never on the command line (ps shows arguments)
  curl -s -m 30 -G "https://monitoring.googleapis.com/v3/projects/$PROJECT/timeSeries" -H @- "${args[@]}" \
    <<<"Authorization: Bearer $TOKEN" >"$WD_TMP/m-$1.json"
}
series cpu         cpu/utilization                 ALIGN_MEAN "$START" &
series memory      memory/utilization              ALIGN_MEAN "$START" &
series disk        disk/utilization                ALIGN_MEAN "$START" &
series connections postgresql/num_backends         ALIGN_MEAN "$START" REDUCE_SUM &
series up          up                              ALIGN_MIN  "$START" &
series lag         replication/replica_lag         ALIGN_MAX  "$START" &
series quota       memory/quota                    ALIGN_MAX  "$(date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" &
gcloud sql instances list --project "$PROJECT" --format=json >"$WD_TMP/instances.json" 2>"$WD_TMP/gerr" &
wait

# an API error (expired login, no permission) is one message, not empty graphs
APIERR=$(jq -r '.error.message // empty' "$WD_TMP/m-cpu.json" 2>/dev/null)
if [ -n "$APIERR" ] || ! jq -e '.' "$WD_TMP/m-cpu.json" >/dev/null 2>&1; then
  grep -qiE 'auth|credential|token' <<<"$APIERR" && APIERR="Google login expired — run: gcloud auth login"
  err_json "Cloud Monitoring: ${APIERR:-no answer}"; exit 0
fi
jq -e 'type == "array"' "$WD_TMP/instances.json" >/dev/null 2>&1 || echo '[]' >"$WD_TMP/instances.json"
for k in memory disk connections up lag quota; do jq -e '.' "$WD_TMP/m-$k.json" >/dev/null 2>&1 || echo '{}' >"$WD_TMP/m-$k.json"; done

jq -n --slurpfile cfg "$CONFIG" --slurpfile gi "$WD_TMP/instances.json" --arg project "$PROJECT" --argjson hours "$HOURS" --argjson step "$STEP" \
  --slurpfile cpu "$WD_TMP/m-cpu.json" --slurpfile memory "$WD_TMP/m-memory.json" --slurpfile disk "$WD_TMP/m-disk.json" \
  --slurpfile connections "$WD_TMP/m-connections.json" --slurpfile up "$WD_TMP/m-up.json" --slurpfile lag "$WD_TMP/m-lag.json" \
  --slurpfile quota "$WD_TMP/m-quota.json" '
  # Cloud SQL default max_connections by memory (GB) of the largest primary in the chain.
  # The memory is the tier'"'"'s (db-custom-<cpus>-<MB>); otherwise memory/quota, which reads
  # about 5% under the advertised size (3.58 for 3.75 GB), so it is scaled back up.
  def default_max($gb): if $gb == null then null elif $gb >= 120 then 1000 elif $gb >= 60 then 800 elif $gb >= 30 then 600
    elif $gb >= 15 then 500 elif $gb >= 7.5 then 400 elif $gb >= 6 then 200 elif $gb >= 3.75 then 100 elif $gb >= 1.7 then 50 else 25 end;
  def val: .value.doubleValue // (.value.int64Value | tonumber?) // null;
  def pts($m; $id; $prec): [($m[0].timeSeries // [])[] | select(.resource.labels.database_id == "\($project):\($id)") | .points[]
    | [(.interval.endTime | sub("\\.[0-9]+Z$"; "Z") | fromdate), (val | if . == null then null else (. * $prec | round) / $prec end)]] | sort_by(.[0]);
  def last_of($p): ($p | last // null | if . then .[1] else null end);
  def peak_of($p): ($p | max_by(.[1]) // null);
  ($gi[0] | map({key: .name, value: .}) | from_entries) as $info
  | {project: $project, hours: $hours, step: $step, checkedAt: (now | todate),
     instances: [$cfg[0].databases.instances[] as $c
       | ($info[$c.id] // {}) as $g
       | ($g.masterInstanceName // null | if . then split(":") | last else null end) as $primary
       | (($info[$primary // $c.id] // $g).settings.tier // "" | capture("^db-custom-[0-9]+-(?<mb>[0-9]+)$").mb // null | if . then tonumber / 1024 else null end) as $tiergb
       | ([($quota[0].timeSeries // [])[] | select(.resource.labels.database_id == "\($project):\($primary // $c.id)") | .points[0] | val] | first) as $qbytes
       | ([($g.settings.databaseFlags // [])[] | select(.name == "max_connections") | .value | tonumber] | first) as $flag
       | {cpu: pts($cpu; $c.id; 1000), memory: pts($memory; $c.id; 1000), disk: pts($disk; $c.id; 1000),
          connections: pts($connections; $c.id; 10), up: pts($up; $c.id; 1), lag: pts($lag; $c.id; 10)} as $s
       | {id: $c.id, name: ($c.name // $c.id), detail: ($c.detail // (if $primary then "replica" else "" end)),
          replica: ($primary != null), primary: $primary, tier: ($g.settings.tier // null), state: ($g.state // null),
          diskGb: ($g.settings.dataDiskSizeGb // null | if . then tonumber else null end),
          diskGrows: ($g.settings.storageAutoResize // false),   # Cloud SQL adds space by itself as it fills
          maxConnections: ($c.maxConnections // $flag // default_max($tiergb // (if $qbytes then $qbytes / 1073741824 * 1.06 else null end))),
          up: last_of($s.up),
          now: ($s | with_entries(.value = last_of(.value))),
          peak: ($s | with_entries(.value = peak_of(.value))),
          series: ($s | del(.up) | if $primary then . else del(.lag) end)}
     ]}'
