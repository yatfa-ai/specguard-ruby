# frozen_string_literal: true

# The formatter half of the client gem: it watches an RSpec run and records
# every example that finished — its name, where it lives, how long it took and
# how it ended — as one JSON object per run.
#
# == Why this file is not on `require "specguard/rspec"`'s chain
#
# `rspec` is a **development** dependency of this gem, not a runtime one
# (specguard-ruby.gemspec declares exactly one runtime dependency: `json`,
# pinned; since SPGD-867 the validator arrives as a resolved binary rather
# than as a gem). `bin/specguard-lint` loads `specguard/rspec`, and it has to
# keep working for someone who installed the gem to lint annotations on a
# machine with no RSpec at all. Putting `require "rspec/core"` on that chain
# would turn a missing test framework into a broken linter.
#
# So the formatter is opt-in, by its own path:
#
#   # spec/spec_helper.rb
#   require "specguard/rspec/formatter"
#   RSpec.configure { |config| config.add_formatter(SpecGuard::RSpecFormatter) }
#
#   # ...or, equivalently, in .rspec
#   --require specguard/rspec/formatter
#   --format SpecGuard::RSpecFormatter
#
# Neither form names a human formatter, and neither has to: see {#seed} for how
# the one RSpec would have installed is kept, why registering this class would
# otherwise take it away, and {#message} for the second listener that keeping it
# would otherwise leave on the stream.
#
# The `--require` is not optional in the `.rspec` form: RSpec resolves a
# `--format` argument by constant lookup and only then guesses a file name to
# require, and the name it guesses for this class is `spec_guard/r_spec_formatter`.
#
# spec/specguard/rspec/formatter_loading_spec.rb pins the separation in both
# directions.
require "rspec/core"
require "rspec/core/formatters/base_formatter"
require "json"
require "fileutils"

require_relative "configuration"
require_relative "transport"
# Brings the linter's discovery chain with it (Scanner, Finding, Schema). That
# direction is safe — `specguard/rspec` does not require `rspec/core`, so the
# linter stays loadable without RSpec; it is only the reverse that would break
# packaging.
require_relative "annotation_lookup"

