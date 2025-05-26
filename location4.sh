(
  # subshell to avoid exiting your interactive shell on errors
  set -euo pipefail
  IFS=$'\n\t'
  trap 'echo "{\"country_code\":null,\"city\":null}"; exit 1' ERR

  TIMEOUT=3
  UA="Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"

  # 1) Detect external IPv4
  for src in https://api.ipify.org https://ipinfo.io/ip https://ifconfig.co/ip; do
    IP=$(timeout $TIMEOUT curl -4 -qs "$src") || continue
    [[ $IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && break
  done
  [[ $IP =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "{\"country_code\":null,\"city\":null}"; exit 0; }

  # 2) Get Apple PEP country_code
  RES=$(timeout $TIMEOUT curl -4 -qsL https://gspe1-ssl.ls.apple.com/pep/gcc)
  APPLE_CODE=""
  if [[ "$RES" != "null" && ${#RES} -le 7 ]]; then
    APPLE_CODE=$RES
  fi
  [[ -n $APPLE_CODE ]] || { echo "{\"country_code\":null,\"city\":null}"; exit 0; }

  # 3) Query free GeoIP services
  declare -a SERVICES=(
    "http://ip-api.com/json/%IP%?fields=countryCode,city"
    "https://get.geojs.io/v1/ip/geo/%IP%.json"
    "http://ipwhois.app/json/%IP%"
    "https://freeipapi.com/api/json/%IP%"
    "https://api.ip.sb/geoip/%IP%"
    "https://ipinfo.io/%IP%/json"
  )

  cities=()
  for tmpl in "${SERVICES[@]}"; do
    url=${tmpl//%IP%/$IP}
    out=$(timeout $TIMEOUT curl -4 -qs -A "$UA" "$url" || echo "")
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
    fi
  done

  # 4) Consensus: mode or random if all unique
  if (( ${#cities[@]} == 0 )); then
    city=""
  else
    declare -A count
    for c in "${cities[@]}"; do
      (( count["$c"]++ ))
    done
    max=0
    modes=()
    for c in "${!count[@]}"; do
      if (( count["$c"] > max )); then
        max=${count["$c"]}
        modes=("$c")
      elif (( count["$c"] == max )); then
        modes+=("$c")
      fi
    done
    if (( max > 1 )); then
      city=${modes[0]}
    else
      city=${modes[RANDOM % ${#modes[@]}]}
    fi
  fi

  # 5) Output final JSON
  printf '{"country_code":"%s","city":"%s"}\n' "$APPLE_CODE" "$city"
)
