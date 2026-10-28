#!/usr/bin/env bats
# Unit tests: run.sh in a real git repository, against a fake curl that answers with real recorded API responses.

ROOT="$BATS_TEST_DIRNAME/.."
FIX="$ROOT/tests/fixtures"

commit() { git -C "$REPO" add -A && git -C "$REPO" -c user.email=t@t -c user.name=t commit -qm "$1" && git -C "$REPO" rev-parse HEAD; }

setup() {
  export MOCK_DIR="$BATS_TEST_TMPDIR/mock" REPO="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$MOCK_DIR" "$REPO"
  cp -R "$FIX/repo/." "$REPO/"
  mkdir -p "$REPO/api" # git keeps no empty folders
  git -C "$REPO" init -q
  cp "$FIX/base.yaml" "$REPO/api/openapi.yaml"
  BASE="$(commit base)"
  cp "$FIX/revision.yaml" "$REPO/api/openapi.yaml"
  HEAD="$(commit head)"
  cp "$ROOT/tests/responses/diff_200.json" "$MOCK_DIR/body_200_diff"
  cp "$ROOT/tests/responses/validate_200.json" "$MOCK_DIR/body_200_validate"
  cp "$ROOT/tests/responses/diff_422.json" "$MOCK_DIR/body_422_diff"
  cp "$ROOT/tests/responses/rapidapi_401.json" "$MOCK_DIR/body_401"
  cp "$ROOT/tests/responses/rapidapi_403.json" "$MOCK_DIR/body_403"
  cp "$ROOT/tests/responses/rapidapi_429.json" "$MOCK_DIR/body_429"
  echo '{"message":"Internal Server Error"}' > "$MOCK_DIR/body_503"
  echo '{"detail":"request body larger than 2 MB"}' > "$MOCK_DIR/body_413"
  echo 200 > "$MOCK_DIR/status_diff"
  echo 200 > "$MOCK_DIR/status_validate"
  echo '[]' > "$MOCK_DIR/gh_labels.json"
  export PATH="$ROOT/tests/bin:$PATH"
  export INPUT_RAPIDAPI_KEY=test-key INPUT_BASE_REF="" INPUT_FAIL_ON_BREAKING=true INPUT_ALLOW_LABEL=breaking-ok
  export INPUT_VALIDATE=false INPUT_COMMENT=true INPUT_MAX_REQUESTS=10 INPUT_ON_QUOTA_EXCEEDED=warn
  export INPUT_GITHUB_TOKEN=gh-token
  export INPUT_SPEC_PATHS="**/openapi.yaml,**/openapi.yml,**/openapi.json,**/*.openapi.yaml,**/*.openapi.yml,**/*.openapi.json"
  export INPUT_EXCLUDE_PATHS="**/node_modules/**"
  export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/output" GITHUB_STEP_SUMMARY="$BATS_TEST_TMPDIR/summary.md"
  export GITHUB_REPOSITORY=acme/app GITHUB_API_URL=https://api.github.com GITHUB_SERVER_URL=https://github.com
  export GITHUB_SHA="$HEAD" GITHUB_EVENT_PATH="$BATS_TEST_TMPDIR/event.json"
  export SPECWISE_RETRY_DELAY=0
  unset SPECWISE_API_URL SPECWISE_AUTH_HEADER
  pr_event
  : > "$GITHUB_OUTPUT"; : > "$GITHUB_STEP_SUMMARY"
}

pr_event() { # pr_event [LABEL…]
  export GITHUB_EVENT_NAME=pull_request
  jq -n --arg base "$BASE" --arg head "$HEAD" --args \
    '{pull_request: {number: 7, base: {sha: $base}, head: {sha: $head}, labels: ($ARGS.positional | map({name: .}))}}' \
    "$@" > "$GITHUB_EVENT_PATH"
}

two_specs() { # both specs changed by the pull request
  cp "$FIX/base.yaml" "$REPO/api/openapi.yaml"; cp "$FIX/base.yaml" "$REPO/api/orders.openapi.yaml"; BASE="$(commit base2)"
  cp "$FIX/revision.yaml" "$REPO/api/openapi.yaml"; cp "$FIX/revision.yaml" "$REPO/api/orders.openapi.yaml"; HEAD="$(commit head2)"
  pr_event
}

run_action() { cd "$REPO" && run "$ROOT/scripts/run.sh"; }
out() { grep "^$1=" "$GITHUB_OUTPUT" | tail -1 | cut -d= -f2-; }
requests() { grep -c . "$MOCK_DIR/requests.log" 2>/dev/null || echo 0; }
comment_body() { jq -r '.body' "$MOCK_DIR/gh_$1.json"; }