module SpecGuard
  # == A NOTE ON CONSTANT RESOLUTION — read this before editing
  #
  # `SpecGuard::RSpec` is *this gem's own namespace*. Inside a `module SpecGuard`
  # body an unqualified `RSpec::Core::Formatters` therefore resolves to
  # `SpecGuard::RSpec::Core::Formatters` and dies with
  # `NameError: uninitialized constant SpecGuard::RSpec::Core` — on the very
  # first line of the class definition, before anything else can go wrong.
  #
  # Every reference to the real RSpec below is consequently top-level-qualified
  # with `::`. It is also why this class is `SpecGuard::RSpecFormatter`, a
  # *sibling* of `SpecGuard::RSpec` rather than a member of it: the sibling name
  # keeps the two namespaces from shadowing each other for readers as well as
  # for the interpreter.
  #
  # == What it captures, and for whom
  #
  # Every example, annotated or not — but not because an unannotated test is
  # anonymous. The row below carries `full_description` and both paths
  # unconditionally, so a test nobody annotated still arrives named and
  # located; its duration and its outcome ride along whenever the runner
  # reported them, which is why both are written safe-navigated below. The
  # protocol says the same thing in its preamble: annotated and unannotated
  # tests are alike ingested — see `PROTOCOL.md` in open-test-intent, above
  # "1. Annotation syntax".
  #
  # What an `@intent` adds is a *structured, authored* statement of what the
  # test is for — fields a machine can group and compare, and a layer and
  # preconditions that a description does not state — written deliberately
  # rather than read off prose composed for a test runner's output. So the
  # gap an annotation closes is one of structure, not of sight.
  #
  # That gap is still one you cannot report on over rows you never recorded,
  # which is why this formatter captures the whole run: filtering to the
  # annotated minority here would make the very first run of a new adopter
  # look empty.
  #
  #   id              example.id — this example's identity within the run
  #   spec_file_path  the spec file that *ran* the example, relative to the root
  #   file_path       example.metadata[:file_path], relative to the project root
  #   line_number     example.metadata[:line_number]
  #   name            example.full_description — the composed describe/context/it
  #   duration        example.execution_result.run_time, seconds, per example
  #   outcome         example.execution_result.status — passed / failed / pending
  #   status          "annotated" / "unannotated" — see {AnnotationLookup}
  #   intent          the parsed annotation when annotated, null when not
  #
  # `status` is not decoration: `Ingest::Payload` validates it against a
  # two-value enum for *every* spec and collects the failures globally, so a
  # payload missing the key is not a payload with a gap — it is a 400 with one
  # error per example.
  #
  # == Why `id` and `spec_file_path` exist alongside the coordinate
  #
  # `(file_path, line_number)` is the coordinate of the **code**, not of the
  # **example**, and two entirely ordinary suite shapes put several examples on
  # one coordinate:
  #
  #   * a table-driven loop — `CASES.each { |c| it("...#{c}") { ... } }` writes
  #     the `it` once, so all N examples report the same line;
  #   * a shared example group — every including file reports the coordinate of
  #     `spec/support/shared.rb`, and the file that actually ran the example
  #     appears nowhere at all.
  #
  # Measured on a probe suite of a 3-case loop plus a 2-example shared group
  # included by two files: 7 examples, 3 distinct coordinates. A key that folds
  # three examples onto one row cannot carry a per-example duration, cannot
  # follow one test's outcome across runs, and hands the duplicate-cluster
  # surface rows that look identical because the *key* collapsed them — a
  # manufactured duplicate in the product's headline answer.
  #
  # RSpec already ships the fix. `Example#id` is
  # `"#{metadata[:rerun_file_path]}[#{metadata[:scoped_id]}]"`
  # (rspec-core 3.13.6, `example.rb:117` → `metadata.rb:105`), it is rooted at
  # the *including* file rather than the defining one, and it is also RSpec's
  # own re-run argument — so a row that turns up slow or flaky is directly
  # actionable: `rspec './spec/table_spec.rb[1:2]'`.
  #
  # **`id` is unique within a run, not stable across refactors.** `scoped_id` is
  # positional, so reordering examples changes it — exactly as `line_number`
  # changes when a line is inserted above it. It is the run-local primary key
  # and nothing more; matching one test across runs remains `name` plus file.
  #
  # `spec_file_path` is `metadata[:rerun_file_path]`, which RSpec defaults to
  # the defining file (`metadata.rb:160`) and overrides with the *including*
  # file for a shared example. It is therefore equal to `file_path` for an
  # ordinary example and differs only for a shared one — which is what makes
  # duration-by-file aggregate to the file that ran the test rather than to a
  # `spec/support/` helper.
  #
  # `file_path` and `line_number` keep their existing meaning — the definition
  # site — and are deliberately not repurposed: the annotation lookup reads
  # `@intent:` from exactly that line, so they are the coordinate the intent
  # came from.
  #
  # == Where the run goes
  #
  # `api_key` set  → one `POST <endpoint>/api/v1/ingest`.
  # `api_key` unset → appended to `local_output_path`, one JSON object per
  #                   line — a local development record, not a replay queue.
  # delivery refused → appended to `output_path`, the replay queue.
  #
  # The credential is the switch on purpose: local development is then the
  # default and needs no opt-out. See {#deliver} for what happens when the POST
  # does not land.
  #
  # A malformed or schema-invalid annotation is recorded as `unannotated` with a
  # null intent rather than shipped or shouted about; {AnnotationLookup}
  # documents why, and the linter is the half of this gem that tells the author.
  #
  # == The never-block-CI contract, and why it lives *here*
  #
  # SpecGuard's non-negotiable is that telemetry never fails a build. It is
  # tempting to read that as a property of the *transport* — a rescue around
  # the POST — but RSpec does not sandbox formatters, so it is a property of
  # the **capture layer** too. A raise in any of the three hooks below escapes
  # `RSpec::Core::Runner.run` entirely; RSpec's own exit code is then never
  # returned at all, and the process exits 1. Probed against rspec-core 3.13.6:
  #
  #   hook=example_finished  process_exit=1  rspec's exit status: never reached
  #   hook=stop              process_exit=1  rspec's exit status: never reached
  #   hook=close             process_exit=1  rspec's exit status: never reached
  #
  # In the `close` case the suite had already printed `2 examples, 0 failures`
  # and the process still exited 1 — a green suite turned red by telemetry. A
  # `nil` line number, an unwritable `log/`, a full disk: each of those is
  # somebody's broken build, for tests that all passed.
  #
  # {#seed} was added after that probe and is guarded for the same reason, with
  # the stakes slightly higher: it is dispatched from `Reporter#start`, before
  # any example has run, so a raise there costs the whole suite rather than its
  # exit code.
  #
  # So every hook body runs inside {#never_fail_the_run}, which swallows
  # `StandardError` *and* `ScriptError` (an autoload blowing up is not a
  # StandardError, and a bare rescue would miss it), warns once, and returns.
  # `Interrupt`, `SignalException` and `SystemExit` are deliberately not caught:
  # Ctrl-C must stay Ctrl-C.
  #
  # spec/specguard/rspec/formatter_spec.rb fails if any of those rescues is
  # removed.
  class RSpecFormatter < ::RSpec::Core::Formatters::BaseFormatter
    # `:seed` and `:message` are not hooks this formatter has anything to say
    # about; both are here for the *human* half of the output.
    #
    # `:seed` is the earliest notification of a run, and {#seed} uses it as the
    # moment to repair RSpec's default-formatter suppression.
    #
    # `:message` is registered for the sake of the registration itself.
    # `setup_default` installs a `FallbackMessageFormatter` unless some already
    # registered formatter listens for `:message` (`formatters.rb:133-135`, via
    # `existing_formatter_implements?` → `reporter.registered_listeners`), and
    # that fallback would then print every message a *second* time alongside the
    # formatter {#seed} restores. Listening here suppresses it and takes over its
    # job — see {#message}, which is that same fallback under this class's roof.
    ::RSpec::Core::Formatters.register self, :example_finished, :stop, :close, :seed, :message

    # Prefixed so it is obvious in a CI log which tool is talking, and worded so
    # a reader knows immediately that it is not their tests that broke.
    WARNING_PREFIX = "SpecGuard: test telemetry failed and was skipped"

    # The other half of that: the run was captured fine, the *delivery* did not
    # land. Kept distinct from {WARNING_PREFIX} because the reader's situation
    # is different — nothing was lost, the payload is sitting in a file, and the
    # thing to fix is a key or a URL rather than a broken sink.
    DELIVERY_WARNING_PREFIX = "SpecGuard: could not deliver test telemetry"

    # The third shape, and the only one that reports a *deliberate* refusal
    # rather than something going wrong. Nothing failed and nothing is
    # recoverable from a file, because there was nothing worth keeping — see
    # {#dry_run?}. It still gets said out loud: a user who wired the formatter
    # up and then saw neither a POST nor a line would otherwise have to go
    # looking for a bug that is not there.
    DRY_RUN_WARNING_PREFIX = "SpecGuard: skipped test telemetry for a dry run"

    # The refusal in full, as its own constant rather than a string built at the
    # call site, because {#skip_dry_run} now needs it in two places: appended to
    # with the coverage figures on the happy path, and emitted bare as the
    # fallback if building those figures raises. The fallback is therefore
    # *exactly* the line this formatter has always printed, which is what makes
    # "the report failed" degrade to "the old behaviour" rather than to silence.
    DRY_RUN_REFUSAL =
      "#{DRY_RUN_WARNING_PREFIX} (rspec --dry-run executes no example bodies, so " \
      "this run's durations and outcomes would not be measurements). " \
      "Nothing was sent or written; the test run is unaffected."

    # The report's indentation. Deliberately *not* `SpecGuard:`-prefixed: a run
    # emits exactly one line carrying that prefix, so a reader scanning a CI log
    # for "did SpecGuard have anything to say" gets one hit per run and not one
    # hit per unannotated example. `formatter_run_spec.rb` pins that contract.
    REPORT_INDENT = "  "
    WORKLIST_INDENT = "    "

    # `Ingest::Payload::STATUSES`, restated. The platform validates every spec
    # against this pair, so they are the contract and not a local naming choice.
    STATUS_ANNOTATED = "annotated"
    STATUS_UNANNOTATED = "unannotated"

    # The published formatter-protocol methods that mean "this formatter tells a
    # human what the suite did", as opposed to RSpec's own auxiliaries, which
    # speak only about deprecations and timings. {#reports_the_run?} is where
    # this set is justified, and where the `respond_to?` approximation's limits
    # are written down.
    REPORTS_THE_RUN = %i[
      example_started example_passed example_failed example_pending dump_summary
    ].freeze

    # @param output [IO] the stream RSpec hands every formatter. This class's
    #   product is a file, so nothing in the capture path writes here — but the
    #   stream is *not* unused, and a reader who is here because stdout went
    #   wrong is in the right place. {#message} writes to it, via
    #   {#relay_message} below: having taken over the `FallbackMessageFormatter`
    #   RSpec would otherwise have appointed, this formatter owes that
    #   formatter's duty, and printing a message no other registered formatter
    #   will print is precisely its job. That is the only write.
    #
    #   The `nil` default has no caller. RSpec always supplies a stream, and the
    #   two direct constructions in the repo — both in `formatter_spec.rb` —
    #   pass one explicitly, so nothing exercises it. It survives because
    #   narrowing a public constructor's signature is not this slice's business,
    #   not because anything depends on it. It cannot reach
    #   `output.puts`: {#relay_message} returns early unless this object is in
    #   `RSpec.configuration.formatters`, which only RSpec puts it in, and doing
    #   so means RSpec built it. A `nil` that somehow got there would raise
    #   inside {#never_fail_the_run} and downgrade to a warning rather than
    #   taking the suite with it.
    # @param error_stream [IO] where the one-shot warning goes. Injectable so a
    #   spec can read it back without reassigning `$stderr` globally.
    # @param annotations [AnnotationLookup] resolves each example's `@intent:`.
    #   One per run: it is where the per-file scan is memoized, so sharing it
    #   across the run is what makes the cost O(files) rather than O(examples).
    #
    #   Fully qualified for the same reason every `::RSpec` above is — and it is
    #   the same trap seen from the other side. This class is a *sibling* of
    #   `SpecGuard::RSpec`, not a member, so a bare `AnnotationLookup` here is
    #   looked up as `SpecGuard::RSpecFormatter::AnnotationLookup` and then
    #   `SpecGuard::AnnotationLookup`, neither of which exists — a NameError
    #   raised from a formatter's constructor, which RSpec reports as
    #   "No examples found".
    def initialize(output = nil, error_stream: $stderr,
                   annotations: SpecGuard::RSpec::AnnotationLookup.new)
      super(output)
      @error_stream = error_stream
      @annotations = annotations
      @specs = []
      @warned = false
      # Stamped here rather than from a `start` hook on purpose. `:start` is not
      # in this formatter's own registered set — it arrives only because
      # BaseFormatter registered for it — and the wall clock a CI operator cares
      # about includes loading the spec files, which happens before `start`
      # fires. `duration_seconds` is therefore a superset of RSpec's own
      # "Finished in N seconds", not a contradiction of it.
      @started_at = monotonic_now
      @duration_seconds = nil
    end

    # The first notification of the run — and the one hook here that exists for
    # the *human* half of the output rather than the telemetry half.
    #
    # == The defect this repairs
    #
    # RSpec installs its own default formatter only if the user registered no
    # formatter at all (rspec-core 3.13.6,
    # `lib/rspec/core/formatters.rb:127`):
    #
    #   add default_formatter, output_stream if @formatters.empty?
    #
    # Registering *this* formatter makes that list non-empty, so `progress` is
    # never added — and since this formatter's product is a file, the run prints
    # **nothing**. Measured on `formatter_run_spec.rb`'s `MIXED_SUITE`: ~900
    # bytes of stdout without SpecGuard, **0** with it. No dots, no failure
    # message, no diff, no `file:line`, no re-run command, and still exit 1. The
    # telemetry was written perfectly (1 line, all 3 specs); the developer was
    # left blind.
    #
    # (Two rules for the byte counts in this class's comments, both learned the
    # hard way. **Name the suite** — they come from different ones and are not
    # comparable across methods; this paragraph's and {#reports_the_run?}'s are
    # `MIXED_SUITE`, {#message}'s are `NON_EXAMPLE_ERROR_SUITE`, both defined in
    # `formatter_run_spec.rb`. And **prefer a delta or a count to a total**: a
    # total carries the run's wall-clock digits, so it is not reproducible even
    # on the same suite — `MIXED_SUITE`'s control measured 955 and 956 bytes on
    # consecutive invocations, and `NON_EXAMPLE_ERROR_SUITE`'s 333 through 335.
    # Hence the `~` above, and hence the figures that carry the argument
    # elsewhere are deltas — 0, a 27-byte hole, one error block versus two.)
    #
    # It hit exactly the wrong person. The `.rspec` wiring escaped it only
    # because the README spelled it with a second `--format progress` line, and
    # a developer who explicitly chose `--format documentation` was unaffected —
    # so the casualty was the reader who followed the README's first wiring
    # block and customised nothing. (That `--format progress` line is gone from
    # the README now: with this repair in place neither documented form needs
    # it, which is what finally makes the two forms equivalent.)
    #
    # == Why here, and not in the user's `spec_helper`
    #
    # The obvious repair — `config.add_formatter(:progress) if
    # config.formatters.empty?` inside `RSpec.configure` — is wrong, and
    # silently so. `configuration_options.rb:21-25` applies `--require` (i.e.
    # `spec_helper.rb`) *before* `--format`, so at that moment the list is `[]`
    # no matter what the user asked for. Probed directly: with `.rspec` set to
    # `--format documentation`, `config.formatters` still returns `[]` inside
    # the helper. That repair gives the documentation user documentation *and*
    # progress dots.
    #
    # `:seed` is the first notification `Reporter#start` sends
    # (`reporter.rb:92`, ahead of `:start` on :93), and `Reporter#notify` runs
    # `ensure_listeners_ready` — hence `setup_default` — before dispatching
    # anything (`reporter.rb:207-208`). So by the time this runs, RSpec has
    # finished deciding, and the decision can be read rather than predicted.
    # Repairing here rather than in `start` is what keeps the output
    # byte-identical: a formatter added during `:seed` still receives `:start`,
    # and the only notification it misses *from `Reporter#start` onwards* is
    # this one, which is forwarded to it by hand below. (Not "the only
    # notification it misses" flatly — a `:message` can arrive before
    # `Reporter#report` is ever entered, which is a real case and is {#message}'s
    # to handle, not this method's.)
    #
    # The forwarding is not decoration, and it is worth knowing what goes if it
    # goes: `:seed` is what prints `Randomized with seed N`, so without it a
    # randomly-ordered run loses its *head* banner and keeps only the one RSpec
    # re-sends at the end (`reporter.rb:189`). That is the line a developer
    # needs to reproduce a flaky failure. Measured on `MIXED_SUITE` under
    # `--order random`: banner twice both with and without this gem, and once if
    # the forwarding loop is deleted (a 27-byte hole, the banner and its blank
    # line). Under RSpec's *defined* ordering nothing prints a banner either
    # way, which is why the parity example that pins this had to ask for random
    # ordering explicitly.
    #
    # Arriving late is not the only way the restored formatter can diverge from
    # one RSpec installed itself, and the second way cost a review round. By the
    # time it is added, `setup_default` has already decided that nobody handles
    # `:message` and installed a `FallbackMessageFormatter` to cover for it — so
    # the newcomer, which does handle `:message`, became the *second* listener on
    # that notification and every message printed twice. Measured on
    # `NON_EXAMPLE_ERROR_SUITE`: one error block without SpecGuard, two with it
    # (~335 bytes against ~546). {#message} is the fix, and it works
    # by making `setup_default`'s premise true rather than by undoing its
    # conclusion — there is no public way to withdraw a registered listener.
    #
    # == What counts as "the human formatter is missing"
    #
    # Not "the list is empty" — by now `setup_default` has appended RSpec's own
    # `DeprecationFormatter` (and a `ProfileFormatter` under `--profile`). The
    # question is whether any *other* registered formatter will give a human an
    # account of the run, so that is what is asked: does it respond to any of
    # `example_started`, `example_passed`, `example_failed`, `example_pending` or
    # `dump_summary`? See {#reports_the_run?} for why that set, and for what the
    # `respond_to?` approximation can and cannot see.
    #
    # Nothing here touches anything rspec-core marks `@private`: `formatters`,
    # `add_formatter` and `default_formatter` are documented public API, and
    # every method name in that set is part of the published formatter protocol
    # (`formatters/protocol.rb`).
    #
    # `default_formatter` rather than a hard-coded `:progress`, for the same
    # reason: a user who set `config.default_formatter = 'doc'` asked for that,
    # and it is the value rspec-core's own line would have used.
    def seed(notification)
      never_fail_the_run { restore_suppressed_default_formatter(notification) }
    end

    # `RSpec::Core::Formatters::FallbackMessageFormatter`, moved inside this
    # class — the other half of {#seed}'s repair, and the one that stops it
    # printing everything twice.
    #
    # == Why this method has to exist at all
    #
    # `setup_default` ends with (`formatters.rb:133-135`):
    #
    #   unless existing_formatter_implements?(:message)
    #     add FallbackMessageFormatter, output_stream
    #   end
    #
    # Somebody must print `reporter.message` output — a `--seed` banner, "No
    # examples found.", and every non-example exception, since
    # `notify_non_example_exception` routes through it (`reporter.rb:163-170`).
    # `progress` and `documentation` do it via `BaseTextFormatter#message`; when
    # no registered formatter listens for `:message`, RSpec appoints a fallback.
    #
    # Before this method, this class did not listen for `:message`, so the
    # fallback was always appointed — and then {#seed} added `progress`, which
    # listens for it too. Two listeners, one stream, every message twice. On
    # `NON_EXAMPLE_ERROR_SUITE` the error block printed once without SpecGuard
    # and twice with it, which is the claim that matters and the one the spec
    # asserts; the streams were ~335 and ~546 bytes.
    #
    # The fallback cannot be withdrawn once appointed: `Reporter#register_listener`
    # has no inverse, and `Configuration#formatters` hands back a `dup`
    # (`configuration.rb:1024-1026`), so deleting from it changes nothing. The
    # repair is therefore to stop it being appointed — this class listens for
    # `:message`, `existing_formatter_implements?(:message)` is true, and the
    # duty lands here instead.
    #
    # == When it actually prints
    #
    # Only when it is the last resort, which is exactly the fallback's own
    # contract: if any *other* registered formatter handles `:message`, that one
    # prints and this stays quiet. So the wirings behave identically to a run
    # without this gem — `progress` prints it under the README's Ruby form once
    # {#seed} has restored it, `documentation` prints it for a developer who
    # asked for documentation, `json` swallows it into its hash exactly as it
    # does on its own, and `--format html` (which has no `message`) gets it from
    # here, just as it would have got it from the fallback.
    #
    # The check is made per message rather than cached, because a message can
    # arrive **before** `:seed`: `Runner#setup` calls `world.announce_filters`,
    # which reports "No examples found." through `reporter.message` before
    # `Reporter#report` is ever entered. In that window this formatter really is
    # the only listener, and it prints — which is what the fallback would have
    # done.
    #
    # `respond_to?` is the public-API approximation of the question rspec-core
    # answers with `registered_listeners(:message)`; {#reports_the_run?}
    # documents how the two can differ. For `:message` specifically they agree
    # across every formatter rspec-core ships, because the only classes that
    # define `message` are the ones that register it.
    def message(notification)
      never_fail_the_run { relay_message(notification) }
    end

    # One example finished — passed, failed or pending. Called for every
    # example in the run, in the order they complete.
    def example_finished(notification)
      never_fail_the_run { @specs << capture(notification.example) }
    end

    # The suite is over but the process is still alive. Sealing the duration
    # here rather than in `close` keeps the number from absorbing the time the
    # other formatters spend dumping their summaries.
    def stop(_notification)
      never_fail_the_run { @duration_seconds = elapsed_since_start }
    end

    # Last hook of the run: flush what we captured.
    #
    # `super` restores the output stream's sync setting, which BaseFormatter
    # changed on our behalf at `start` (a notification it registers for, and so
    # one this subclass receives too). Overriding `close` without calling it
    # would leave stdout unbuffered for whatever runs next in the process.
    def close(notification)
      never_fail_the_run do
        @duration_seconds ||= elapsed_since_start
        deliver(payload)
      end
      never_fail_the_run { super(notification) }
    end

    # The run, as it will be written or POSTed. Public so a caller — or a spec
    # — can inspect what was captured without going anywhere near the
    # filesystem or the network.
    #
    # Key names match the platform's ingest contract
    # (`Ingest::Payload`: commit_sha / branch / ci_run_id / duration_seconds /
    # specs), which is what made adding transport a transport change rather
    # than a reshaping of everything above it. {Transport} sends this Hash
    # verbatim.
    #
    # `ci_run_id` is the field that keeps a sharded suite honest: every shard of
    # one CI run emits the same one, and the platform folds them onto a single
    # `TestRun` instead of recording one row per shard with a quarter of the
    # denominator in it. `nil` here — a laptop run, an unrecognised
    # provider — means "this run is its own run", which is the pre-existing
    # behaviour and is left exactly alone.
    #
    # `shard_id` says *which* slice of that run this is, and it is what makes
    # the fold idempotent. A CI run id survives a re-run by design (GitHub's
    # `GITHUB_RUN_ID` is documented as unchanged across attempts), so without a
    # per-shard key the platform could only add a re-delivered slice, never
    # recognise it, and "re-run failed jobs" would report a suite bigger than
    # the suite. With it, a retried shard replaces its own previous numbers.
    # `nil` is allowed and still counts — see {Configuration::SHARD_ID_KEYS}.
    #
    # The settings are `run_id` / `shard_id` and the wire fields are
    # `ci_run_id` / `shard_id`, deliberately.
    # Configuration names are this gem's own (`SPECGUARD_RUN_ID`, next to
    # `output_path` and `endpoint`); every key in *this* Hash is the platform's,
    # spelled exactly as `TestRun` spells it. That rule is what lets a reader
    # check the envelope against the schema without a translation table — and a
    # run identity that two sides spell differently is one more way to split a
    # run, which is the whole defect this field closes.
    #
    # @return [Hash]
    def payload
      configuration = SpecGuard::RSpec.configuration

      {
        "commit_sha" => configuration.commit_sha,
        "branch" => configuration.branch,
        "ci_run_id" => configuration.run_id,
        "shard_id" => configuration.shard_id,
        "duration_seconds" => @duration_seconds,
        "specs" => @specs
      }
    end

    private

    # {#seed}'s body. Adds RSpec's default formatter when registering this one
    # suppressed it, and hands the newcomer the notification it arrived too late
    # to receive.
    #
    # The `equal?(self)` guard on the first line is not defensive padding: it is
    # what keeps this method inert outside a real run. `spec/.../formatter_spec.rb`
    # drives these hooks in-process against a formatter that RSpec never
    # registered, and without the guard each of those examples would bolt a
    # progress formatter onto the *parent* suite's live configuration. If this
    # object is not in `RSpec.configuration.formatters`, nothing here is its
    # business.
    def restore_suppressed_default_formatter(notification)
      configuration = rspec_configuration
      registered = configuration.formatters
      return unless registered.any? { |formatter| formatter.equal?(self) }
      return if registered.any? { |formatter| reports_the_run?(formatter) }

      configuration.add_formatter(configuration.default_formatter)
      configuration.formatters.each do |formatter|
        next if registered.any? { |already| already.equal?(formatter) }

        formatter.seed(notification) if formatter.respond_to?(:seed)
      end
    end

    # {#message}'s body: print, but only as the last resort.
    #
    # The `equal?(self)` guard is the same inertness guard
    # {#restore_suppressed_default_formatter} carries, for the same reason — this
    # object only owes anybody a message because RSpec registered it and skipped
    # appointing its own fallback. A formatter RSpec never registered (the
    # in-process examples in `spec/.../formatter_spec.rb`) owes nothing and
    # writes nothing.
    def relay_message(notification)
      registered = rspec_configuration.formatters
      return unless registered.any? { |formatter| formatter.equal?(self) }
      return if registered.any? { |formatter| relays_messages?(formatter) }

      output.puts notification.message
    end

    # The live RSpec configuration, behind a method so a spec can hand this
    # object a stand-in. Stubbing `::RSpec.configuration` itself is not an
    # option: rspec-core reads it throughout the example it is running, so the
    # double gets asked things like `dry_run?` and the example dies inside
    # RSpec rather than inside this class.
    #
    # The `::` is load-bearing and this is the only place it can be wrong.
    # Inside `module SpecGuard` a bare `RSpec.configuration` reaches *this
    # gem's* Configuration, which has no `dry_run?` — see {#dry_run?} for what
    # that costs. Keeping every reader of the real configuration funnelled
    # through this one method is what gives that hazard a single site to be
    # pinned by a test, and formatter_spec.rb pins it with an `equal`
    # assertion against `::RSpec.configuration`.
    def rspec_configuration
      ::RSpec.configuration
    end

    # Whether `formatter` is somebody else's account of the run — i.e. anything
    # but this formatter that will tell a human what the suite did.
    #
    # == Why this set of methods
    #
    # It is the late-run translation of the condition rspec-core evaluates at
    # `formatters.rb:127`, `@formatters.empty?`. That runs *before* RSpec appends
    # its own auxiliaries, so "empty" there means "the user named no formatter";
    # by the time {#seed} can look, the list also holds a `DeprecationFormatter`
    # (and a `ProfileFormatter` under `--profile`). What separates those from
    # every formatter a user can name is that they speak only about deprecations
    # and timings — never about an example, never about the outcome of the run.
    #
    # So the question is asked in exactly those terms. Checked against the
    # formatters rspec-core ships: `progress`, `documentation` and `html` answer
    # on the `example_*` methods, `json` on `dump_summary`, `--format failures`
    # (`FailureListFormatter`) on `example_failed`; `DeprecationFormatter`,
    # `FallbackMessageFormatter` and `ProfileFormatter` answer on none of them.
    #
    # `dump_summary` alone is *not* enough, and shipping it alone was a bug. A
    # suite run with `--format failures` prints one line per failure and no
    # summary, so a `dump_summary`-only question read it as "nobody is reporting"
    # and bolted a whole progress run onto an explicitly chosen formatter.
    # Measured on `formatter_run_spec.rb`'s `MIXED_SUITE`: 61 bytes of failure
    # list became ~963 bytes of dots, backtrace and summary. That
    # is the additive promise broken in the same breath as it is kept.
    #
    # == What `respond_to?` cannot see
    #
    # rspec-core answers the structurally identical question with
    # `@reporter.registered_listeners(notification).any?` (`formatters.rb:207-209`)
    # — *registration*, not method presence. That is the more accurate question
    # and it is deliberately not the one asked here: `registered_listeners` is
    # `@private` (`reporter.rb:51`), and this repair is worth nothing if a minor
    # rspec-core bump can silence a suite with it.
    #
    # The approximation is not free, and it is worth knowing which way it errs. A
    # formatter that *inherits* one of these methods from `BaseTextFormatter`
    # while registering only a subset of notifications reads as an account of the
    # run and never receives one — so the default is not restored and the run is
    # quiet, which is this ticket's own defect one level in. Nothing rspec-core
    # ships is shaped that way (every class that defines one of these registers
    # it), and a third-party formatter would have to inherit `BaseTextFormatter`
    # specifically to avoid printing. The reverse error — a formatter that prints
    # under some other method name, so the default is restored alongside it — is
    # noisy rather than silent, and is the direction to prefer if this ever has
    # to be re-tuned.
    def reports_the_run?(formatter)
      return false if formatter.equal?(self)

      REPORTS_THE_RUN.any? { |method_name| formatter.respond_to?(method_name) }
    end

    # Whether `formatter` is somebody else's `:message` handling — the question
    # {#message} asks before deciding it is the last resort. See {#message}.
    def relays_messages?(formatter)
      !formatter.equal?(self) && formatter.respond_to?(:message)
    end

    # Sink selection, and the fallback that keeps a failed delivery from being
    # a silent one.
    #
    # Called from inside {#never_fail_the_run}, so nothing below has to guard
    # itself against raising — including the fallback `append`, whose own
    # failure modes (unwritable `log/`, full disk) are already covered there.
    #
    # == Why a failure writes the file rather than shrugging
    #
    # "Never block CI" is a promise about the *exit code*, not a licence to
    # discard the run. A 401 with no file left behind loses the whole run's
    # telemetry for a mistake — a rotated key, a typo'd URL — that is fixed in
    # thirty seconds and cannot be re-run afterwards, because the suite is over.
    # Writing the payload to the replay queue turns silent loss into recoverable
    # loss, which is the same thing `output_path` already exists for ("supports
    # a future replay-from-file ingestion path").
    #
    # == And the one case that goes to neither sink
    #
    # A dry run is refused outright — no POST, no line. It is the exception to
    # the paragraph above because there is nothing to recover: the run measured
    # nothing, so keeping it is not preserving telemetry, it is manufacturing
    # it. {#dry_run?} has the argument in full.
    def deliver(data)
      return skip_dry_run if dry_run?

      configuration = SpecGuard::RSpec.configuration
      return append_local(data) if blank?(configuration.api_key)

      obstacle = undeliverable_reason(configuration, data)
      return fall_back(data, obstacle) if obstacle

      result = transport_for(configuration).deliver(data)
      return if result.success?

      fall_back(data, result.reason)
    end

    # The checks worth doing *before* spending the run's wall clock on a request
    # whose answer is already known.
    #
    # `commit_sha` is the sharp one: `Ingest::Payload#validate_commit_sha`
    # refuses a blank one and the controller renders 400, so the run would be
    # discarded whole — every example, not merely the empty field. Ten seconds
    # of CI time to be told that is pure loss, and the operator learns more from
    # being told *why* than from being shown the platform's rejection.
    #
    # @return [String, nil] nil when there is nothing standing in the way.
    def undeliverable_reason(configuration, data)
      if blank?(configuration.endpoint)
        return "an API key is set but no endpoint is (set SPECGUARD_ENDPOINT)"
      end

      return unless blank?(data["commit_sha"])

      "the commit could not be determined, and the endpoint rejects a run without one " \
        "(set SPECGUARD_COMMIT_SHA)"
    end

    # Is RSpec executing example bodies at all?
    #
    # == Why a dry run must not be delivered
    #
    # `rspec --dry-run` walks the suite, builds every example and reports each
    # one as `passed`, without running a single body. The two per-example fields
    # this formatter exists to report are therefore both fabrications:
    # `duration` is the cost of constructing an example (single-digit
    # microseconds against the pinned rspec-core 3.13.6 — a `sleep 0.05`
    # example understates its own runtime by three to four orders of magnitude)
    # and `outcome` is `passed` for code that never executed.
    #
    # Nothing downstream can tell. The payload carries no dry-run marker,
    # `Ingest::Payload` validates neither field, and `Repository#latest_test_run`
    # is last-writer-wins — so one lint job that runs `rspec --dry-run` with an
    # environment-level `SPECGUARD_API_KEY` in scope replaces the suite's
    # headline with all-green zeroes that look exactly like a fast, healthy
    # suite.
    #
    # The local sink gets the same refusal for the same reason: a `.jsonl` of
    # zero-duration all-green runs is the identical corruption, deferred until
    # something replays it.
    #
    # == The `::` is load-bearing — do not remove it
    #
    # This is the class-body hazard documented at the top of `module SpecGuard`,
    # in its worst form. Inside this namespace a bare `RSpec.configuration`
    # resolves to `SpecGuard::RSpec.configuration` — *this gem's* Configuration,
    # whose accessors are `commit_sha`, `branch`, `run_id`, `shard_id`,
    # `output_path`, `endpoint`, `api_key` and `timeout`, and which has no
    # `dry_run?`. Note that four methods here — {#payload}, {#deliver},
    # {#append} and {#warn_delivery_failure} — legitimately call
    # `SpecGuard::RSpec.configuration` for this gem's own settings, so both
    # spellings appear in this file and mean different things.
    #
    # The mis-spelling's consequence depends on the `respond_to?` below, and
    # both halves were measured by mutating {#rspec_configuration} and running
    # `bundle exec rspec` (601 examples on the tree this landed on):
    #
    #   bare `RSpec`, respond_to? kept     this gem's Configuration answers
    #                                      `respond_to?(:dry_run?) => false`, so
    #                                      every run is treated as ordinary and
    #                                      the defect this method closes is
    #                                      silently reinstated. 23 fail
    #                                      suite-wide; the one that names *this*
    #                                      cause rather than a downstream
    #                                      symptom is formatter_spec.rb's
    #                                      "reads the real RSpec's
    #                                      configuration, not this gem's
    #                                      same-named one". The other 22 are
    #                                      symptoms: 4 further dry-run ones, and
    #                                      18 from the message relay, which
    #                                      reads this same method for
    #                                      `.formatters`.
    #   bare `RSpec`, respond_to? removed  NoMethodError inside `close`'s
    #                                      {#never_fail_the_run}, swallowed — a
    #                                      formatter that delivers *nothing*, on
    #                                      every run, behind one warning line,
    #                                      while the suite still passes. 110
    #                                      fail suite-wide.
    #
    # Both totals are whole-suite figures and will move with any edit anywhere
    # in the tree; the named example above is the durable half of the claim.
    #
    # So `respond_to?` is not only there for an RSpec build without the
    # predicate: it is what keeps a mis-spelling from escalating into deleting
    # all telemetry. Neither state is acceptable, and {#rspec_configuration}
    # gives the `::` exactly one place to be wrong and one place to be pinned —
    # formatter_spec.rb asserts it is `equal` to `::RSpec.configuration`, which
    # is the only assertion that names the cause rather than a downstream
    # symptom.
    def dry_run?
      configuration = rspec_configuration
      return false unless configuration.respond_to?(:dry_run?)

      configuration.dry_run?
    end

    # A dry run's one useful product, said out loud instead of thrown away.
    #
    # == Why there is anything to say at all
    #
    # {#capture} builds three fields side by side, and only two of them are
    # fabricated by a dry run. `duration` and `outcome` come from
    # `example.execution_result`, which under `--dry-run` describes a body that
    # never ran — that is the whole reason delivery is refused. But `status`
    # comes from {AnnotationLookup#intent_for}, which reads the *spec file* and
    # scans its text; it is a fact about source, identical whether or not
    # anything executed. A dry run builds every example, so it holds the exact
    # numerator and denominator of the product's headline adoption metric, and
    # until now discarded both.
    #
    # This adds a third destination the refusal never contemplated: the
    # operator's own terminal. Nothing is published — the POST and the
    # `log/test_results.jsonl` append stay refused, exactly as before.
    #
    # == "This working tree", never "your repository"
    #
    # The wording matters and is not decoration. The repository's headline
    # figure is derived from the last *delivered* run; this one is derived from
    # the files on disk right now. They legitimately differ the moment somebody
    # edits a spec — which is precisely the gap this exists to close — so the
    # line must not be confusable with the dashboard's number.
    #
    # == Why this does not go through {#emit_warning}
    #
    # The one-shot budget exists to stop a per-example failure printing
    # thousands of identical lines. Neither half of it fits here:
    #
    # * *Reading* it would let an earlier warning swallow the report. That is
    #   worst in the case where the report matters most: if the annotation
    #   scanner blew up, every example is classified `unannotated` and the
    #   coverage figure reads 0%. An operator must see the warning *and* the
    #   figure to know the figure is explained by the failure rather than by
    #   their specs.
    # * *Spending* it would silence a genuine later warning to buy a line that
    #   was never a warning in the first place. Nothing went wrong here.
    #
    # It cannot flood, either — it is emitted once, from {#deliver}, at `close`.
    #
    # Building the report is wrapped so that a failure degrades to the bare
    # refusal this formatter has always printed, and the write is wrapped so a
    # dead stream is still not worth failing a run over ({#emit_warning} makes
    # the same trade). The never-block-CI contract is not suspended by a
    # reporting feature.
    #
    # Both rescues are *behaviour*, not decoration, so both are pinned by an
    # example that fails if they are removed or emptied:
    #
    # * the inner one degrades to the refusal rather than to silence — which is
    #   the whole reason {DRY_RUN_REFUSAL} is a constant — and "reports the
    #   refusal, and only the refusal, when the report cannot be built" asserts
    #   the emitted text *equals* it, so both emptying the fallback and
    #   swallowing it fail.
    # * the outer one keeps a dead stream from spending the run's one warning
    #   through `close`'s {#never_fail_the_run}. Without it, a stream that
    #   failed here would consume the budget a *genuine* later failure needs,
    #   trading a line nobody could read for one somebody needed; "does not
    #   spend the run's one warning when the error stream is dead" pins it.
    def skip_dry_run
      lines =
        begin
          [dry_run_summary, *unannotated_worklist]
        rescue ScriptError, StandardError
          [DRY_RUN_REFUSAL]
        end

      lines.each { |line| @error_stream.puts(line) }
    rescue ScriptError, StandardError
      nil
    end

    # The single `SpecGuard:`-prefixed line of a dry run: the refusal, then the
    # coverage it was able to compute anyway.
    def dry_run_summary
      total = @specs.length
      unannotated = unannotated_specs.length
      annotated = total - unannotated

      "#{DRY_RUN_REFUSAL} #{coverage_sentence(total, annotated, unannotated)}"
    end

    def coverage_sentence(total, annotated, unannotated)
      if total.zero?
        return "No examples were built, so there is no annotation coverage " \
               "to report for this working tree."
      end

      "Annotation coverage is a fact about source, not about execution, so it " \
        "survives the refusal — this working tree: #{total} #{pluralize(total, 'example')}, " \
        "#{annotated} annotated, #{unannotated} unannotated " \
        "(#{annotated_percentage(annotated, total)}% annotated)."
    end

    # The same predicate the platform applies, spelled the same way round.
    #
    # `Ingest::Payload#annotated_specs` *rejects* `status == "unannotated"`
    # rather than selecting `"annotated"`, and `Ingest::ObservationRecorder`
    # writes that same string verbatim. Selecting on `STATUS_UNANNOTATED` here —
    # rather than on `STATUS_ANNOTATED`, which would read more naturally — is
    # what makes "local figure equals `total_specs - annotated_specs` for the
    # same tree" true *by construction* instead of true until one side drifts.
    def unannotated_specs
      @specs.select { |spec| spec["status"] == STATUS_UNANNOTATED }
    end

    # The worklist: the same four fields `latest_run.unannotated_examples`
    # serves server-side, so a local list and the dashboard's have one shape.
    #
    # Sorted by definition site rather than left in capture order, which under
    # `--order random` is a different sequence every run. A worklist you can
    # diff between two runs is worth more than one that mirrors execution.
    def unannotated_worklist
      specs = unannotated_specs
      return [] if specs.empty?

      sites = specs.map { |spec| ["#{spec['spec_file_path']}:#{spec['line_number']}", spec] }
                   .sort_by { |_site, spec| [spec["spec_file_path"].to_s, spec["line_number"].to_i] }
      width = sites.map { |site, _| site.length }.max

      heading = "#{REPORT_INDENT}the #{specs.length} unannotated " \
                "#{pluralize(specs.length, 'example')}, by definition site:"

      [heading] + sites.map do |site, spec|
        "#{WORKLIST_INDENT}#{site.ljust(width)}  #{spec['name']}"
      end
    end

    # Rounded, but never rounded *across* either boundary: 999 of 1000 must not
    # read `100% annotated`, and 1 of 1000 must not read `0%`. Both would say
    # the suite had reached — or had never left — a state it had not, which is
    # the one way a coverage figure actively misleads rather than merely
    # approximates.
    #
    # There is deliberately no `total.zero?` guard here. {#coverage_sentence}
    # already returns before reaching this, so a guard would be a branch no
    # input could reach — and an unreachable branch is one nothing can falsify,
    # which is exactly what the two clamps below are not. One zero-denominator
    # answer, in one place, pinned by "says there is nothing to measure rather
    # than dividing by zero".
    def annotated_percentage(annotated, total)
      percentage = (annotated * 100.0 / total).round
      return 99 if percentage >= 100 && annotated < total
      return 1 if percentage <= 0 && annotated.positive?

      percentage
    end

    def pluralize(count, noun)
      count == 1 ? noun : "#{noun}s"
    end

    def fall_back(data, reason)
      # Warned before the write, not after: if the fallback write *also* fails,
      # the outer guard's one allotted warning has already been spent on the
      # more specific message, which is the one naming the status code.
      warn_delivery_failure(reason)
      append(data)
    end

    def transport_for(configuration)
      SpecGuard::RSpec::Transport.new(
        endpoint: configuration.endpoint,
        api_key: configuration.api_key,
        timeout: configuration.timeout
      )
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def capture(example)
      metadata = example.metadata || {}
      result = example.execution_result
      file_path = relative_path(metadata[:file_path])
      line_number = metadata[:line_number]

      # Its own envelope, inside the one `example_finished` already provides.
      # The outer one drops the whole example; this one drops only its
      # annotation, so an unreadable spec file or a broken schema costs the run
      # the intent of the examples in it and not the examples themselves. It
      # also routes through {#warn_once}, so the operator hears about it exactly
      # once however many examples are affected.
      intent = never_fail_the_run { @annotations.intent_for(file: file_path, line: line_number) }

      {
        # Not wrapped in `never_fail_the_run`, unlike the annotation lookup
        # above. That guard is there because the lookup does file I/O; this is a
        # memoized string interpolation over a Hash RSpec has already built, and
        # a guard here could only ever add a way to emit an identity-less row
        # silently. The outer guard at `#example_finished` still covers it.
        "id" => example.id,
        # `|| file_path` rather than a bare read: RSpec defaults
        # `:rerun_file_path` for every example it builds, so the fallback is
        # unreachable in a real run — but if a producer ever hands us metadata
        # without it, the definition site is the best answer available and a
        # null would silently drop a whole file out of any by-file aggregate.
        "spec_file_path" => relative_path(metadata[:rerun_file_path]) || file_path,
        "file_path" => file_path,
        "line_number" => line_number,
        "name" => example.full_description,
        "duration" => result&.run_time,
        # A Symbol here would serialize fine but would compare unequal to the
        # string every consumer reads back out of JSON.
        "outcome" => result&.status&.to_s,
        "status" => intent.nil? ? STATUS_UNANNOTATED : STATUS_ANNOTATED,
        # Written explicitly rather than omitted. `Ingest::Payload#validate_intent`
        # accepts either for an unannotated spec (nil is nil whether the key was
        # absent or null), and a present null is the difference
        # between "we looked and there was no annotation" and "this producer
        # does not report annotations", which is precisely what slice 1's
        # payload could not say.
        "intent" => intent
      }
    end

    # RSpec reports `./spec/orders_spec.rb` for a file under the working
    # directory and an absolute path for one outside it. Reuse RSpec's own
    # definition of "relative to the project root" rather than inventing a
    # second one, then drop the `./` so the value matches what a linter, a
    # `git diff --name-only` and the platform all use as a file's identity.
    def relative_path(path)
      return nil if path.nil?

      string = path.to_s
      return nil if string.empty?

      (::RSpec::Core::Metadata.relative_path(string) || string).sub(%r{\A\./}, "")
    end

    # Appends one line. Opened in append mode and written with a single call so
    # that two suites sharing an output path (parallel CI shards, say) interleave
    # whole runs rather than halves of one.
    def append(data)
      path = SpecGuard::RSpec.configuration.output_path
      append_to(data, path)
    end

    # The keyless branch's sink: `local_output_path`, a local development
    # record deliberately kept apart from {#append}'s replay queue so that
    # `specguard-ingest log/test_results.jsonl` re-delivers only genuine
    # failed deliveries. See {Configuration#local_output_path}.
    def append_local(data)
      append_to(data, SpecGuard::RSpec.configuration.local_output_path)
    end

    def append_to(data, path)
      directory = File.dirname(path)
      FileUtils.mkdir_p(directory) unless directory == "." || File.directory?(directory)

      File.open(path, "a") { |file| file.write("#{JSON.generate(data)}\n") }
    end

    # `Errno::*` and `IOError` — the sink's failure modes — are both
    # `StandardError` descendants, so they need no separate clause; they are
    # named in the ticket because they are the *reason* this rescue is here, not
    # because Ruby files them somewhere unusual.
    def never_fail_the_run
      yield
    rescue ScriptError, StandardError => e
      warn_once(e)
      nil
    end

    # Once per run. A formatter that warned per example would bury the failure
    # output of the suite it is supposed to be reporting on under thousands of
    # identical lines — which is its own way of breaking somebody's CI.
    def warn_once(error)
      emit_warning("#{WARNING_PREFIX} (#{error.class}: #{error.message}). The test run is unaffected.")
    end

    # The delivery half, through the same one-shot budget so a run still emits
    # at most one line however many things went wrong. `reason` names the HTTP
    # status when there was one — a 400 and a 401 call for entirely different
    # actions, and a warning that only said "delivery failed" would leave the
    # reader unable to tell which.
    def warn_delivery_failure(reason)
      path = SpecGuard::RSpec.configuration.output_path

      emit_warning("#{DELIVERY_WARNING_PREFIX} (#{reason}). " \
                   "Falling back to #{path}; the test run is unaffected.")
    end

    def emit_warning(line)
      return if @warned

      @warned = true
      @error_stream.puts(line)
    rescue ScriptError, StandardError
      # The warning stream itself is gone. There is nothing left to say, and
      # saying it is not worth failing the run over.
      nil
    end

    def elapsed_since_start
      (monotonic_now - @started_at).round(6)
    end

    # Monotonic: immune to an NTP correction landing mid-suite, which on the
    # wall clock can produce a negative duration.
    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
