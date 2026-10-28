#!/usr/bin/env bash
# Functions used by run.sh; sourced by the bats tests too.

SPECWISE_HOST="specwise-openapi-validator-and-diff-api.p.rapidapi.com"
MAX_BYTES=921600 # both versions go in one request, and the API takes at most 2 MB per request
ZERO_SHA="0000000000000000000000000000000000000000"

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

# glob_match PATH PATTERN: shell-style pattern; a leading "**/" also matches at the repository root.
glob_match() {
  local path="$1" pattern="$2"
  # Explicit ifs: bash 3.2 (macOS runners) with `set -e` exits on a failed `[[ ]] && return` at the end of a block.
  # shellcheck disable=SC2053 # the right-hand side is a pattern on purpose
  if [[ $path == $pattern ]]; then return 0; fi
  if [[ $pattern == '**/'* ]]; then
    # shellcheck disable=SC2053
    if [[ $path == ${pattern#'**/'} ]]; then return 0; fi
  fi
  # "/**/" also matches no folder at all: docs/**/openapi.yaml matches docs/openapi.yaml
  if [[ $pattern == *'/**/'* ]]; then
    local slash=/ zero
    zero="${pattern//\/\*\*\//$slash}" # a variable: escaping "/" in the replacement differs between bash versions
    # shellcheck disable=SC2053
    if [[ $path == $zero ]]; then return 0; fi
  fi
  return 1
}

# matches_any PATH "glob1,glob2,…"
matches_any() {
  local path="$1" list="$2" p pats=()
  # read, not `for p in $list`: an unquoted list would also be expanded against the files on disk
  IFS=',' read -r -a pats <<<"$list"
  for p in ${pats[@]+"${pats[@]}"}; do
    p="$(trim "$p")"
    if [[ -n $p ]] && glob_match "$path" "$p"; then return 0; fi
  done
  return 1
}

# discover: the tracked files matching spec-paths and not exclude-paths, one per line
discover() {
  local f
  while IFS= read -r f; do
    [[ -z $f ]] && continue
    if matches_any "$f" "${INPUT_EXCLUDE_PATHS:-}"; then continue; fi
    if matches_any "$f" "${INPUT_SPEC_PATHS:-}"; then printf '%s\n' "$f"; fi
  done < <(git ls-files 2>/dev/null)
}

# spec_kind FILE → openapi3, swagger2 or other (a YAML or JSON document, pretty-printed or not)
spec_kind() {
  local q="[\"']?"
  if grep -qE "${q}openapi${q}[[:space:]]*:[[:space:]]*${q}3\\." "$1" 2>/dev/null; then echo openapi3
  elif grep -qE "${q}swagger${q}[[:space:]]*:[[:space:]]*${q}2\\." "$1" 2>/dev/null; then echo swagger2
  else echo other; fi
}

# skip_reason FILE → empty when the file can be compared, else why not (no request spent)
skip_reason() {
  local file="$1"
  if [[ ! -f $file ]]; then echo "not found"; return 0; fi
  if (( $(wc -c < "$file") > MAX_BYTES )); then echo "larger than 900 KiB"; return 0; fi
  case "$(spec_kind "$file")" in
    swagger2) echo "Swagger 2.0: the diff needs OpenAPI 3.x" ;;
    other) echo "not an OpenAPI document" ;;
  esac
  return 0
}

# gh_api METHOD PATH OUT [JSON_FILE] → prints the HTTP status ("000" when the request itself failed)
gh_api() {
  local method="$1" path="$2" out="$3" data="${4:-}" code args=()
  [[ -n $data ]] && args=(-H "Content-Type: application/json" --data-binary "@$data")
  code="$(curl -sS --max-time 30 -o "$out" -w '%{http_code}' -X "$method" \
    -H "Authorization: Bearer ${INPUT_GITHUB_TOKEN:-}" -H "Accept: application/vnd.github+json" \
    ${args[@]+"${args[@]}"} "${GITHUB_API_URL:-https://api.github.com}/$path" 2>/dev/null)" || code="000"
  printf '%s' "${code:-000}"
}

# base_sha → the commit to compare against: the base-ref input, else the pull request base, else the push's
# previous commit. Empty when there is none (a new branch, or an event without a diff).
base_sha() {
  local ev="${GITHUB_EVENT_PATH:-}" sha=""
  if [[ -n ${INPUT_BASE_REF:-} ]]; then printf '%s' "$INPUT_BASE_REF"; return 0; fi
  [[ -f $ev ]] || return 0
  case "${GITHUB_EVENT_NAME:-}" in
    pull_request*) sha="$(jq -r '.pull_request.base.sha // empty' "$ev")" ;;
    push|merge_group) sha="$(jq -r '.before // .merge_group.base_sha // empty' "$ev")" ;;
  esac
  [[ $sha == "$ZERO_SHA" ]] && sha=""
  printf '%s' "$sha"
}