# ---------- helpers ----------

@test "discovery: spec-paths and exclude-paths, at the root too, unquoted lists never glob the disk" {
  source "$ROOT/scripts/lib.sh"
  cd "$REPO"
  cp "$FIX/base.yaml" openapi.yaml
  mkdir -p node_modules/x && cp "$FIX/base.yaml" node_modules/x/openapi.yaml
  cp "$FIX/base.yaml" api/orders.openapi.yaml
  git add -A
  run discover
  [ "$status" -eq 0 ]
  [[ $output == *"api/openapi.yaml"* ]]
  [[ $output == *"api/orders.openapi.yaml"* ]]
  [[ $output == *"legacy/openapi.yaml"* ]]
  [[ $(grep -cx "openapi.yaml" <<<"$output") -eq 1 ]]
  [[ $output != *node_modules* ]]
  [[ $output != *README* ]]
}

@test "globs: /**/ also matches no folder at all" {
  source "$ROOT/scripts/lib.sh"
  glob_match demo/openapi.yaml 'demo/**/openapi.yaml'
  glob_match demo/v1/openapi.yaml 'demo/**/openapi.yaml'
  glob_match a/b/c/openapi.yaml 'a/**/openapi.yaml'
  glob_match openapi.yaml '**/openapi.yaml'
  ! glob_match other/openapi.yaml 'demo/**/openapi.yaml'
  ! glob_match demo/openapi.json 'demo/**/openapi.yaml'
}

@test "no file matches spec-paths: a notice instead of a silent pass" {
  INPUT_SPEC_PATHS="nowhere/**/openapi.yaml" run_action
  [ "$status" -eq 0 ]
  [[ $output == *"::notice::No tracked file matches spec-paths (nowhere/**/openapi.yaml)."* ]]
}

@test "spec kind: OpenAPI 3 in YAML, pretty and minified JSON; Swagger 2.0; anything else" {
  source "$ROOT/scripts/lib.sh"
  cd "$BATS_TEST_TMPDIR"
  [ "$(spec_kind "$FIX/base.yaml")" = openapi3 ]
  printf '{"openapi":"3.1.0","info":{"title":"x","version":"1"},"paths":{}}' > min.json
  [ "$(spec_kind min.json)" = openapi3 ]
  printf "openapi: '3.0.0'\n" > quoted.yaml
  [ "$(spec_kind quoted.yaml)" = openapi3 ]
  [ "$(spec_kind "$REPO/legacy/openapi.yaml")" = swagger2 ]
  [ "$(spec_kind "$REPO/docs/openapi.yaml")" = other ]
  [ "$(skip_reason "$REPO/legacy/openapi.yaml")" = "Swagger 2.0: the diff needs OpenAPI 3.x" ]
  [ "$(skip_reason "$REPO/docs/openapi.yaml")" = "not an OpenAPI document" ]
  { echo "openapi: 3.0.3"; head -c 1000000 /dev/zero | tr '\0' 'a'; } > big.yaml
  [ "$(skip_reason big.yaml)" = "larger than 900 KiB" ]
  [ "$(skip_reason missing.yaml)" = "not found" ]
}

@test "line map: JSON Pointers to lines in YAML and JSON, nearest parent for removals and \$refs" {
  source "$ROOT/scripts/lib.sh"
  line_map "$FIX/revision.yaml" > "$BATS_TEST_TMPDIR/lines.json"
  run jq -c --slurpfile m "$BATS_TEST_TMPDIR/lines.json" -f "$ROOT/scripts/lines.jq" "$ROOT/tests/responses/diff_200.json"
  [ "$(jq -c '[.changes[].line]' <<<"$output")" = "[5,12,35,15,27,4]" ]
  yq -o json "$FIX/revision.yaml" > "$BATS_TEST_TMPDIR/revision.json"
  line_map "$BATS_TEST_TMPDIR/revision.json" > "$BATS_TEST_TMPDIR/lines.json"
  run jq -c --slurpfile m "$BATS_TEST_TMPDIR/lines.json" -f "$ROOT/scripts/lines.jq" "$ROOT/tests/responses/diff_200.json"
  [ "$(jq -c '.changes[1].line' <<<"$output")" = 15 ]
}

@test "line map: without yq, no lines (annotations still point at the file)" {
  mkdir -p "$BATS_TEST_TMPDIR/bin" && printf '#!/bin/sh\necho "yq 3.4.3"\n' > "$BATS_TEST_TMPDIR/bin/yq"
  chmod +x "$BATS_TEST_TMPDIR/bin/yq"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  run_action
  [ "$status" -eq 1 ]
  [[ $output == *"::error file=api/openapi.yaml,title=Breaking change%3A path.removed::"* ]]
}

