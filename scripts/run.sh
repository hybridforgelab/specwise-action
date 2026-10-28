#!/usr/bin/env bash
# Specwise GitHub Action: report the breaking changes a pull request makes to its OpenAPI specs.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$HERE/lib.sh"

PRICING="https://rapidapi.com/hybrid-forge-lab-hybrid-forge-lab-default/api/specwise-openapi-validator-and-diff-api/pricing"
MARKER="<!-- specwise-action -->"
OUT="${GITHUB_OUTPUT:-/dev/null}"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
RESULTS="$WORK/results.jsonl"
: > "$RESULTS"

output() { printf '%s=%s\n' "$1" "$2" >> "$OUT"; }
record() { jq -cn "$@" >> "$RESULTS"; } # one JSON object per spec
flag() { # flag NAME VALUE → validates a true/false input
  case "$2" in true|false) ;; *) echo "::error::$1 must be true or false (got '$2')."; exit 1;; esac
}

# 1. Preflight
for tool in curl jq git; do
  command -v "$tool" >/dev/null || { echo "::error::Specwise needs $tool on the runner."; exit 1; }
done
FAIL_ON_BREAKING="${INPUT_FAIL_ON_BREAKING:-true}"; flag fail-on-breaking "$FAIL_ON_BREAKING"
VALIDATE="${INPUT_VALIDATE:-false}"; flag validate "$VALIDATE"
COMMENT="${INPUT_COMMENT:-true}"; flag comment "$COMMENT"
case "${INPUT_ON_QUOTA_EXCEEDED:-warn}" in warn|fail) ;; *)
  echo "::error::on-quota-exceeded must be warn or fail."; exit 1;; esac
MAX_REQ="${INPUT_MAX_REQUESTS:-10}"
[[ $MAX_REQ =~ ^[0-9]+$ ]] || { echo "::error::max-requests must be a whole number."; exit 1; }
ALLOW_LABEL="$(trim "${INPUT_ALLOW_LABEL:-}")"

if [[ -z ${INPUT_RAPIDAPI_KEY:-} && -z ${SPECWISE_AUTH_HEADER:-} ]]; then
  if [[ ${GITHUB_EVENT_NAME:-} == pull_request* ]]; then
    echo "::warning::Specwise skipped: no rapidapi-key. Pull requests from forks don't get repository secrets."
    output passed true; output requests-used 0
    exit 0
  fi
  echo "::error::rapidapi-key is empty. Subscribe to the Specwise API (free Basic plan) at $PRICING and store the key as a secret."
  exit 1
fi
[[ -n ${INPUT_RAPIDAPI_KEY:-} ]] && echo "::add-mask::$INPUT_RAPIDAPI_KEY"

PR=""
if [[ ${GITHUB_EVENT_NAME:-} == pull_request* && -f ${GITHUB_EVENT_PATH:-} ]]; then
  PR="$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")"
fi

# 2. What to compare against
BASE_REF="$(base_sha)"
BASE_COMMIT=""
if [[ -n $BASE_REF ]]; then
  BASE_COMMIT="$(resolve_base "$BASE_REF")"
else
  echo "::notice::No base to compare against for this event (set base-ref): specs can only be validated."
fi