# resolve_base REF → the local commit for REF, fetching it (depth 1) when the checkout doesn't have it.
# Empty when it can't be fetched (base_file then falls back to the GitHub API).
resolve_base() {
  local ref="$1"
  if git rev-parse -q --verify "$ref^{commit}" 2>/dev/null; then return 0; fi
  if git fetch -q --no-tags --depth=1 origin "$ref" 2>/dev/null; then
    git rev-parse -q --verify "FETCH_HEAD^{commit}" 2>/dev/null || true
  fi
  return 0
}

# base_file COMMIT REF PATH OUT → 0 found, 1 not in the base (a new spec), 2 couldn't be read
base_file() {
  local commit="$1" ref="$2" path="$3" out="$4" code enc
  if [[ -n $commit ]]; then
    if git cat-file -e "$commit:$path" 2>/dev/null; then git show "$commit:$path" > "$out" && return 0; return 2; fi
    return 1
  fi
  enc="$(jq -rn --arg p "$path" '$p | split("/") | map(@uri) | join("/")')"
  code="$(gh_api GET "repos/${GITHUB_REPOSITORY:-}/contents/$enc?ref=$(jq -rn --arg r "$ref" '$r | @uri')" "$out.json")"
  case "$code" in
    200) jq -er '.content' "$out.json" 2>/dev/null | base64 -d > "$out" 2>/dev/null && return 0; return 2 ;;
    404) return 1 ;;
    *) return 2 ;;
  esac
}

# call_api ENDPOINT BODY_FILE OUT HEADERS → prints the HTTP status ("000" when the request itself failed)
call_api() {
  local endpoint="$1" body="$2" out="$3" headers="$4" code
  local url="${SPECWISE_API_URL:-https://$SPECWISE_HOST}/v1/$endpoint"
  local auth=(-H "X-RapidAPI-Key: ${INPUT_RAPIDAPI_KEY:-}" -H "X-RapidAPI-Host: $SPECWISE_HOST")
  # SPECWISE_API_URL / SPECWISE_AUTH_HEADER let the tests and maintainers call the API directly
  [[ -n ${SPECWISE_AUTH_HEADER:-} ]] && auth=(-H "$SPECWISE_AUTH_HEADER")
  code="$(curl -sS --max-time 60 -o "$out" -D "$headers" -w '%{http_code}' \
    -X POST "$url" "${auth[@]}" -H "Content-Type: application/json" --data-binary "@$body" 2>/dev/null)" || code="000"
  printf '%s' "${code:-000}"
}

# header_value HEADERS_FILE NAME (case-insensitive) → value or empty
header_value() { awk -v n="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" -F': *' \
  'tolower($1) == n { sub(/\r$/, "", $2); v = $2 } END { if (v != "") print v }' "$1" 2>/dev/null; }

# line_map FILE → JSON object {"<path segments joined by NUL>": line} for every node, from yq (mikefarah).
# "{}" when yq isn't installed: annotations then point at the file without a line.
line_map() {
  if ! yq --version 2>/dev/null | grep -q mikefarah; then echo '{}'; return 0; fi
  # the line of the key ("get:") when there is one, else of the value (array items)
  yq -p yaml -o json -I0 '[.. | {"p": path, "k": (key | line), "l": line}]' "$1" 2>/dev/null \
    | jq -c 'map({key: (.p // [] | map(tostring) | join("\u0000")), value: (if .k > 0 then .k else .l end)} | select(.value > 0))
             | from_entries' 2>/dev/null || echo '{}'
}