# ---------- a pull request with breaking changes ----------

@test "compares the spec with the base, annotates the lines, comments, fails" {
  echo 13 > "$MOCK_DIR/quota"
  run_action
  [ "$status" -eq 1 ]
  [ "$(requests)" -eq 1 ]
  # one request with both versions, as strings (so the API can parse YAML)
  [ "$(jq -r '.base' "$MOCK_DIR/requests.log")" = "$(cat "$FIX/base.yaml")" ]
  [ "$(jq -r '.revision' "$MOCK_DIR/requests.log")" = "$(cat "$FIX/revision.yaml")" ]
  [[ $output == *"::error file=api/openapi.yaml,line=5,title=Breaking change%3A path.removed::path /pets/{id} removed (GET)"* ]]
  [[ $output == *"::error file=api/openapi.yaml,line=12,title=Breaking change%3A parameter.became_required::"* ]]
  [[ $output != *"non-breaking"* ]]
  [[ $output == *"::error title=Specwise check failed::1 spec(s) with breaking changes (add the label 'breaking-ok' to accept them). The report lists every change."* ]]
  [ "$(out passed)" = false ]
  [ "$(out breaking)" = true ]
  [ "$(out breaking-changes)" = 3 ]
  [ "$(out changes)" = 6 ]
  [ "$(out semver)" = major ]
  [ "$(out specs-compared)" = 1 ]
  [ "$(out requests-used)" = 1 ]
  [ "$(out quota-remaining)" = 13 ]
  [ "$(out comment-url)" = "https://github.com/acme/app/pull/7#issuecomment-99" ]
  grep -q "POST repos/acme/app/issues/7/comments" "$MOCK_DIR/github.log"
  body="$(comment_body post)"
  [[ $body == "<!-- specwise-action -->"* ]]
  [[ $body == *"**3 breaking changes** · 6 changes in total · version \`1.2.0\` → \`1.3.0\` · suggested bump: **major**"* ]]
  [[ $body == *"[line 12](https://github.com/acme/app/blob/$HEAD/api/openapi.yaml#L12)"* ]]
  [[ $body == *"add the label \`breaking-ok\`"* ]]
  [[ $body != *"legacy/openapi.yaml"* ]] # unchanged: not worth a line
  grep -q "## Specwise ❌" "$GITHUB_STEP_SUMMARY"
}

@test "the allow label accepts the breaking changes: passes, annotations become warnings" {
  echo '[{"name":"breaking-ok"}]' > "$MOCK_DIR/gh_labels.json"
  run_action
  [ "$status" -eq 0 ]
  [[ $output == *"::warning file=api/openapi.yaml,line=5,title=Breaking change%3A path.removed::"* ]]
  [[ $output != *"::error"* ]]
  [ "$(out passed)" = true ]
  [ "$(out breaking)" = true ]
  [[ $(comment_body post) == *"The label \`breaking-ok\` accepts these breaking changes."* ]]
}

@test "labels: falls back to the event payload when the API can't be read" {
  echo 403 > "$MOCK_DIR/gh_labels_status"
  pr_event breaking-ok
  run_action
  [ "$status" -eq 0 ]
  [ "$(out passed)" = true ]
}

@test "another label doesn't accept anything" {
  echo '[{"name":"docs"}]' > "$MOCK_DIR/gh_labels.json"
  run_action
  [ "$status" -eq 1 ]
}

@test "fail-on-breaking false: reports, warns, passes" {
  INPUT_FAIL_ON_BREAKING=false run_action
  [ "$status" -eq 0 ]
  [[ $output == *"::warning file=api/openapi.yaml,line=5,"* ]]
  [ "$(out passed)" = true ]
  [[ $(comment_body post) == *"Breaking changes don't fail this check"* ]]
}

@test "changes without breaking ones pass" {
  cp "$ROOT/tests/responses/diff_200_none.json" "$MOCK_DIR/body_200_diff"
  run_action
  [ "$status" -eq 0 ]
  [ "$(out breaking)" = false ]
  [ "$(out semver)" = none ]
  [[ $(comment_body post) == *"No changes to the API"* ]]
}

# ---------- what costs nothing ----------

@test "an unchanged spec: no request, no comment" {
  cp "$FIX/base.yaml" "$REPO/api/openapi.yaml"; HEAD="$(commit revert)"; pr_event
  run_action
  [ "$status" -eq 0 ]
  [ "$(requests)" -eq 0 ]
  [ ! -f "$MOCK_DIR/gh_post.json" ]
  [ "$(out passed)" = true ]
  [ "$(out specs-compared)" = 0 ]
  grep -q "No OpenAPI spec changed in this pull request." "$GITHUB_STEP_SUMMARY"
}

