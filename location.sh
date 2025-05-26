#!/usr/bin/env bash
#===============================================================================
#
# FILE: consensus_ip_location.sh
#
# DESCRIPTION:
#   Determine your external IP, fetch Apple PEP country code, then query
#   multiple free GeoIP services to derive a consensus city for that country.
#   Outputs a JSON dict: {"country_code":"XX","city":"City Name"}.
#
# USAGE:
#   curl -sL https://example.com/consensus_ip_location.sh | bash
#
# REQUIREMENTS:
#   - bash ≥4.0
#   - curl, jq, timeout
#
# AUTHOR: Your Name
# LICENSE: MIT
#===============================================================================

set -Eeuo pipefail
trap 'error_exit "Unexpected error on line $LINENO"' ERR
IFS=$'\n\t'

#--- CONFIG -------------------------------------------------------------------
TIMEOUT=3
USER_AGENT='Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0'

# List of fallback GeoIP endpoints (JSON) to query country_code and city
declare -a SERVICES=(
  "http://ip-api.com/json/%IP%?fields=countryCode,city"
  "https://get.geojs.io/v1/ip/geo/%IP%.json"
  "http://ipwhois.app/json/%IP%"
  "https://freeipapi.com/api/json/%IP%"
  "https://api.ip.sb/geoip/%IP%"
)

#--- LOGGING & ERRORS ---------------------------------------------------------
log_info()    { printf '\e[1;34m[INFO]\e[0m %s\n' "$*"; }
log_warn()    { printf '\e[1;33m[WARN]\e[0m %s\n' "$*" >&2; }
error_exit()  { printf '\e[1;31m[ERROR]\e[0m %s\n' "$*" >&2; exit 1; }

#--- DEPENDENCY CHECK ---------------------------------------------------------
for cmd in curl jq timeout; do
  command -v "$cmd" >/dev/null 2>&1 || error_exit "Required command '$cmd' not found"
done

#--- FUNCTIONS ---------------------------------------------------------------

# Detect external IPv4
detect_ip() {
  for src in https://api.ipify.org https://ipinfo.io/ip https://ifconfig.co/ip; do
    if ip=$(timeout "$TIMEOUT" curl -4 -qs "$src"); then
      if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_info "Detected external IP: $ip"
        printf '%s' "$ip"
        return
      fi
    fi
  done
  error_exit "Failed to detect external IP"
}

# Query Apple PEP GCC for country code
get_apple_code() {
  local res
  if ! res=$(timeout "$TIMEOUT" curl -4 -qsL https://gspe1-ssl.ls.apple.com/pep/gcc); then
    log_warn "Apple lookup timed out or failed"
    printf ''
    return
  fi

  # Validate result: non-null, ≤7 chars
  if [[ $res == "null" || ${#res} -gt 7 ]]; then
    log_warn "Invalid Apple response: '$res'"
    printf ''
  else
    log_info "Apple country_code: $res"
    printf '%s' "$res"
  fi
}

# Query ipinfo.io, returns JSON or empty
get_ipinfo() {
  local data code city
  data=$(timeout "$TIMEOUT" curl -4 -qs -A "$USER_AGENT" "https://ipinfo.io/$IP/json" || echo '')
  code=$(jq -r '.country // empty' <<<"$data")
  city=$(jq -r '.city    // empty' <<<"$data")
  if [[ -n $code && -n $city ]]; then
    printf '{"country_code":"%s","city":"%s"}' "$code" "$city"
  else
    printf ''
  fi
}

# Query fallback services, collect cities matching APPLE_CODE
gather_cities() {
  local url out code city tmpl result=()
  for tmpl in "${SERVICES[@]}"; do
    url=${tmpl//%IP%/$IP}
    out=$(timeout "$TIMEOUT" curl -4 -qs -A "$USER_AGENT" "$url" 2>/dev/null || continue)
    code=$(jq -r '
      .countryCode?     // 
      .country?         // 
      .country_code?    //
      .location.country_code? // empty
    ' <<<"$out")
    city=$(jq -r '
      .city? 
      // .location.city? 
      // empty
    ' <<<"$out")
    if [[ $code == "$APPLE_CODE" && -n $city ]]; then
      result+=("$city")
      log_info "Matched $code → $city from $url"
    fi
  done
  printf '%s\n' "${result[@]:-}"
}

# Determine most frequent city (mode) from array
compute_mode() {
  if (( $# == 0 )); then
    printf ''
    return
  fi
  printf '%s\n' "$@" \
    | sort \
    | uniq -c \
    | sort -rn \
    | head -n1 \
    | awk '{ $1=""; sub(/^ */, ""); print }'
}

#--- MAIN --------------------------------------------------------------------
main() {
  IP=$(detect_ip)
  APPLE_CODE=$(get_apple_code)
  [[ -n $APPLE_CODE ]] || error_exit "No valid Apple country_code; aborting"

  # 1) Try ipinfo (highest priority)
  if info=$(get_ipinfo) && [[ -n $info ]]; then
    # Extract code and city
    code=$(jq -r '.country_code' <<<"$info")
    if [[ $code == "$APPLE_CODE" ]]; then
      printf '%s\n' "$info"
      exit 0
    else
      log_warn "ipinfo country_code '$code' != Apple '$APPLE_CODE'"
    fi
  else
    log_warn "ipinfo lookup failed or missing data"
  fi

  # 2) Fallback services
  mapfile -t cities < <(gather_cities)
  consensus=$(compute_mode "${cities[@]}")
  [[ -n $consensus ]] || consensus=''

  printf '{"country_code":"%s","city":"%s"}\n' "$APPLE_CODE" "$consensus"
}

main "$@"
