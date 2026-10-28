# Specwise GitHub Action

Find the **breaking changes** a pull request makes to your **OpenAPI spec**, before your clients do:

- a removed path or operation;
- a new required parameter or request property;
- a narrower request type, a removed enum value or a stricter constraint;
- a response property that was removed or may now be missing;
- an operation that now requires authentication.

That's 26 kinds of breaking change, out of 69 kinds of change it classifies as breaking, warning, non-breaking or info.

How it works:

- It compares each changed spec with its version on the base branch.
- It posts the result as a pull request comment, updated on every push.
- Each breaking change is also an annotation on the line of the spec.
- The check fails until the breaking changes are fixed, or accepted with a label.

It calls the [Specwise API](https://specwise.hybridforgelab.com) with **your own RapidAPI key**.

- The free Basic plan has 15 requests a month.
- One changed spec is one request.

```yaml
name: specwise
on:
  pull_request:
    types: [opened, synchronize, reopened, labeled, unlabeled]
permissions:
  contents: read
  pull-requests: write
jobs:
  openapi:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: hybridforgelab/specwise-action@v1
        with:
          rapidapi-key: ${{ secrets.RAPIDAPI_KEY }}
```

1. Subscribe to the [Specwise API on RapidAPI](https://rapidapi.com/hybrid-forge-lab-hybrid-forge-lab-default/api/specwise-openapi-validator-and-diff-api). Basic is $0 with a hard limit, so it never runs up a bill.
2. Add your RapidAPI key as the repository secret `RAPIDAPI_KEY`.
3. Add the workflow above.

`labeled` and `unlabeled` are there so that adding the `breaking-ok` label re-runs the check.

Each run costs the same requests again.

## What you get

- **A pull request comment**, one per pull request and updated in place:
  - per spec, the number of breaking changes, the version change and the suggested semver bump;
  - a table of breaking changes and warnings, each linked to its line;
  - the other changes in a collapsed section.
- **Annotations on the spec:**
  - breaking changes as errors, warnings as warnings;
  - on the line of the change, or of the nearest parent that still exists for removals.
- **The same report in the job summary**, also when the job can't comment.
- **A pass/fail result:**
  - the step fails when a spec has breaking changes;
  - with the label `breaking-ok` on the pull request, the annotations become warnings and the step passes.

## Inputs

| input | default | meaning |
|---|---|---|
| `rapidapi-key` | *required* | your RapidAPI key |
| `spec-paths` | `**/openapi.yaml,**/openapi.yml,**/openapi.json,**/*.openapi.yaml,**/*.openapi.yml,**/*.openapi.json` | comma-separated globs |
| `exclude-paths` | `**/node_modules/**,**/vendor/**` | comma-separated globs to skip |
| `base-ref` | *empty* | what to compare with: default the pull request's base, or the previous commit on a push |
| `fail-on-breaking` | `true` | fail on breaking changes (unless `allow-label` is set on the pull request) |
| `allow-label` | `breaking-ok` | the label that accepts breaking changes; empty to disable |
| `validate` | `false` | also validate every changed spec (one more request each) and fail on errors |
| `comment` | `true` | post the report as a pull request comment |
| `max-requests` | `10` | cap per run; specs over it are listed as not checked |
| `on-quota-exceeded` | `warn` | `warn` or `fail` when the monthly quota runs out |
| `github-token` | `${{ github.token }}` | reads labels and the base version, and comments |

## Outputs

| output | meaning |
|---|---|
| `passed` | `true` when the check passed |
| `breaking` | `true` when any spec has breaking changes, even if a label accepted them |
| `breaking-changes` | number of breaking changes across all specs |
| `changes` | number of changes across all specs |
| `semver` | suggested bump: `major`, `minor`, `patch` or `none` |
| `specs-compared` | specs compared with their base version |
| `requests-used` | API requests used by this run |
| `quota-remaining` | requests left this month, from RapidAPI's `x-ratelimit-requests-remaining` header |
| `comment-url` | the pull request comment, empty when none was posted |

To use an output in a later step, give this step an `id` and read `steps.<id>.outputs.semver`.

## Saving requests

One changed spec is one request, or two with `validate: true`.

These cost nothing:

- specs the change didn't touch, compared locally with the base version;
- a new spec, which has nothing to compare with (with `validate: true` it is validated instead);
- Swagger 2.0 files, and files over 900 KiB, which are listed as not checked.

Most repositories have one spec. A pull request then costs one request, and only when it touches the spec.

## When something goes wrong

| situation | what the action does |
|---|---|
| no key on a pull request from a fork (forks don't get secrets) | warning, step passes |
| key invalid or not subscribed (401/403) | error with the subscribe link, step fails |
| this branch's spec can't be parsed (422) | error annotation on the line, step fails |
| the base version can't be parsed | warning, that spec is skipped |
| quota exhausted (429) | `on-quota-exceeded: warn` gives a warning and the step passes; `fail` fails it |
| API down or timing out | one retry, then a warning: **your build is never failed because of us** |
| no permission to comment | a notice; the report is in the job summary |

Use `on: pull_request`, not `pull_request_target`:

- with `pull_request_target`, a pull request from a fork would run with your secrets;
- skipping fork pull requests is the safe default.

## Specs in several files

Specwise only follows local `#/` references.

If your spec uses `$ref: ./schemas/pet.yaml`, bundle it into one file first and point `spec-paths` at the bundle:

```yaml
      - run: npx @redocly/cli@latest bundle api/openapi.yaml -o openapi.bundled.yaml
      - uses: hybridforgelab/specwise-action@v1
        with:
          rapidapi-key: ${{ secrets.RAPIDAPI_KEY }}
          spec-paths: openapi.bundled.yaml
```

The bundle isn't committed, so the base needs one too. Either:

- bundle the base branch's version in the same job, and pass it with `base-ref`; or
- commit the bundle.

## Compared with oasdiff

[oasdiff](https://github.com/oasdiff/oasdiff) is free, open source, has its own action and follows `$ref`s to other files.

If it does what you need, use it. This action is for teams that want:

- validation and the breaking-change check in one step;
- a label to accept breaking changes on purpose;
- a report in the pull request with a link to the line of every change.

## Privacy

- Both versions of each changed spec are sent to the Specwise API, processed in memory and discarded.
- Nothing is stored, and specs are never logged.
- Your key is masked in the logs.

See the [privacy policy](https://specwise.hybridforgelab.com/privacy.html).

## Limits

- OpenAPI 3.0, 3.1 and 3.2 only. Swagger 2.0 can't be compared.
- External `$ref`s are not fetched or compared, and the report says so.
- Lines need [yq](https://github.com/mikefarah/yq), which GitHub-hosted runners have. Without it, annotations point at the file.
- The runner needs `bash`, `curl`, `jq` and `git`. GitHub-hosted runners have all four.

## Contributing

Issues and pull requests are welcome: see the [contributing guide](https://github.com/hybridforgelab/.github/blob/main/CONTRIBUTING.md).

To work on the action:

```bash
bats tests/                                 # unit tests (curl is faked, no key needed)
shellcheck -x scripts/*.sh tests/bin/curl
actionlint
```

The end-to-end test (`.github/workflows/e2e.yml`) runs the action against the real API monthly, with the `RAPIDAPI_KEY` secret.

## Licence

MIT.

Specwise itself is a paid API with a free plan, run by [Hybrid Forge Lab](https://hybridforgelab.com).