# 3. One diff request per changed spec (plus one validate request with validate: true)
requests=0 quota="" stop=""
api() { # api ENDPOINT BODY_FILE → sets $code and leaves the response in $WORK/resp.json; retries once on 000/5xx
  code="$(call_api "$1" "$2" "$WORK/resp.json" "$WORK/headers.txt")"; requests=$((requests + 1))
  if [[ $code == 000 || $code =~ ^5 ]]; then
    sleep "${SPECWISE_RETRY_DELAY:-5}"
    code="$(call_api "$1" "$2" "$WORK/resp.json" "$WORK/headers.txt")"; requests=$((requests + 1))
  fi
  local q; q="$(header_value "$WORK/headers.txt" x-ratelimit-requests-remaining)"; [[ -n $q ]] && quota="$q"
  return 0
}
not_analysed() { # not_analysed FILE REASON
  record --arg file "$1" --arg reason "$2" '{file: $file, status: "not_analysed", reason: $reason}'
}
# handle_error FILE ENDPOINT: everything but 200. Returns 0 when the file should still count as processed.
handle_error() {
  local f="$1" detail line
  case "$code" in
    401|403)
      detail="$(jq -r '.message // empty' "$WORK/resp.json" 2>/dev/null || true)"
      echo "::error::Specwise refused the key (HTTP $code${detail:+: $detail}). Subscribe (free Basic plan) at $PRICING."
      not_analysed "$f" "key refused (HTTP $code)"; stop="key refused" ;;
    413)
      echo "::warning file=$f::Specwise skipped this spec: request too large."
      record --arg file "$f" --arg reason "request too large (HTTP 413)" '{file: $file, status: "skipped", reason: $reason}' ;;
    422)
      detail="$(jq -r '.detail | if type == "string" then . else tostring end' "$WORK/resp.json" 2>/dev/null || echo "invalid input")"
      if [[ $detail == base\ * ]]; then
        # the old version is broken: not this change's fault, and nothing to compare with
        echo "::warning file=$f::Specwise couldn't read the base version of this spec: $detail"
        record --arg file "$f" --arg reason "base version unreadable: $detail" '{file: $file, status: "skipped", reason: $reason}'
      else
        line="$(grep -oE 'line [0-9]+' <<<"$detail" | head -1 | grep -oE '[0-9]+' || true)"
        echo "::error file=$f${line:+,line=$line},title=Specwise could not parse this spec::$detail"
        record --arg file "$f" --arg detail "$detail" '{file: $file, status: "invalid", reason: $detail}'
      fi ;;
    429)
      if [[ ${INPUT_ON_QUOTA_EXCEEDED:-warn} == fail ]]; then
        echo "::error::Specwise monthly quota exhausted. Upgrade at $PRICING."
        record --arg file "$f" '{file: $file, status: "failed", reason: "quota exhausted (HTTP 429)"}'
      else
        echo "::warning::Specwise monthly quota exhausted: the remaining specs were not checked. Upgrade at $PRICING."
        not_analysed "$f" "quota exhausted (HTTP 429)"
      fi
      stop="quota exhausted" ;;
    *)
      echo "::warning::Specwise API unavailable (HTTP $code): the remaining specs were not checked. Your build is not failed because of it."
      not_analysed "$f" "API unavailable (HTTP $code)"; stop="API unavailable" ;;
  esac
}

while IFS= read -r f; do
  [[ -z $f ]] && continue
  [[ -f $f ]] || continue
  base="$WORK/base"; rm -f "$base"
  if [[ -n $BASE_REF ]]; then
    set +e; base_file "$BASE_COMMIT" "$BASE_REF" "$f" "$base"; rc=$?; set -e
  else
    rc=1
  fi
  if [[ $rc -eq 2 ]]; then
    echo "::warning file=$f::Couldn't read the base version of this spec."
    record --arg file "$f" '{file: $file, status: "skipped", reason: "base version unreadable"}'; continue
  fi
  if [[ $rc -eq 0 ]] && cmp -s "$base" "$f"; then
    record --arg file "$f" '{file: $file, status: "unchanged"}'; continue
  fi
  # only a spec this change touched is worth a reason in the report
  reason="$(skip_reason "$f")"
  if [[ -n $reason ]]; then
    record --arg file "$f" --arg reason "$reason" '{file: $file, status: "skipped", reason: $reason}'; continue
  fi
  if [[ $rc -eq 0 && $(spec_kind "$base") != openapi3 ]]; then
    record --arg file "$f" '{file: $file, status: "skipped", reason: "the base version is not OpenAPI 3.x"}'; continue
  fi
  if [[ $rc -eq 1 && $VALIDATE != true ]]; then
    record --arg file "$f" '{file: $file, status: "new"}'; continue
  fi
  if [[ -n $stop ]]; then not_analysed "$f" "$stop"; continue; fi
  need=1; [[ $rc -eq 0 && $VALIDATE == true ]] && need=2
  if (( requests + need > MAX_REQ )); then not_analysed "$f" "max-requests ($MAX_REQ) reached"; continue; fi

  # results go through files: one argument over 128 KiB fails on Linux
  echo null > "$WORK/diff.json"; echo null > "$WORK/validate.json"; status="new" line_file="$WORK/lines.json"
  line_map "$f" > "$line_file"
  if [[ $rc -eq 0 ]]; then
    jq -n --rawfile b "$base" --rawfile r "$f" '{base: $b, revision: $r}' > "$WORK/body.json"
    api openapi/diff "$WORK/body.json"
    if [[ $code != 200 ]]; then handle_error "$f"; continue; fi
    jq -c --slurpfile m "$line_file" -f "$HERE/lines.jq" "$WORK/resp.json" > "$WORK/diff.json"
    status="compared"
  fi
  if [[ $VALIDATE == true ]]; then
    jq -n --rawfile r "$f" '{spec: $r}' > "$WORK/body.json"
    api openapi/validate "$WORK/body.json"
    if [[ $code == 200 ]]; then
      jq -c '{valid, error_count, errors, warning_count, warnings, truncated}' "$WORK/resp.json" > "$WORK/validate.json"
    elif [[ $status == new ]]; then
      handle_error "$f"; continue
    else
      echo "::warning file=$f::Specwise couldn't validate this spec (HTTP $code); the diff is still reported."
    fi
  fi
  record --arg file "$f" --arg status "$status" --slurpfile d "$WORK/diff.json" --slurpfile v "$WORK/validate.json" \
    '{file: $file, status: $status, diff: $d[0], validate: $v[0]}'
