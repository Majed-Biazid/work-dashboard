# Shared helpers for the collectors. Source it: `. "$(dirname "$0")/lib.sh"`.
#
# Every collector prints ONE JSON object on stdout and exits 0, even when its
# source fails — the failure goes inside the JSON as {"error": "..."} so the app
# can show it next to that section without blanking anything else.
# Collectors are read-only: list / get / search calls only.

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
CONFIG="${WD_CONFIG:-$HOME/.config/work-dashboard/config.json}"
export TZ="$(jq -r '.timezone // "UTC"' "$CONFIG" 2>/dev/null || echo UTC)"
TODAY="${WD_DAY:-$(date +%F)}"   # WD_DAY=YYYY-MM-DD replays another day (testing)
TODAY_START="$(date -j -f '%Y-%m-%d %H:%M:%S' "$TODAY 00:00:00" +%Y-%m-%dT%H:%M:%S%z | sed -E 's/([+-][0-9]{2})([0-9]{2})$/\1:\2/')"
TODAY_EPOCH="$(date -j -f '%Y-%m-%d %H:%M:%S' "$TODAY 00:00:00" +%s)"   # midnight in config.timezone

cfg()  { jq -r "$1 // empty" "$CONFIG" 2>/dev/null; }     # a scalar, "" if missing
cfgj() { jq -c "$1" "$CONFIG" 2>/dev/null; }              # JSON
expand_path() { printf '%s' "${1/#\~/$HOME}"; }
keychain() { [ -n "$1" ] && security find-generic-password -s "$1" -w 2>/dev/null; }
err_json() { jq -cn --arg e "$1" '{error: ($e | .[0:300])}'; }
have() { command -v "$1" >/dev/null 2>&1; }
# No default route = no network (lid just opened, Wi-Fi off). Collectors that
# depend on the network say "offline" instead of reporting things as broken.
online() { route -n get default >/dev/null 2>&1; }
# For collectors whose last result is still the best answer while offline: print
# nothing and exit 75, and the app keeps showing the last good result (the
# offline banner comes from health.sh and local.sh).
keep_last_if_offline() { online || exit 75; }


# A temp dir that cleans itself up, for collectors that fan out in parallel.
tmpdir() { WD_TMP=$(mktemp -d); trap 'rm -rf "$WD_TMP"' EXIT; }
