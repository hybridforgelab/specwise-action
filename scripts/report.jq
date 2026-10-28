# Input: {results, passed, allowed, allow_label, fail_on_breaking, requests, quota, blob, pr}.
# Output: Markdown for the job summary and the pull request comment.
def cell: tostring | gsub("\\|"; "\\|") | gsub("\n"; " ");
def plural($n; $word): "\($n) \($word)\(if $n == 1 then "" else "s" end)";
def sev: {breaking: "🔴 breaking", warning: "🟠 warning", "non-breaking": "🟢 non-breaking", info: "⚪ info"}[.] // .;
def where($blob; $file): if .line then "[line \(.line)](\($blob)/\($file | @uri | gsub("%2F"; "/"))#L\(.line))" else "" end;
def table($blob; $file; $rows; $max):
  "| Severity | Change | Operation | Where |",
  "|---|---|---|---|",
  ($rows[:$max][] | "| \(.severity | sev) | \(.message | cell) | \(.operation // "" | cell) | \(where($blob; $file)) |"),
  (if ($rows | length) > $max then "", "…and \(($rows | length) - $max) more." else empty end);

. as $r
| ([.results[] | select(.diff or .validate)]) as $checked
| ([.results[] | select(.status == "new" and (.validate | not))]) as $new
| ([.results[] | select(.status == "skipped" or .status == "not_analysed" or .status == "invalid" or .status == "failed")]) as $other
| ([.results[] | select(.status == "unchanged")]) as $unchanged
| "## Specwise \(if .passed then "✅" else "❌" end)\n",
  (if ($checked | length) == 0 and ($new | length) == 0 and ($other | length) == 0 then
    "No OpenAPI spec changed\(if .pr != "" then " in this pull request" else "" end).\n"
  else empty end),
  ($checked[] as $s
    | ($s.diff.changes // []) as $ch
    | ([$ch[] | select(.severity == "breaking" or .severity == "warning")]) as $bad
    | ([$ch[] | select(.severity == "non-breaking" or .severity == "info")]) as $ok
    | "### `\($s.file)`\n",
      (if $s.diff then
        (if $s.diff.breaking then "**\(plural($s.diff.summary.breaking; "breaking change"))**"
         elif $s.diff.summary.total == 0 then "No changes to the API"
         else "No breaking changes" end)
        + " · \(plural($s.diff.summary.total; "change")) in total"
        + (if $s.diff.base_version != null or $s.diff.revision_version != null
           then " · version `\($s.diff.base_version // "?")` → `\($s.diff.revision_version // "?")`" else "" end)
        + " · suggested bump: **\($s.diff.semver)**",
        "",
        (if ($bad | length) > 0 then table($r.blob; $s.file; $bad; 50), "" else empty end),
        (if ($ok | length) > 0 then
          "<details><summary>\(plural($ok | length; "other change"))</summary>", "",
          table($r.blob; $s.file; $ok; 100), "", "</details>", ""
        else empty end),
        (if ($s.diff.unresolved_refs.revision | length) > 0 or ($s.diff.unresolved_refs.base | length) > 0 then
          "> External `$ref`s were not compared. Bundle the spec into one file first (for example `redocly bundle`).", ""
        else empty end),
        (if $s.diff.truncated then "> More than 2,000 changes: the list was cut.", "" else empty end)
      else "New spec: nothing to compare it with.\n" end),
      (if $s.validate then
        (if $s.validate.valid then "Validation: ✅ valid" else "Validation: ❌ **\(plural($s.validate.error_count; "error"))**" end)
        + (if $s.validate.warning_count > 0 then " · \(plural($s.validate.warning_count; "lint warning"))" else "" end),
        "",
        (if ($s.validate.errors | length) > 0 then
          "| Error | Pointer | Where |", "|---|---|---|",
          ($s.validate.errors[:50][] | "| \(.message | cell) | `\(.pointer | cell)` | \(where($r.blob; $s.file)) |"), ""
        else empty end),
        (if ($s.validate.warnings | length) > 0 then
          "<details><summary>\(plural($s.validate.warning_count; "lint warning"))</summary>", "",
          "| Rule | Warning | Where |", "|---|---|---|",
          ($s.validate.warnings[:100][] | "| `\(.rule)` | \(.message | cell) | \(where($r.blob; $s.file)) |"), "",
          "</details>", ""
        else empty end)
      else empty end)),
  (if ($new | length) > 0 then
    "### New specs", "",
    "Nothing to compare them with yet: \($new | map("`\(.file)`") | join(", ")). Set `validate: true` to check them.", ""
  else empty end),
  (if ($other | length) > 0 then
    "### Not checked", "",
    "| Spec | Why |", "|---|---|",
    ($other[] | "| `\(.file | cell)` | \(.reason | cell) |"), ""
  else empty end),
  (if any($checked[]; .diff.breaking == true) then
    (if .allowed then "The label `\(.allow_label)` accepts these breaking changes."
     elif .fail_on_breaking | not then "Breaking changes don't fail this check (`fail-on-breaking: false`)."
     elif .allow_label != "" then "To accept these breaking changes, add the label `\(.allow_label)` to the pull request."
     else "" end), ""
  else empty end),
  "<sub>\(if ($unchanged | length) > 0 then "\(plural($unchanged | length; "unchanged spec")) skipped · " else "" end)requests used: \(.requests)"
  + (if .quota != "" then " · quota left this month: \(.quota)" else "" end)
  + " · [Specwise](https://specwise.hybridforgelab.com) by Hybrid Forge Lab</sub>"