done < <(discover)
if [[ ! -s $RESULTS ]]; then
  echo "::notice::No tracked file matches spec-paths ($INPUT_SPEC_PATHS)."
fi

# 4. A label can accept the breaking changes
allowed=false
has_breaking="$(jq -s 'any(.[]; .diff.breaking == true)' "$RESULTS")"
if [[ $has_breaking == true && -n $ALLOW_LABEL && -n $PR ]]; then
  if [[ $(gh_api GET "repos/${GITHUB_REPOSITORY:-}/issues/$PR/labels?per_page=100" "$WORK/labels.json") == 200 ]]; then
    labels="$(jq -c '[.[].name]' "$WORK/labels.json")"
  else
    labels="$(jq -c '[.pull_request.labels[]?.name]' "$GITHUB_EVENT_PATH")" # as of the event
  fi
  [[ $(jq --arg l "$ALLOW_LABEL" 'index($l) != null' <<<"$labels") == true ]] && allowed=true
fi

# 5. Pass or fail
passed="$(jq -s --argjson fob "$FAIL_ON_BREAKING" --argjson allowed "$allowed" '
  all(.[];
    (.status != "invalid") and (.status != "failed")
    and ((.diff.breaking == true and $fob and ($allowed | not)) | not)
    and (.validate.valid != false))' "$RESULTS")"
[[ $stop == "key refused" ]] && passed=false

# 6. Annotations
level="error"; [[ $FAIL_ON_BREAKING != true || $allowed == true ]] && level="warning"
jq -s -r --arg breaking_level "$level" -f "$HERE/annotate.jq" "$RESULTS"

# 7. Report: job summary, and a pull request comment that is updated on every run
if [[ -n $quota && $quota =~ ^[0-9]+$ ]] && (( quota < 3 )); then
  echo "::warning::Only $quota Specwise requests left this month. Plans: $PRICING"
fi
head_sha="${GITHUB_SHA:-}"
[[ -n $PR ]] && head_sha="$(jq -r '.pull_request.head.sha // empty' "$GITHUB_EVENT_PATH")"
jq -s --argjson passed "$passed" --argjson allowed "$allowed" --arg allow_label "$ALLOW_LABEL" \
  --argjson fail_on_breaking "$FAIL_ON_BREAKING" --arg requests "$requests" --arg quota "$quota" \
  --arg blob "${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/blob/$head_sha" --arg pr "$PR" \
  '{results: ., passed: $passed, allowed: $allowed, allow_label: $allow_label, fail_on_breaking: $fail_on_breaking,
    requests: $requests, quota: $quota, blob: $blob, pr: $pr}' "$RESULTS" > "$WORK/report-input.json"
