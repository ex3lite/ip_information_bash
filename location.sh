# ————————————————————————————————————————————————————————————————
# Paste the entire block below into your Bash (WSL, Git Bash, Linux shell)
# ————————————————————————————————————————————————————————————————

{
  set -Eeuo pipefail
  trap 'echo "[ERROR] Unexpected error on line $LINENO" >&2; exit 1' ERR
  IFS=$'\n\t'

  # ————————————————————————————————————————————
  # Logging to stderr only
  log_info ()  { printf '\e[1;34m[INFO]\e[0m %s\n'  "$*" >&2; }
  log_warn ()  { printf '\e[1;33m[WARN]\e[0m %s\n'  "$*" >&2; }
  error_exit(){ printf '\e[1;31m[ERROR]\e[0m %s\n' "$*" >&2; exit 1; }

  # ————————————————————————————————————————————
  # Dependencies
  for cmd in curl jq timeout; do
    command -v "$cmd" >/dev/null 2>&1 || error_exit "Required '$cmd' not found"
  done

  TIMEOUT=3
  USER_AGENT='Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0'

  # ————————————————————————————————————————————
  # 1. Detect external IPv4
  detect_ip() {
    for src in https://api.ipify.org https://ipinfo.io/ip https://ifconfig.co/ip; do
      if ip=$(timeout "$TIMEOUT" curl -4 -qs "$src"); then
        if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
          echo "$ip"
          return
        fi
      fi
    done
    error_exit "Failed to detect external IP"
  }
  IP=$(detect_ip)
  log_info "External IP: $IP"

  # ————————————————————————————————————————————
  # 2. Get Apple PEP-GCC country code
  get_apple() {
    local res
    if ! res=$(timeout "$TIMEOUT" curl -4 -qsL https://gspe1-ssl.ls.apple.com/pep/gcc); then
      log_warn "Apple lookup failed or timed out"
      return
    fi
    [[ $res == "null" || ${#res} -gt 7 ]] && {
      log_warn "Apple returned invalid: '$res'"
      return
    }
    echo "$res"
  }
  APPLE_CODE=$(get_apple)
  [[ -n $APPLE_CODE ]] || error_exit "No valid country_code from Apple"
  log_info "Apple country_code: $APPLE_CODE"

  # ————————————————————————————————————————————
  # 3. Priority: ipinfo.io
  ipinfo_json=$(timeout "$TIMEOUT" curl -4 -qs -A "$USER_AGENT" "https://ipinfo.io/$IP/json" || echo "")
  IPINFO_CODE=$(jq -r '.country // empty' <<<"$ipinfo_json")
  IPINFO_CITY=$(jq -r '.city    // empty' <<<"$ipinfo_json")
  if [[ $IPINFO_CODE == "$APPLE_CODE" && -n $IPINFO_CITY ]]; then
    printf '{"country_code":"%s","city":"%s"}\n' "$IPINFO_CODE" "$IPINFO_CITY"
    exit 0
  else
    log_warn "ipinfo mismatch or no city (code='$IPINFO_CODE', city='$IPINFO_CITY')"
  fi

  # ————————————————————————————————————————————
  # 4. Fallback services
  declare -a SERVICES=(
    "http://ip-api.com/json/%IP%?fields=countryCode,city"
    "https://get.geojs.io/v1/ip/geo/%IP%.json"
    "http://ipwhois.app/json/%IP%"
    "https://freeipapi.com/api/json/%IP%"
    "https://api.ip.sb/geoip/%IP%"
  )

  cities=()
  for tmpl in "${SERVICES[@]}"; do
    url=${tmpl//%IP%/$IP}
    out=$(timeout "$TIMEOUT" curl -4 -qs -A "$USER_AGENT" "$url" 2>/dev/null || echo "")
    code=$(jq -r '
      .countryCode?       // 
      .country?           // 
      .country_code?      //
      .location.country_code? // empty
    ' <<<"$out")
    city=$(jq -r '
      .city? 
      // .location.city? 
      // empty
    ' <<<"$out")
    if [[ $code == "$APPLE_CODE" && -n $city ]]; then
      cities+=("$city")
      log_info "Matched '$code' → '$city' from $url"
    fi
  done

  # ————————————————————————————————————————————
  # 5. Compute mode (most frequent city)
  if (( ${#cities[@]} )); then
    consensus=$(printf '%s\n' "${cities[@]}" \
      | sort \
      | uniq -c \
      | sort -rn \
      | head -n1 \
      | sed -E 's/^[[:space:]]*[0-9]+ //')
  else
    consensus=""
  fi

  # ————————————————————————————————————————————
  # 6. Final JSON output
  printf '{"country_code":"%s","city":"%s"}\n' "$APPLE_CODE" "$consensus"
}