@test "an earlier comment is updated, even when nothing changed any more" {
  jq -n '[{id: 5, body: "hello"}, {id: 41, body: "<!-- specwise-action -->\nold"}]' > "$MOCK_DIR/gh_comments.json"
  cp "$FIX/base.yaml" "$REPO/api/openapi.yaml"; HEAD="$(commit revert)"; pr_event
  run_action
  [ "$status" -eq 0 ]
  grep -q "PATCH repos/acme/app/issues/comments/41" "$MOCK_DIR/github.log"
  [ ! -f "$MOCK_DIR/gh_post.json" ]
  [[ $(comment_body patch) == *"No OpenAPI spec changed in this pull request."* ]]
}

@test "no permission to comment: a notice, and the result still stands" {
  echo 403 > "$MOCK_DIR/gh_comment_status"
  run_action
  [ "$status" -eq 1 ]
  [[ $output == *"::notice::Couldn't comment on the pull request (HTTP 403): give the job \`pull-requests: write\`."* ]]
  [ "$(out comment-url)" = "" ]
}

@test "comment: false never calls the comments API" {
  INPUT_COMMENT=false run_action
  [ "$status" -eq 1 ]
  ! grep -q comments "$MOCK_DIR/github.log"
}

@test "a changed Swagger 2.0 spec is listed as not checked, at no cost" {
  printf '\n' >> "$REPO/legacy/openapi.yaml"; HEAD="$(commit legacy)"; pr_event
  run_action
  [ "$(requests)" -eq 1 ]
  [[ $(comment_body post) == *"| \`legacy/openapi.yaml\` | Swagger 2.0: the diff needs OpenAPI 3.x |"* ]]
}

@test "a new spec: nothing to compare, no request" {
  cp "$FIX/revision.yaml" "$REPO/api/orders.openapi.yaml"; HEAD="$(commit new)"; pr_event
  run_action
  [ "$status" -eq 1 ] # api/openapi.yaml still has its breaking changes
  [ "$(requests)" -eq 1 ]
  grep -q "Nothing to compare them with yet: \`api/orders.openapi.yaml\`" "$GITHUB_STEP_SUMMARY"
}

# ---------- validate ----------

@test "validate: a second request, lint warnings in the report" {
  INPUT_VALIDATE=true run_action
  [ "$status" -eq 1 ]
  [ "$(requests)" -eq 2 ]
  [ "$(out requests-used)" = 2 ]
  [[ $(comment_body post) == *"Validation: ✅ valid · 4 lint warnings"* ]]
}

@test "validate: an invalid new spec fails with its errors on the lines" {
  cp "$ROOT/tests/responses/validate_200_invalid.json" "$MOCK_DIR/body_200_validate"
  cp "$FIX/base.yaml" "$REPO/api/openapi.yaml"
  cp "$FIX/invalid.yaml" "$REPO/api/broken.openapi.yaml"; HEAD="$(commit broken)"; pr_event
  INPUT_VALIDATE=true run_action
  [ "$status" -eq 1 ]
  [ "$(requests)" -eq 1 ]
  [[ $output == *"::error file=api/broken.openapi.yaml,line=7,title=Invalid OpenAPI (minProperties)::{} should be non-empty at /paths/~1x/get/responses"* ]]
  [[ $output == *"Specwise check failed::1 spec(s) invalid."* ]]
  [ "$(out breaking)" = false ]
}

# ---------- API errors ----------

@test "422 on this branch's version: error on the line, fails" {
  echo 422 > "$MOCK_DIR/status_diff"
  echo '{"detail":"revision is not valid YAML or JSON: did not find expected node content at line 9, column 3"}' > "$MOCK_DIR/body_422_diff"
  run_action
  [ "$status" -eq 1 ]
  [[ $output == *"::error file=api/openapi.yaml,line=9,title=Specwise could not parse this spec::revision is not valid YAML"* ]]
  [[ $output == *"1 spec(s) could not be parsed"* ]]
}

@test "422 on the base version: a warning, not this change's fault" {
  echo 422 > "$MOCK_DIR/status_diff"
  run_action
  [ "$status" -eq 0 ]
  [[ $output == *"::warning file=api/openapi.yaml::Specwise couldn't read the base version of this spec: base is not valid YAML"* ]]
}