jq -r -f "$HERE/report.jq" "$WORK/report-input.json" > "$WORK/report.md"
cat "$WORK/report.md" >> "$SUMMARY"

comment_url=""
if [[ $COMMENT == true && -n $PR ]]; then
  existing=""
  for page in 1 2 3 4 5 6 7 8 9 10; do
    [[ $(gh_api GET "repos/${GITHUB_REPOSITORY:-}/issues/$PR/comments?per_page=100&page=$page" "$WORK/comments.json") == 200 ]] || break
    existing="$(jq -r --arg m "$MARKER" 'map(select(.body | contains($m))) | first | .id // empty' "$WORK/comments.json")"
    [[ -n $existing || $(jq 'length' "$WORK/comments.json") -lt 100 ]] && break
  done
  worth="$(jq -s 'any(.[]; .status == "compared" or .status == "new" or .status == "invalid" or .status == "failed"
    or .status == "not_analysed")' "$RESULTS")"
  if [[ -n $existing || $worth == true ]]; then
    { printf '%s\n' "$MARKER"; cat "$WORK/report.md"; } | jq -Rs '{body: .}' > "$WORK/comment.json"
    if [[ -n $existing ]]; then
      code="$(gh_api PATCH "repos/${GITHUB_REPOSITORY:-}/issues/comments/$existing" "$WORK/comment-resp.json" "$WORK/comment.json")"
    else
      code="$(gh_api POST "repos/${GITHUB_REPOSITORY:-}/issues/$PR/comments" "$WORK/comment-resp.json" "$WORK/comment.json")"
    fi
    if [[ $code =~ ^2 ]]; then
      comment_url="$(jq -r '.html_url // empty' "$WORK/comment-resp.json")"
    else
      echo "::notice::Couldn't comment on the pull request (HTTP $code): give the job \`pull-requests: write\`. The report is in the job summary."
    fi
  fi
fi

# 8. Outputs and exit code
stats="$(jq -s '[.[] | select(.diff)] | {
  breaking: (map(.diff.summary.breaking) | add // 0),
  total: (map(.diff.summary.total) | add // 0),
  semver: ((map(.diff.semver) | map({none: 0, patch: 1, minor: 2, major: 3}[.]) | max // 0) as $m
           | ["none", "patch", "minor", "major"][$m]),
  compared: length}' "$RESULTS")"
output passed "$passed"
output breaking "$has_breaking"
output breaking-changes "$(jq -r '.breaking' <<<"$stats")"
output changes "$(jq -r '.total' <<<"$stats")"
output semver "$(jq -r '.semver' <<<"$stats")"
output specs-compared "$(jq -r '.compared' <<<"$stats")"
output requests-used "$requests"
output quota-remaining "$quota"
output comment-url "$comment_url"
echo "Specwise: $(jq -r '.compared' <<<"$stats") spec(s) compared, $requests request(s), breaking=$has_breaking, passed=$passed${quota:+, $quota left this month}"
if [[ $passed != true ]]; then
  # say why, instead of leaving only GitHub's generic "Process completed with exit code 1"
  why=()
  n="$(jq -s '[.[] | select(.diff.breaking == true)] | length' "$RESULTS")"
  if (( n > 0 )) && [[ $FAIL_ON_BREAKING == true && $allowed != true ]]; then
    why+=("$n spec(s) with breaking changes${ALLOW_LABEL:+ (add the label '$ALLOW_LABEL' to accept them)}")
  fi
  n="$(jq -s '[.[] | select(.validate.valid == false)] | length' "$RESULTS")"
  (( n > 0 )) && why+=("$n spec(s) invalid")
  n="$(jq -s '[.[] | select(.status == "invalid")] | length' "$RESULTS")"
  (( n > 0 )) && why+=("$n spec(s) could not be parsed")
  if (( ${#why[@]} > 0 )); then
    msg="$(IFS=';'; echo "${why[*]}")"
    echo "::error title=Specwise check failed::${msg//;/; }. The report lists every change."
  fi
fi
[[ $passed == true ]]
