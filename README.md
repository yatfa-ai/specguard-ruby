# specguard-ruby

> The Ruby client for [SpecGuard](https://github.com/yatfa-ai/specguard), every Ruby test framework
> in one gem: an RSpec formatter and a Minitest reporter that ship test-run telemetry, and a CLI
> linter that validates `@intent` annotations.

Two independent tools, one dependency — the [OpenTestIntent](https://github.com/yatfa-ai/open-test-intent) annotation format.
A third command, [`specguard-ingest`](#replaying-a-saved-run--specguard-ingest), belongs to the first of them: it replays a
run a reporter saved when the endpoint could not be reached.

This gem was named `specguard-rspec` while RSpec was its only adapter; it was renamed when the
Minitest reporter joined. Same environment variables, same wire contract, same tools.

## Install

```ruby
# Gemfile
group :test do
  gem "specguard-ruby", require: false
end
```

## The Minitest reporter

Minitest discovers the reporter as a plugin — the gem on the load path is the whole integration,
no spec file changes, no flags:

```bash
SPECGUARD_ENDPOINT=https://specguard.example SPECGUARD_API_KEY=sgk_… bundle exec ruby test/your_suite.rb
```

The plugin rides alongside Minitest's own reporters (the suite's output is unchanged), posts one
envelope per process with the same field names the RSpec formatter sends, and never fails the run:
a refused or unreachable delivery costs one line on stderr and a line in the local sink. Without
`SPECGUARD_API_KEY` nothing is sent — the run is appended to the local development record, exactly
as the RSpec formatter behaves. Parameterized tests — the `define_method("test_x_#{param}")` loop
idiom — ship one row per instance, not one row per definition site, so each instance's outcome and
duration are tracked on their own. For a deterministic CI attachment where plugin discovery must not
be assumed, require it explicitly before the run:

```bash
bundle exec ruby -rminitest/specguard_plugin -e 'Minitest.extensions << "specguard"; load ARGV[0]' test/your_suite.rb
```

## The linter — `specguard-lint`

Validates `# @intent:` annotations in changed (or all) `*_spec.rb` files against the OpenTestIntent
JSON Schema. Exits `1` on a malformed annotation — or a well-formed but unreachable one (stacked
above another comment-form `@intent:` line, so the one-line lookback never claims it) — and
**never** fails on a *missing* one (adoption is opt-in and gradual).

```bash
bundle exec specguard-lint --changed   # CI mode: only files in the current diff
bundle exec specguard-lint             # one-off audit: every *_spec.rb
```

Files are **positional** (`specguard-lint spec/order_spec.rb`); there is no `--source` flag —
that belongs to `validate-intent`, not to this one.

The linter is a thin CLI over the [`validate-intent`](https://github.com/yatfa-ai/open-test-intent)
binary — the protocol's own reference implementation, which decides whether an annotation is valid
against [`PROTOCOL.md`](https://github.com/yatfa-ai/open-test-intent/blob/main/PROTOCOL.md) and the
canonical schema compiled into it. Since SPGD-867 that is the only validator: the gem selects the
files, resolves the binary, renders the report and owns the 0/1/2 exit contract, and the verdicts
are the binary's. Its rendering is checked by replaying that tool's own recorded reports through
this CLI in `spec/specguard/rspec/validator_backend_spec.rb` — findings, ordering and exit codes,
byte for byte.

### Machine-readable output (`--json`)

The human report is for humans. `--json` emits **one JSON document on stdout** instead, so a CI
step or an agent gets *which file, which line, which rule* as data rather than a prose format to
regex and a 3-valued exit code. The flag can go anywhere on the command line.

```bash
bundle exec specguard-lint --json spec/models/order_spec.rb
```
```json
{
  "schema": "open-test-intent.v1.json",
  "mode": "source",
  "ok": false,
  "summary": { "files": 1, "annotations": 2, "failed": 2 },
  "findings": [
    { "file": "spec/models/order_spec.rb", "line": 24, "ok": false, "kind": "schema",
      "errors": ["<root>: additional property 'entiity' is not allowed"],
      "intent": { "entiity": "Order", "action": "checkout", "behavior": "...", "layer": "request" } },
    { "file": "spec/models/order_spec.rb", "line": 31, "ok": false, "kind": "extraction",
      "errors": ["unterminated object literal (an annotation must fit on one line)"],
      "intent": null }
  ]
}
```

This is the **same document** `validate-intent --json --source` emits, key for key — the gem
already *consumes* it when the Go backend is on, and a consumer of both tools should not need two
parsers for one protocol. It is not byte-identical; it is key-, type- and value-identical, which is
what a parser sees.

| field                 | meaning |
| --------------------- | ------- |
| `schema`              | the OpenTestIntent schema version the payloads were validated against |
| `mode`                | always `"source"` — annotations in spec sources, the port's name for what this tool does. Not the *selection* mode (`--changed` vs named files), which the document has no field for |
| `ok`                  | whether the run passed — derived from the exit code, not recomputed, so the two renderers cannot disagree |
| `summary.files`       | spec files selected: the number the text report's leading `checked N spec file(s)` line states |
| `summary.annotations` | annotation sites examined: the number its trailing summary line states. A site whose payload could not be captured or parsed still counts; a file that could not be read contributes none |
| `summary.failed`      | findings with `"ok": false`, read failures included. Note this is **not** the text summary's `M malformed`, which counts malformed annotations and reports unread files in its own clause |

Every finding has the same six keys:

| field    | meaning |
| -------- | ------- |
| `file`   | the path, echoed back exactly as it was given |
| `line`   | the annotation's line number; **`null`** where the finding is not line-scoped — a read failure saw no line of the file, and `file:0` would point CI annotations and editor quickfix at a line that does not exist |
| `ok`     | whether this finding passed |
| `kind`   | *how* it failed; `null` when it passed |
| `errors` | every violated rule, or the single problem — **always** a list of strings, never null and never a bare string, so a consumer never branches on its type |
| `intent` | what the payload **parsed to** — the annotation as data, after the permissive syntax (unquoted keys, single quotes) has been normalized away. `null` where there was no payload to parse: a read, extraction or parse failure. A **schema-rejected** annotation still carries it — it parsed, and `ok` already reports the verdict, so this field answers *what does this say*, not *is this good* |

> `intent` is `null` in one case that is not about your annotation: a payload holding a lone
> surrogate escape (`"\ud800"`) is valid to the Go/Python validator and cannot be represented in
> Ruby at all — `JSON.parse` refuses it and `JSON.generate` cannot re-emit it. Rather than repair
> it into something you did not write, this tool drops the payload and keeps the verdict, so the
> finding is still reported and the exit code is unchanged.

`kind` is the field the prose renderer destroys: a failed extraction and an unparseable payload
both read as one sentence after `FAIL … — `, and only `kind` tells them apart.

| `kind` | means |
| ------ | ----- |
| `schema` | parsed fine, violated the OpenTestIntent schema |
| `extraction` | an `@intent:` token whose object literal could not be captured (missing or unbalanced braces, or spread across lines) |
| `parse` | the payload was captured but is not JSON even after normalisation |
| `read` | the file could not be read at all (missing, unopenable, or not valid UTF-8), so no annotation in it was ever seen |

The port has a fifth kind, `no-match`, that cannot appear here: its arguments are globs and this
tool's are paths, so a path that matches nothing is a `read` failure of that path.

Three things worth knowing:

- **Exit codes are identical with and without the flag**, and the default output is unchanged.
  `--json` is a second renderer over the same checks, not a second code path — it is pinned that
  way in `spec/specguard/rspec/exit_contract_spec.rb` and
  `spec/specguard/rspec/regression_targets_spec.rb`.
- **A run that could not produce verdicts emits no document.** Bad flags, `--changed` outside a
  repository, a validator that could not be resolved — all still exit `2` with prose on stderr. Those runs checked nothing, and `{"ok": false, "findings": []}` is exactly how a
  gate that checked nothing gets mistaken for one that found nothing.
- **The provenance line stays on stderr** and is deliberately *not* duplicated into the document
  (see below). Redirect `2>` to keep it; stdout is the document and nothing else.

### The validator: `validate-intent`, resolved on every run

`specguard-lint` validates through the Go `validate-intent` binary and **only** through it — the
Ruby hand-rolled validation path was removed at SPGD-867, completing the SPGD-96 cutover. The
formatter's annotation half asks the same binary the linter does, so what CI ratified and what the
platform receives come from one implementation.

**Resolution order** (in `ValidatorBackend.resolve`):

1. `SPECGUARD_VALIDATE_INTENT` names a binary → that one, verified before anything is selected or
   checked. A blank value counts as unset.
2. Otherwise → the platform-matched prebuilt binary from open-test-intent's GitHub release
   (`v0.1.3`: `validate-intent-{linux,darwin}-{amd64,arm64}`, static, schema compiled in), fetched
   on first run, verified against the release's `SHA256SUMS` manifest, installed atomically under
   the user cache dir, and reused from there afterwards. Redirect the cache with
   `SPECGUARD_CACHE_DIR` (XDG_CACHE_HOME is honoured too).

**When no binary can be resolved** — first run with no network, an unsupported platform — the run
exits `2` with a message naming **both** remediations, before anything is selected or checked:

```
specguard-lint: error: could not obtain validate-intent from https://github.com/yatfa-ai/open-test-intent/releases/download/v0.1.3: ... ; set SPECGUARD_VALIDATE_INTENT to a validate-intent binary, or install one with: curl -fsSL https://raw.githubusercontent.com/yatfa-ai/open-test-intent/v0.1.3/scripts/install.sh | sh
```

It never falls back to Ruby, because there is no Ruby validation left to fall back to — that is the
cutover. `--require-validator` is gone with the same stroke: its assertion ("fail unless the binary
actually ran") is now the always-on failure mode, so passing the retired flag is an ordinary usage
error (exit `2`, `invalid option`).

**CI without network access** should pin the install explicitly with open-test-intent's own
`install.sh` (the same verified release artifact) and point the env var at the result:

```bash
curl -fsSL https://raw.githubusercontent.com/yatfa-ai/open-test-intent/v0.1.3/scripts/install.sh | sh
SPECGUARD_VALIDATE_INTENT="$(command -v validate-intent)" bundle exec specguard-lint --changed
```

#### Every run says which validator ran

`specguard-lint` states it, in one line on **stderr**, on every run:

```
specguard-lint: validated by validate-intent 1.4.0 (go1.22.12 linux/arm64) schema sha256:3760d8f7… at /path/to/validate-intent (SPECGUARD_VALIDATE_INTENT) — it reports enforcing the schema this gem vendors, loaded from /usr/local/schemas/open-test-intent.v1.json
```

Three things worth knowing about it:

* **stdout is untouched.** The line is on stderr, beside the other diagnostics about the linter
  itself, so the findings and the two `checked …` lines stay safe to pipe. Under `--json` it stays
  exactly where it is and is **not** copied into the document.
* **The identity is the binary's own.** It comes from `<binary> --version`, asked once per run
  before any file is selected, and is passed through verbatim rather than reworded — that is the
  only thing that can tell two builds of the validator apart.
* **A binary that cannot answer still validates.** `--version` and `--schema-source` each arrived in
  a later slice of the validator; a build without one reads the flag as a filename and exits 1. That
  costs nothing — same findings, same exit code, same stdout — and the line says which question went
  unanswered, in words (`… which could not report its identity, so the schema contract it carries
  could not be checked`) rather than going missing.

#### Which schema the run enforces

The identity line is not only printed. `specguard-lint` compares the schema *this gem* vendors —
digested from the file at runtime — against the schema the binary reports, before any file is
selected or checked, and refuses the run when the two differ.

**Which digest it asks for is the whole of this check.** `validate-intent --version` ends
`schema sha256:<64-hex>`, the digest of the JSON Schema **compiled into** that binary — and that is
not the schema a run necessarily *loads*. A `schemas/open-test-intent.v1.json` sitting beside the
executable takes precedence over the compiled-in copy, and `--version` answers above that decision
and never reaches it; the binary's own `--help` says the digest "is not a claim about what a given
run enforced". So `specguard-lint` asks `validate-intent --schema-source`, which runs the real
loader and reports the origin and digest of the bytes a verdict run would enforce, and compares
*that*. Both questions are asked once per run, before any file is selected or checked.

This is the one thing about the pair that neither half can check by itself. Both sides already pin
their own schema against their own tree, and both stay green while disagreeing with each other: the
gem is installed from RubyGems, the binary is resolved or fetched by version separately, and nothing
ties the two vintages together. What that produces is a run that succeeds under a contract other
than the one this gem ships.

**The run enforces the schema this gem vendors.** It proceeds, and the line names where that schema
came from — an absolute path when a file beside the binary won, or `<embedded schema>` when the
compiled-in copy did:

```
specguard-lint: validated by validate-intent 1.4.0 (…) at /path/to/validate-intent (SPECGUARD_VALIDATE_INTENT) — it reports enforcing the schema this gem vendors, loaded from <embedded schema>
```

**It enforces a different one.** Exit `2`, before any file is selected or checked:

```
specguard-lint: error: the validator backend at /path/to/validate-intent (SPECGUARD_VALIDATE_INTENT) reports enforcing schema sha256:9c1e…, loaded from /usr/local/schemas/open-test-intent.v1.json, but this gem vendors sha256:3760… — the two halves would enforce different contracts, so this run would produce a verdict this gem cannot stand behind; the binary identifies itself as validate-intent 1.5.0 (go1.22.12 linux/arm64) schema sha256:3760…
```

Both digests are printed in full (elided above only to fit), because one of them lives inside a
binary and the other inside an installed gem and neither is inspectable from where the other lives.
The origin is there because it says *which half to move*: a stale `<embedded schema>` is fixed by
rebuilding or reinstalling the binary, and a path on this host by replacing or deleting that file.
To fix a divergence, move whichever half is stale so the two agree.

**The binary is too old to be asked.** `--schema-source` arrived in a later slice of the validator;
an older build reads it as a filename and exits 1, and a schema that exists beside the binary and
will not load exits 2 with its own "could not load schema" diagnostic (which the run reaches a
moment later anyway, from the path that owns it). Neither costs a verdict. The comparison falls back
to the *carried* digest — the same two outcomes, proceed or exit `2` — and the line keeps the hedge
that belongs to that weaker question, because on that path it is still true:

```
specguard-lint: validated by validate-intent 1.2.0 (…) at /path/to/validate-intent (SPECGUARD_VALIDATE_INTENT), which reports carrying the schema this gem vendors — the contract it carries, not necessarily the one this run enforced
```

**No digest to compare.** Never a refusal — same findings, same exit code, same stdout — and the
provenance line says which kind of "could not check" it was, in its own words:

* `…, which reports no schema digest, so the contract it carries could not be checked` — a build
  older than the slice that added the token.
* `…, which could not report its identity, so the schema contract it carries could not be checked` —
  a build too old to answer `--version` at all.
* `…, whose schema contract could not be checked: this gem could not read its own vendored copy` —
  the gem's own installation is missing or unreadable. Not fatal on purpose: the binary's run does
  not otherwise read that file, and a missing operand is an unanswered question, not a
  disagreement.

#### Read-failure wording

The gem's arguments are paths; the binary's are glob patterns. A path that matches nothing —
missing, or not a regular file — reaches the gem as the same answer the binary gives both shapes
(`no-match`), which the CLI re-words as `could not read file: no file at this path` and folds into
the `read` kind. The binary's own UTF-8 refusal prose (`input is not well-formed UTF-8
(PROTOCOL.md §1.1 requires it)`) and parse-failure prose are passed through unaltered.

Every way the backend can fail — the binary is missing, will not execute, exits with something that
is not a verdict, or emits output that is not a report — is **exit 2**, the linter's "could not do
my job" code. It never becomes exit 1, which means "an annotation is malformed" — or well-formed
but unreachable: stacked above another comment-form `@intent:` line, so the one-line lookback
never claims it — and nothing else.

## The formatter — `SpecGuard::RSpecFormatter`

An **additive** RSpec formatter: it runs alongside your usual one (`progress`, `documentation`, …)
rather than replacing it, and records every example that finished — annotated or not — as one JSON
object per run, POSTed to SpecGuard (or written to `log/test_results.jsonl` when there is no API
key).

```ruby
# spec/spec_helper.rb
require "specguard/rspec/formatter"
RSpec.configure do |config|
  config.add_formatter(SpecGuard::RSpecFormatter)
end
```

```
# ...or in .rspec — the --require is not optional, RSpec cannot guess this path
--require specguard/rspec/formatter
--format SpecGuard::RSpecFormatter
```

The two forms are equivalent, and neither needs you to name a human formatter. Additive is meant
literally, in both directions: if you chose a formatter that reports the run to a human
(`progress`, `documentation`, `--format failures`, `--format json`, …), it is left alone and
SpecGuard adds nothing to your output; if you chose none, you get RSpec's default (`progress`)
exactly as you would without this gem — same dots, same failures, same summary, byte for byte.

The qualifier on that first half is deliberate. SpecGuard restores the default when no *other*
registered formatter would give a human an account of the run, and it judges that by the formatter
protocol — whether anything answers to `example_started`, `example_passed`, `example_failed`,
`example_pending` or `dump_summary`. So if the only other formatter you registered is a silent one
(another telemetry gem, a custom notifier that writes elsewhere), SpecGuard reads the run as
unserved and restores `progress`, and you get output you did not have before. That is the error
direction chosen on purpose — noisy beats silent, which is the whole point of this behaviour — but
if you want a genuinely quiet run, name a formatter that reports the run and says little:
`--format failures` prints one line per failure and nothing else, so a green suite stays at zero
bytes and the restore does not fire.

That second half is not free, because RSpec installs its default formatter only when *no* formatter
was registered at all — so a gem that registers one silently suppresses it, and a failing suite
prints nothing. SpecGuard restores it on the first notification of the run, once RSpec has finished
deciding. If you want something other than `progress`, name it the usual way (`--format
documentation`, or `config.default_formatter = "doc"`) and that is what you will get, on its own.

"Byte for byte" is checked rather than asserted: `spec/specguard/rspec/formatter_run_spec.rb` runs
each wiring and the same suite with no SpecGuard at all, and diffs the two streams end to end with
only the two wall-clock numbers erased. Both a failing suite and a suite that reports through
`reporter.message` — an error in an `after(:context)` hook — are compared that way, because they
travel through different formatters and an addition that is invisible in one shows up in the other.

Each example contributes its `id`, `spec_file_path`, `file_path`, `line_number`, `name` (the composed
`describe`/`context`/`it` string), `duration`, `outcome`, `status` (`"annotated"` or
`"unannotated"`) and `intent` — the parsed annotation when there is one, `null` when there is not;
the run envelope carries `commit_sha`, `branch` and `duration_seconds`.

`id` is RSpec's own example id — `./spec/orders_spec.rb[1:2]`, the argument that re-runs that one
example — and it is the key that distinguishes examples a coordinate cannot. A table-driven loop
writes its `it` once, so all of its examples share a `line_number`; a shared example group reports
the coordinate of `spec/support/shared.rb` from every file that includes it. `spec_file_path` is the
spec file that actually **ran** the example, which is the same as `file_path` for an ordinary example
and the *including* file for a shared one — so duration-by-file adds up against the file you would
have named, not against a `spec/support/` helper.

> `id` is unique within a run, not stable across refactors: it is positional, so reordering examples
> changes it, exactly as inserting a line changes `line_number`. Matching one test across runs is
> `name` plus file.

`file_path` and `line_number` keep meaning the **definition** site — that is the line the `@intent:`
annotation is read from.

An example counts as **annotated** when an `@intent:` sits on its `it` line, or on the comment line
immediately above it:

```ruby
# @intent: { entity: "Order", action: "refund", behavior: "restores stock levels on refund", layer: "unit" }
it "restores stock on refund" do

it "surfaces the decline reason" do # @intent: { entity: "Order", action: "checkout", ... }
```

One line of lookback, no more — and a trailing annotation belongs to its own example only, never to
the one on the next line.

> **A malformed or schema-invalid annotation is recorded as `unannotated`, with a `null` intent, and
> the formatter says nothing about it.** That is deliberate: telemetry must never block CI, and the
> platform validates a run's payload as a whole — so shipping one bad annotation would cost the
> *entire run* its telemetry rather than one row its metadata. `specguard-lint` is the half of this
> gem that tells you about a bad annotation, loudly, with exit code `1`. Run it in CI and the
> formatter never has anything to hide.

```ruby
# optional — the defaults read the commit, branch, CI run id and shard index
# from whichever provider is running you (GitHub Actions, GitLab CI, CircleCI,
# Buildkite, Jenkins), and when none of them named the commit or the branch,
# ask git directly for both — so a laptop run and a hand-rolled container
# report their checkout too, without being configured to. A detached checkout
# reports no branch rather than the string "HEAD".
# SPECGUARD_COMMIT_SHA / SPECGUARD_BRANCH / SPECGUARD_RUN_ID /
# SPECGUARD_SHARD_ID / SPECGUARD_OUTPUT_PATH / SPECGUARD_LOCAL_OUTPUT_PATH
# override any of it.
#
# Assign a value here only when it is one neither source can know:
SpecGuard::RSpec.configure do |config|
  config.branch = "release/2.0"
end
```

## Shipping the run to SpecGuard

Set an API key and an endpoint and the run is POSTed to
`<endpoint>/api/v1/ingest` — once per process, as a single request (see
[If you shard your suite](#if-you-shard-your-suite) for what happens when there
is more than one process):

```bash
export SPECGUARD_ENDPOINT=https://specguard.example.com
export SPECGUARD_API_KEY=…          # from your repository's settings
export SPECGUARD_TIMEOUT=10         # optional; seconds, applied to connect and read
```

```ruby
# ...or in Ruby, if you would rather not use the environment
SpecGuard::RSpec.configure do |config|
  config.endpoint = "https://specguard.example.com"
  config.api_key  = ENV["SPECGUARD_API_KEY"]
  config.timeout  = 10
end
```

**The API key is the switch.** With no key nothing is sent anywhere and the run
is written to `log/test_results.local.jsonl` — the local development record,
kept apart from the replay queue — so local development needs no opt-out, and a
fork with no secret configured behaves like a laptop rather than like a broken
build. The local file's name is configurable via `SPECGUARD_LOCAL_OUTPUT_PATH`
(or `SpecGuard::RSpec.configure { |c| c.local_output_path = ... }`).

**A failed delivery is never silent, and never lost.** If the endpoint refuses
the run (a `401` from a rotated key, a `400`, a `500`) or cannot be reached at
all (connection refused, DNS failure, timeout), the formatter prints **one**
line to stderr naming the status or the error, and writes the payload to
`log/test_results.jsonl` — the **replay queue**: runs offered to the endpoint
and not accepted — so the run can be replayed later with
[`specguard-ingest`](#replaying-a-saved-run--specguard-ingest):

```
SpecGuard: could not deliver test telemetry (HTTP 401 — the API key was not
accepted). Falling back to log/test_results.jsonl; the test run is unaffected.
```

**That line carries the endpoint's own words when it has any.** A `400` refusal
names the offending spec by index, file and line, so a rejected payload is a
thing you can fix from the CI log rather than one you have to reproduce
locally:

```
SpecGuard: could not deliver test telemetry (HTTP 400 — the endpoint rejected
the payload — spec 3 (spec/orders_spec.rb:9): line_number is required and must
be a positive integer; spec 7 (spec/orders_spec.rb:31): outcome must be one of
passed, failed, pending). Falling back to log/test_results.jsonl; the test run
is unaffected.
```

It stays **one** line whatever comes back. A systemic problem can have the
endpoint refusing every spec in the suite, so at most three reasons are spelled
out and the rest are counted (`… and 497 more`); anything that arrives without
a reason it can read — an empty body, or the HTML a proxy answers a `413` with
— prints the bare status line above and is still reported as a refusal, not as
an error.

There are **no retries**, and the whole delivery is bounded by `timeout`
(10 seconds by default, against `Net::HTTP`'s own 60): telemetry is explicitly
allowed to be lost, and a retry would only double what a hung endpoint can cost
your CI run.

**A dry run is refused, to both sinks.** `rspec --dry-run` builds and reports
every example without executing a single body, so its per-example `duration` is
the cost of *constructing* an example (single-digit microseconds — a
`sleep 0.05` example understates its own runtime by three to four orders of
magnitude) and its `outcome` is `passed` for code that never
ran. Nothing downstream can tell the difference, and an all-green, near-instant
run is exactly the shape that poisons both the numbers SpecGuard reports. So
when RSpec is in dry-run mode the formatter makes no POST **and** writes no line
to `log/test_results.jsonl` — a file full of zero-duration green runs is the
same corruption, deferred until something replays it — and says so once:

```
SpecGuard: skipped test telemetry for a dry run (rspec --dry-run executes no
example bodies, so this run's durations and outcomes would not be
measurements). Nothing was sent or written; the test run is unaffected.
Annotation coverage is a fact about source, not about execution, so it
survives the refusal — this working tree: 6 examples, 3 annotated,
3 unannotated (50% annotated).
  the 3 unannotated examples, by definition site:
    spec/orders_spec.rb:7   Order has no annotation
    spec/orders_spec.rb:16  Order has a malformed annotation
    spec/orders_spec.rb:21  Order has a schema-invalid annotation
```

The refusal throws away less than it used to. `duration` and `outcome` are
fabricated by a dry run, which is what makes them unpublishable — but the
third field the formatter computes per example, `annotated` / `unannotated`,
comes from scanning the **spec file's source text** and is identical whether or
not a body ran. Since a dry run still builds every example, it holds the exact
numerator and denominator of the annotation-coverage metric, so `--dry-run` is
also the way to ask *"where are we?"* without a commit, a push, and a CI round
trip. The figure describes **your working tree right now**, so it will differ
from the dashboard's the moment you edit a spec — that difference is the point.

Nothing is published either way: the report goes to stderr and to nowhere else.

This matters most where you are least likely to look for it: an API key is
usually an environment-level secret rather than a job-level one, so a lint job
that runs `rspec --dry-run` to catch an unparseable spec file inherits the key
and would otherwise overwrite your suite's real duration and pass/fail picture
with zeroes and green.

It **never blocks CI.** RSpec does not sandbox formatters — an exception raised
in one escapes the runner and takes RSpec's own exit code with it — so every
hook rescues, warns once on stderr, and leaves the exit status to your suite
alone. A non-2xx response gets the same treatment: `Net::HTTP` returns those as
ordinary values rather than raising, so they are checked for explicitly instead
of being left to a `rescue` that would never see them.

### Replaying a saved run — `specguard-ingest`

The suite is over by the time you see the `401`, and re-running it to recover
the telemetry costs you the whole suite again. So the file the formatter wrote
is the run: each line is byte-for-byte the body the endpoint refused, and
`specguard-ingest` is the command that sends it.

```bash
export SPECGUARD_API_KEY=…            # the key that was rotated, fixed
bundle exec specguard-ingest log/test_results.jsonl
```

```
line 1: accepted — HTTP 202, test_run_id 41f2c9b8, ci_run_id 17442
line 2: accepted — HTTP 202, test_run_id 41f2c9b8, ci_run_id 17442
specguard-ingest: delivered 2 of 2 runs from log/test_results.jsonl
specguard-ingest: lines 1, 2 carried ci_run_id 17442 and each came back with
test_run_id 41f2c9b8 — the endpoint folded them onto one run
```

It reads the same `SPECGUARD_ENDPOINT`, `SPECGUARD_API_KEY` and
`SPECGUARD_TIMEOUT` the formatter does, and sends each line through the same
transport — so a run that was refused for a rotated key appears on the platform
once the secret is fixed, with the shard folding described in
[If you shard your suite](#if-you-shard-your-suite) applying exactly as it would
have during the run.

> **It re-delivers *every* line in the file you give it.** Two kinds of line can
> be sitting in the file you point it at. In files written by **an earlier
> version of the gem**, and in `log/test_results.local.jsonl` — the local
> development record the formatter now writes when no API key is configured —
> ordinary local runs and genuinely failed deliveries are indistinguishable on
> the line, because nothing in the payload records which sink it was destined
> for: the writer split into two files precisely so this could not happen on
> new replay-queue files, and a line from before that split carries no marker.
> So this command will send every line in such a file, and no filter or
> heuristic can change that: guessing which lines "were failures" from data
> that does not say would be confidently wrong about which of your runs reach
> the platform. Check the file first with
> [`--list`](#checking-a-file-before-you-send-it----list), and check it before
> you replay one you did not write. A `log/test_results.jsonl` written entirely
> by this version or later holds only genuine failed deliveries by
> construction — but verify that before you rely on it. If you deliberately
> want one file for both roles, set `local_output_path` to the same value as
> `output_path` and the formatter reproduces the old single-file behaviour.

#### Checking a file before you send it — `--list`

`--list` prints one row per line and **delivers nothing**:

```bash
bundle exec specguard-ingest --list log/test_results.jsonl
```

```
line 1: branch main, commit_sha 0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2, ci_run_id 17442, 412 examples, 93.4s
line 2: branch main, commit_sha 0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2, ci_run_id 17442, 388 examples, 91.2s
line 3: branch spike/local, commit_sha 9c2e7a10b4d3, no ci_run_id, 6 examples, 0.4s
line 4: unparseable — could not parse the line as JSON: unexpected end of input
specguard-ingest: listed 4 lines from log/test_results.jsonl; nothing was delivered
```

Every field on the row is already on the line — nothing is guessed at, and a
line the command cannot parse is listed **as unparseable** rather than quietly
dropped from the preview. `no ci_run_id` is the one to read for: that line has
no identity for SpecGuard to fold a redelivery onto, so sending it creates a new
run rather than joining an existing one.

Reading the file yourself is not the alternative. One line is one whole run, and
at 20,000 examples that is megabytes of JSON on a single physical line.

**It needs no `SPECGUARD_ENDPOINT` and no `SPECGUARD_API_KEY`** — deliberately.
The file most worth checking is the one written *because* no API key was set, so
requiring a key to look at it would withdraw the instrument in exactly the
situation that produces the hazard. It composes with `--from-line` and `--lines`
too, so you can list the exact set you are about to send:

```bash
bundle exec specguard-ingest --list --from-line 7 log/test_results.jsonl
bundle exec specguard-ingest --list --lines 3,7,12-15 log/test_results.jsonl
```

A listing under either selector previews **exactly** the lines the same command
without `--list` would deliver, by the same numbers.

Listing sends nothing, so it can never be a verdict about a run: it exits `0`
when it listed the file and `2` when it could not read it or the flags were
wrong. **`1` is unreachable with `--list`.**

**Each line is reported by its line number**, and `--from-line N` starts at one —
so a file that was only partly accepted is resumed from the line the report
named, rather than blindly re-sent:

```bash
bundle exec specguard-ingest --from-line 7 log/test_results.jsonl
```

The numbering never shifts: line 7 is line 7 of the file you gave it, both times.
Re-sending a line that already landed is harmless *only* when it carries a
`ci_run_id` — that is the identity SpecGuard folds a redelivery onto. A line
**without** one has nothing to fold onto and becomes a second run, and a keyless
local file is made entirely of those, so `--from-line` is worth the two seconds
it takes to read the previous report.

#### Sending a set rather than a suffix — `--lines`

`--from-line` can only express a **suffix**, and the set a per-line report points
at is a suffix at most once. `--lines` takes the set itself — comma-separated
numbers and ranges, over the file's own numbering:

```bash
bundle exec specguard-ingest --lines 3,7,12-15 log/test_results.jsonl
```

```
line 3: accepted — HTTP 202, test_run_id 41f2c9b8, ci_run_id 17442
line 7: accepted — HTTP 202, test_run_id 41f2c9b8, ci_run_id 17442
line 12: accepted — HTTP 202, test_run_id 5a3d0e91, ci_run_id 17443
…
specguard-ingest: delivered 6 of 6 runs from log/test_results.jsonl; 34 lines not selected by --lines
```

Two things want it. The first is an **interior line that will never be accepted**:
an HTTP `400` is the one response SpecGuard forms an opinion about your payload
in, so a line it refuses is refused every time it is offered. Sitting at line 3
of a 40-line file, no `--from-line` can step over it — the file can never be
replayed to completion, and the command can never exit `0` over it. Naming the
set around it can:

```bash
bundle exec specguard-ingest --lines 1-2,4-40 log/test_results.jsonl
```

The second is that the sink is **append-only and mixes both sources**, so
ordinary keyless laptop runs keep landing *after* the CI failures you want to
replay. Every unwanted keyless line a too-early `--from-line` sweeps up is a
spurious run on the platform, because a line with no `ci_run_id` has nothing to
fold onto.

Carving the file up first (`sed -n '21,24p' file > tmp.jsonl`) is not the
alternative: a carved file **renumbers**, and the whole value of acting on a
per-line report is that line 12 is still line 12.

The held-back lines are **counted and reported**, exactly as `--from-line`'s and
the blank ones are — a summary that quietly narrowed what it was summarising
would be worse than no summary.

A spec is read strictly, and a bad one is a `2` rather than a fallback to the
whole file — which is the one outcome a selector exists to prevent. `--lines 0`,
`--lines 5-2`, `--lines abc`, `--lines 12-`, an empty spec and an empty entry
(`3,,5`) are all refused, naming what was wrong. Whitespace *between* entries is
fine (`3, 7`); inside one it is a typo, not a range (`5 - 7` is refused).

**`--lines` and `--from-line` do not combine** — giving both is a `2`:

```
specguard-ingest: error: --from-line and --lines both choose which lines to send; give one or the other
```

They answer the same question, and intersecting them would silently drop a
number you typed: `--from-line 5 --lines 3,7` would send only line 7, and the 3
would vanish without a word. Refusing the pair is the same discipline as the
rest of this command — it will not quietly narrow what it was asked for.

Repeating **one** selector is a different case and is allowed: the last one
wins. `--lines 1,2 --lines 4` sends line 4, and `--from-line 2 --from-line 5`
starts at 5. A repeat replaces rather than intersects, so the set delivered is
exactly the last one you typed — nothing is combined into something smaller than
you asked for, which is the objection to the pair above. It is also what lets
you override a selector baked into a wrapper script or shell alias by appending
a new one.

Nothing about a line's **content** is consulted by either flag. The numbers come
from you, after reading `--list`; that is what keeps this an explicit selector
rather than the heuristic this command refuses to grow.

Each line is delivered **once** — the command runs out of band and costs your CI
nothing, but a retry loop cannot see *why* an attempt failed and you can, so
re-running the command is the retry.

**A dry run is never in the file**, so nothing here can replay one: the
formatter refuses both sinks for `rspec --dry-run` (see above), which means this
command inherits that guarantee rather than re-checking it.

The exit code is the contract, and it is `specguard-lint`'s:

| Code | Meaning |
| --- | --- |
| `0` | every line was accepted |
| `1` | at least one line was **refused by the endpoint** — it read the payload and said no, with its own reasons rendered exactly as the formatter renders them |
| `2` | the command could not do its job — no endpoint or API key, an unreadable file, an unparseable line, a bad flag, or a delivery the platform never stored |

`1` is reachable only by the endpoint having read a payload and said no, which
is an **HTTP 400** and nothing else: that is the one response SpecGuard forms an
opinion about your run in. A `401` is answered before the request reaches the
code that would read the payload; a `404`, `429` or `5xx` never gets that far
either. **Nothing was stored in any of them**, so all of them are a `2` — as are
a connection refused, a DNS failure and a timeout. Reporting any of these as a
`1` would be the command telling you your suite is bad on the strength of a
rotated key, a typo in `SPECGUARD_ENDPOINT`, or a bad afternoon at the platform.
Note what that buys you: `1` means *fix the payload*, `2` means *fix the setup
or try again later*, and a `404` and an unset `SPECGUARD_ENDPOINT` — the same
mistake — give you the same code. When a file produces both, `2` wins, and every
line is still printed either way.

`--list` sits outside that table's `1`, and outside most of its `2`: it makes no
request, so no endpoint has read anything and there is no verdict to report. A
listing exits `0` or `2` only, and the only `2`s it can reach are a bad flag and
a file it could not read. The other causes in that row are delivery's, not
listing's — listing needs no `SPECGUARD_ENDPOINT` and no `SPECGUARD_API_KEY`,
and an unparseable line becomes a row in the listing that names it rather than
an exit code.

**What it will not tell you** is whether a replayed line *created* a new run or
*folded into* an existing one. The ingest endpoint's `202` carries the run's id
but no created-versus-updated flag, so the command reports what it can see: the
`test_run_id` that came back, and whether the line carried a `ci_run_id` of its
own. Two lines that went out with the same `ci_run_id` and came back with the
same `test_run_id` landed on one record — that is the sentence above, and it is
an observation rather than an inference.

Bulk-importing an aged archive is **not** what this is for. The payload carries
no execution timestamp and SpecGuard orders a repository's runs by when they
were ingested, so a replayed run becomes the repository's latest. For the case
this exists to serve — replay the run that just failed, right after fixing the
credential — that is correct.

#### Machine-readable output — `--json`

An HTTP `400` is the one **permanent** verdict in the table above: a refused line
is refused every time it is offered, so the only way to land the run is to learn
which specs SpecGuard objected to and fix the payload. It names **every** one of
them — one error per offending spec, by index, file and line — and the human
report has room for three:

```
line 3: refused — HTTP 400 — the endpoint rejected the payload — specs[417] spec/models/user_spec.rb:88: duration must be a non-negative number when present; specs[418] …; specs[419] … and 19997 more
```

That cap is right where it is: it exists for the **one stderr line** an in-run CI
warning is allowed, and the formatter still has to fit inside it. It is a cap on
a *line*, though, and `--json` is the other channel — stdout carries one JSON
document instead of the human report, with the whole list in it:

```bash
bundle exec specguard-ingest --json log/test_results.jsonl
```
```json
{
  "tool": "specguard-ingest",
  "mode": "deliver",
  "file": "log/test_results.jsonl",
  "summary": { "lines": 3, "attempted": 3, "accepted": 2, "refused": 1,
               "undelivered": 0, "unparseable": 0, "blank": 0, "skipped": 0,
               "selector": null },
  "lines": [
    { "number": 1, "status": "accepted", "code": 202, "reasons": [],
      "test_run_id": "41f2c9b8", "ci_run_id": "17442" },
    { "number": 2, "status": "accepted", "code": 202, "reasons": [],
      "test_run_id": "41f2c9b8", "ci_run_id": "17442" },
    { "number": 3, "status": "refused", "code": 400, "test_run_id": null,
      "ci_run_id": "17443",
      "reasons": [
        "specs[417] spec/models/user_spec.rb:88: duration must be a non-negative number when present",
        "specs[418] spec/models/user_spec.rb:96: duration must be a non-negative number when present"
      ] }
  ],
  "foldings": [
    { "ci_run_id": "17442", "test_run_id": "41f2c9b8", "lines": [1, 2] }
  ]
}
```

| field | meaning |
| --- | --- |
| `tool` | always `"specguard-ingest"`. Deliberately **not** a schema id: this document is about deliveries, and `specguard-lint --json` is the one that mirrors `validate-intent`'s |
| `mode` | `"deliver"` or `"list"` — whether the lines were sent or only shown |
| `file` | the path you gave it, echoed back |
| `summary.lines` | rows in `lines`: the lines that carried a payload and were not held back by a selector |
| `summary.attempted` | how many of those were offered to the endpoint — always `0` under `--list`, and `lines` minus the unparseable ones otherwise |
| `summary.accepted` / `refused` / `undelivered` / `unparseable` | the same four counts the text summary line states, computed once for both renderers so they cannot disagree |
| `summary.blank` / `skipped` | the two ways a line of the file is not a row here, counted rather than dropped |
| `summary.selector` | `"--lines"`, `"--from-line"`, or `null` when nothing was held back |
| `lines[]` | one entry per row, in the file's order |
| `foldings[]` | folding, **observed**: the lines that went out with one `ci_run_id` and came back with one `test_run_id`. The same statement the text report makes as a sentence |

Every delivered line has the same six keys:

| field | meaning |
| --- | --- |
| `number` | its 1-based line number in the file **as given**, blank lines counted — so it is the number `--from-line` and `--lines` take |
| `status` | `accepted`, `refused`, `undelivered` or `unparseable`. The tool's own vocabulary, not the report's wording (`undelivered`, where the row prints `not delivered`) |
| `code` | the HTTP status, or **`null`** where there is not one: a line that was never a run, and a delivery that got no answer at all (connection refused, DNS, TLS, a timeout) |
| `reasons` | why the line did not land — **always** a list of strings, never null and never a bare string, so a consumer never branches on its type. SpecGuard's own per-spec errors on a refusal (all of them, in its order), the parse problem where the line was not a run, the error where nothing reached the endpoint, and `[]` where it landed or where the refusal's body said nothing readable |
| `test_run_id` | the run the line landed on, as the endpoint reported it; `null` where that cannot be said honestly |
| `ci_run_id` | the run identity the line carried, or `null` — the field to read for, because a line without one has nothing for SpecGuard to fold a redelivery onto |

Every listed line has the same eight keys — `number`, `status` and `reasons`, as
on a delivered line, and then the five envelope facts the text row prints
instead of a delivery's outcome:

| field | meaning |
| --- | --- |
| `number` | its 1-based line number in the file **as given**, blank lines counted — the same number as on a delivered line, and the one `--from-line` and `--lines` take |
| `status` | `listed`, or `unparseable` where the line could not be parsed as a run — the two outcomes a preview has, since nothing was sent |
| `reasons` | the parse problem on an `unparseable` row, and `[]` on a `listed` one — **always** a list of strings, never null and never a bare string, so a consumer never branches on its type. It is the only field that says *why* a previewed line is unusable |
| `branch` | the branch the line carried, or **`null`** where the row says `no branch` |
| `commit_sha` | the commit the line carried, or **`null`** |
| `ci_run_id` | the run identity the line carried, or **`null`** where the row says `no ci_run_id` — the field to read for here too |
| `examples` | how many examples the line carried, or **`null`** where the row says `no specs`. `0` and `null` stay different facts, exactly as `0 examples` and `no specs` do |
| `duration_seconds` | the run's duration, or **`null`** where the row says `no duration_seconds` |

`--list --json` needs no `SPECGUARD_ENDPOINT` and no `SPECGUARD_API_KEY`,
exactly as `--list` does, and it previews the same set by the same numbers a
delivery would send.

Four things worth knowing:

- **The exit code is identical with and without the flag**, and the default
  output is unchanged. `--json` is a second renderer over the same lines, the
  same statuses and the same counts — pinned that way, byte for byte, in
  `spec/specguard/rspec/regression_targets_spec.rb`.
- **`--json` does not lift the cap on the human line.** The two channels render
  the same refusal at different lengths on purpose; nothing about the formatter's
  in-run warning moves.
- **A run that never got as far as reading the file emits no document.** A bad
  flag, `--from-line` with `--lines`, no endpoint or API key, a file that cannot
  be read — all still exit `2` with prose on stderr and **nothing** on stdout,
  because there is nothing yet to be a document about. A file the command *did*
  read always gets one, whatever the exit code, including an empty one.
- **Warnings stay on stderr**, in both renderers. A run that delivered nothing is
  still loud there; stdout is the document and nothing else.

### If you shard your suite

`parallel_tests`, Knapsack and a CI matrix all run the suite as several
processes, and each one loads this formatter and POSTs its own slice. The run id
is what tells SpecGuard those POSTs are **one run**: shards that share it are
accumulated onto a single record, so a 20,000-example suite reports a 20,000
denominator instead of one record per shard holding a quarter of it — and a
quarter is what the dashboard showed before, attributed to the right commit,
with nothing to mark it as partial.

Every supported provider publishes an id for the build (`GITHUB_RUN_ID`,
`CI_PIPELINE_ID`, `CIRCLE_WORKFLOW_ID`, `BUILDKITE_BUILD_ID`, `BUILD_TAG`), so a
sharded job on any of them needs no configuration. If you shard somewhere else,
export one yourself — any value that every shard of the run shares and no other
run repeats:

```bash
export SPECGUARD_RUN_ID="$MY_CI_BUILD_ID"
```

Unset is not an error. A run with no id is treated as a run of its own, which is
exactly right for `bundle exec rspec` on a laptop. A genuinely different run — a
nightly, a later push — gets a different id from its provider and stays a
separate record, which is why the commit alone cannot do this job.

#### Re-runs, and why each shard also names itself

A CI run id does **not** change when you re-run the build. GitHub's own wording
for `GITHUB_RUN_ID` is *"This number does not change if you re-run the workflow
run"*; Buildkite retries a job inside the same `BUILDKITE_BUILD_ID` and GitLab
inside the same `CI_PIPELINE_ID`. That is the behaviour SpecGuard wants — press
"re-run failed jobs" on a sharded suite and only the failed shards run again, so
they need to land back on the run they came from rather than forming a new run
holding a fifth of the suite.

For that to be right, a shard has to be able to *replace* its own earlier
numbers instead of adding to them, which means naming itself. SpecGuard reads
the shard index your runner already exports:

| Runner | Variable |
| --- | --- |
| `parallel_tests` | `TEST_ENV_NUMBER` (its blank first process is read as shard `1`) |
| GitLab `parallel:`, Knapsack Pro | `CI_NODE_INDEX` |
| CircleCI `parallelism:` | `CIRCLE_NODE_INDEX` |
| Buildkite `parallelism:` | `BUILDKITE_PARALLEL_JOB` |

**GitHub Actions `matrix:` is the one that needs a line of config.** It exports
no per-leg index — `GITHUB_JOB` is the job's id in your YAML and is identical
across every leg — so set it from the matrix value:

```yaml
strategy:
  matrix:
    shard: [1, 2, 3, 4]
steps:
  - run: bundle exec rspec
    env:
      SPECGUARD_SHARD_ID: ${{ matrix.shard }}
```

The value only has to be unique *within one run*; it is never compared across
runs. Do the same if you nest — `parallel_tests` inside a matrix leg repeats
`TEST_ENV_NUMBER` across legs, so give `SPECGUARD_SHARD_ID` something that
composes both.

Leaving it unset is not an error and does not lose the slice: an unnamed shard
is still counted into the run. What it cannot do is be recognised on a second
delivery, so if that shard is retried its numbers are added again rather than
replacing what was there. If your suite shards and you re-run it, name the
shards.

## What SpecGuard collects

Everything below is the whole of it. `Transport#deliver` sends the payload
verbatim — there is no filtering layer between what the formatter captures and
what leaves the machine — so this list *is* the request body, and a spec pins
it so that adding a field without updating this section fails the build. A run
big enough to be worth compressing is gzipped in transit; that changes how the
body is encoded on the wire, never what is in it.

**The run envelope — six fields, once per process:**

| Field | What it holds | Where it comes from |
| --- | --- | --- |
| `commit_sha` | the commit the suite ran against | `SPECGUARD_COMMIT_SHA` if you set it, else `GITHUB_SHA`, `CI_COMMIT_SHA`, `CIRCLE_SHA1`, `BUILDKITE_COMMIT`, `GIT_COMMIT`, else `git rev-parse HEAD` |
| `branch` | the branch name; `null` on a detached checkout | `SPECGUARD_BRANCH` if you set it, else `GITHUB_REF_NAME`, `CI_COMMIT_REF_NAME`, `CIRCLE_BRANCH`, `BUILDKITE_BRANCH`, `GIT_BRANCH`, else `git symbolic-ref --short -q HEAD` |
| `ci_run_id` | your provider's build id, so shards of one run fold together; `null` on a laptop | `SPECGUARD_RUN_ID` if you set it, else `GITHUB_RUN_ID`, `CI_PIPELINE_ID`, `CIRCLE_WORKFLOW_ID`, `BUILDKITE_BUILD_ID`, `BUILD_TAG` |
| `shard_id` | which slice of that run this process is; `null` when unsharded | `SPECGUARD_SHARD_ID` if you set it, else `TEST_ENV_NUMBER`, `CI_NODE_INDEX`, `CIRCLE_NODE_INDEX`, `BUILDKITE_PARALLEL_JOB` |
| `duration_seconds` | wall clock for the whole run | measured by the formatter |
| `specs` | one object per example that finished — the nine fields below | the run |

**Each example — nine fields, one object per example, annotated or not:**

| Field | What it holds | Where it comes from |
| --- | --- | --- |
| `id` | RSpec's own example id, `./spec/orders_spec.rb[1:2]` — the re-run argument | `example.id` |
| `spec_file_path` | the spec file that **ran** the example, relative to the project root when it lives under it — an absolute path when it does not, because a spec outside the working directory has no relative name | `metadata[:rerun_file_path]` |
| `file_path` | the spec file the example is **defined** in, on the same terms | `metadata[:file_path]` |
| `line_number` | the line it is defined on | `metadata[:line_number]` |
| `name` | the composed `describe`/`context`/`it` string | `example.full_description` |
| `duration` | seconds that one example took | `execution_result.run_time` |
| `outcome` | `passed`, `failed` or `pending` | `execution_result.status` |
| `status` | `annotated` or `unannotated` | whether an `@intent:` was found for that line |
| `intent` | the parsed `@intent:` annotation; `null` when there is none | the annotation you wrote in the spec file |

Two request headers say something about you rather than about the request: the
API key travels as a bearer token in `Authorization`, and `User-Agent` names
this gem and its version (`specguard-ruby/<version>`), so the platform can tell
its clients apart. The rest are ordinary HTTP plumbing that describe the message
itself and carry nothing about your code or your suite — `Content-Type`,
`Accept`, `Content-Length`, `Host`, `Accept-Encoding`, and `Content-Encoding:
gzip` on a run large enough to be compressed. A spec pins that header set too,
so a header added later cannot quietly slip past this paragraph.

### Test names and annotations are free text, and that is the point

`name` and `intent` are written by your developers, in prose; `file_path` and
`spec_file_path` are the names they gave the files. They **will** carry internal
product detail — feature names, customer names, the shape of work you have not
shipped — because a suite describes the system it tests.

The paths are the one part of this that is not authored but **machine-derived**,
and it is worth knowing where that can go further than you meant. A spec under
the project root reports a project-relative name and nothing more. A spec run
from *outside* it has no relative name, so its real location is what travels —
`/home/build-agent-07/…`, `/var/lib/jenkins/workspace/acme-payments-nightly/…` —
in `spec_file_path`, in `file_path`, and in `id`, which is that same path plus a
position. Ordinary suites never hit this; a spec vendored outside the tree, a
shard splitter that expands its arguments to absolute paths, or an IDE runner
will. That discloses a build machine's directory layout, which is a different
category from prose, so it is named here rather than folded into the paragraph
above.

SpecGuard is built on that and cannot be built without it. The product answers
"what does this suite actually cover, and where are the gaps" — a question whose
entire input is what your tests say they cover. A mode that shipped anonymised
coordinates would not be a lighter SpecGuard; it would be a SpecGuard that
cannot answer anything. So there is no opt-out, no field-level redaction and no
name-scrubbing switch, and none is planned. This is a deliberate product
decision, stated here so you can make yours.

### If this cannot leave your perimeter, run SpecGuard inside it

Self-hosting is the supported answer, and it needs no code change — point
`SPECGUARD_ENDPOINT` at your own deployment and every byte described above goes
there instead:

```bash
export SPECGUARD_ENDPOINT=https://specguard.internal.example.com
```

### What is never collected

- **No source code.** Not your application's, and not your tests' — no example
  body, no `let`, no fixture, no diff of any of it.
- **No failure messages and no backtraces.** A failing example contributes the
  string `failed` and nothing else; the exception, its message and its stack
  stay on your machine.
- **No test output.** Nothing your suite printed to stdout or stderr, and
  nothing any other formatter wrote, is read or forwarded.
- **No environment.** SpecGuard's own code reads a fixed list of variables and
  no others: the ones named in the envelope table above, which fill
  `commit_sha`, `branch`, `ci_run_id` and `shard_id`; plus four that configure
  the gem itself rather than describing your suite — `SPECGUARD_ENDPOINT` (where
  to send the run), `SPECGUARD_OUTPUT_PATH` (where to write the replay queue —
  runs the endpoint refused or could not be reached for), `SPECGUARD_LOCAL_OUTPUT_PATH`
  (where to write the local development record when there is no key),
  `SPECGUARD_TIMEOUT` (how long to wait), and
  `SPECGUARD_API_KEY`, which leaves the machine only as the bearer token
  described above. The other three are never sent, and there is no general
  environment capture to be caught by. (The linter is a separate program that
  sends nothing at all; it reads two variables of its own —
  `SPECGUARD_VALIDATE_INTENT` to name a validator binary, and
  `SPECGUARD_CACHE_DIR` to redirect its download cache — documented above. On a
  first run with neither cache nor variable set it fetches the validator
  binary from open-test-intent's GitHub release, over HTTPS, and nothing else.)
- **One exception, and it is about the route rather than the contents: your
  proxy settings are read.** Sending the run goes through Ruby's `Net::HTTP`,
  which resolves a proxy from the environment the way every Ruby HTTP client
  does — so if your network requires a proxy, the run takes it, without
  SpecGuard being told about it. `http_proxy` (or `HTTP_PROXY`) is the variable
  that does it, **including for an `https://` endpoint**: `Net::HTTP` resolves
  the proxy against an `http` URL whatever the transport, which means setting
  only `https_proxy` will *not* proxy your run. `no_proxy` (or `NO_PROXY`)
  suppresses it per host. In a CGI environment (`REQUEST_METHOD` set)
  `CGI_HTTP_PROXY` is read instead and the uppercase spelling is ignored. None
  of these is ever transmitted, and none of them changes a byte of what is sent
  — they decide only **where it goes**, which is worth knowing alongside
  *"If this cannot leave your perimeter, run SpecGuard inside it"* above, since
  `SPECGUARD_ENDPOINT` is not the only thing that determines the destination.

---

<p align="center">
  <a href="https://yatfa.com">
    <img src="assets/built-with-yatfa.png" alt="Built with yatfa — a team of AI agents that plans, builds &amp; ships software." width="100%">
  </a>
</p>