@test "401: error with the subscribe link, fails, stops" {
  echo 401 > "$MOCK_DIR/status_diff"
  two_specs
  run_action
  [ "$status" -eq 1 ]
  [[ $output == *"::error::Specwise refused the key (HTTP 401: Invalid API key."* ]]
  [ "$(requests)" -eq 1 ]
  [ "$(out passed)" = false ]
  grep -q "not_analysed\|key refused" "$GITHUB_STEP_SUMMARY"
}

@test "429 with on-quota-exceeded warn: warning, passes" {
  echo 429 > "$MOCK_DIR/status_diff"
  run_action
  [ "$status" -eq 0 ]
  [[ $output == *"::warning::Specwise monthly quota exhausted"* ]]
}

@test "429 with on-quota-exceeded fail: fails" {
  echo 429 > "$MOCK_DIR/status_diff"
  INPUT_ON_QUOTA_EXCEEDED=fail run_action
  [ "$status" -eq 1 ]
  [[ $output == *"::error::Specwise monthly quota exhausted. Upgrade at"* ]]
}

@test "API down: one retry, then a warning, and the build passes" {
  printf '503\n503\n' > "$MOCK_DIR/status_diff"
  run_action
  [ "$status" -eq 0 ]
  [ "$(out requests-used)" = 2 ]
  [[ $output == *"Your build is not failed because of it."* ]]
}

@test "API blip: the retry succeeds" {
  printf '000\n200\n' > "$MOCK_DIR/status_diff"
  run_action
  [ "$status" -eq 1 ]
  [ "$(out breaking)" = true ]
  [ "$(out requests-used)" = 2 ]
}

@test "max-requests: specs over the cap are listed as not checked" {
  two_specs
  INPUT_MAX_REQUESTS=1 run_action
  [ "$(requests)" -eq 1 ]
  grep -q "max-requests (1) reached" "$GITHUB_STEP_SUMMARY"
}

# ---------- events and inputs ----------

@test "no key on a pull request (forks): warning, passes" {
  INPUT_RAPIDAPI_KEY="" run_action
  [ "$status" -eq 0 ]
  [[ $output == *"::warning::Specwise skipped: no rapidapi-key."* ]]
}

@test "no key on a push: error" {
  export GITHUB_EVENT_NAME=push
  INPUT_RAPIDAPI_KEY="" run_action
  [ "$status" -eq 1 ]
  [[ $output == *"::error::rapidapi-key is empty."* ]]
}

@test "push: compares with the previous commit, no comment" {
  export GITHUB_EVENT_NAME=push
  jq -n --arg b "$BASE" --arg a "$HEAD" '{before: $b, after: $a}' > "$GITHUB_EVENT_PATH"
  run_action
  [ "$status" -eq 1 ]
  [ "$(out breaking-changes)" = 3 ]
  [ ! -f "$MOCK_DIR/github.log" ]
}

@test "push of a new branch: no base, nothing compared" {
  export GITHUB_EVENT_NAME=push
  jq -n --arg a "$HEAD" '{before: "0000000000000000000000000000000000000000", after: $a}' > "$GITHUB_EVENT_PATH"
  run_action
  [ "$status" -eq 0 ]
  [[ $output == *"::notice::No base to compare against for this event (set base-ref)"* ]]
  [ "$(requests)" -eq 0 ]
}

@test "base-ref input wins, and a base the checkout lacks is read through the GitHub API" {
  mkdir -p "$MOCK_DIR/contents/api"
  cp "$FIX/base.yaml" "$MOCK_DIR/contents/api/openapi.yaml"
  INPUT_BASE_REF=1234567890abcdef1234567890abcdef12345678 run_action
  [ "$status" -eq 1 ]
  grep -q "GET repos/acme/app/contents/api/openapi.yaml?ref=1234567890abcdef1234567890abcdef12345678" "$MOCK_DIR/github.log"
  [ "$(jq -r '.base' "$MOCK_DIR/requests.log")" = "$(cat "$FIX/base.yaml")" ]
}

@test "bad inputs are refused before any request" {
  INPUT_FAIL_ON_BREAKING=maybe run_action
  [ "$status" -eq 1 ]
  [[ $output == *"::error::fail-on-breaking must be true or false (got 'maybe')."* ]]
  INPUT_MAX_REQUESTS=ten run_action
  [[ $output == *"::error::max-requests must be a whole number."* ]]
  INPUT_ON_QUOTA_EXCEEDED=ignore run_action
  [[ $output == *"::error::on-quota-exceeded must be warn or fail."* ]]
  [ "$(requests)" -eq 0 ]
}

@test "the key is masked" {
  run_action
  [[ $output == *"::add-mask::test-key"* ]]
}
