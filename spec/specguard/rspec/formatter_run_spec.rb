# frozen_string_literal: true

require "tmpdir"
require "open3"
require "fileutils"

# {FormatterRunHelpers::HERMETIC_ENV} derives itself from this class's key
# lists. `specguard/rspec` deliberately does not require it (see the comment on
# its own require list), and `spec_helper` loads only that — so naming it here
# is what makes this file safe to run alone, or under `--order random`, rather
# than dependent on some other spec having pulled it in first.
require "specguard/rspec/configuration"

require_relative "../../support/stub_ingest_endpoint"
require_relative "../../support/validator_stub"

# Everything the out-of-process examples need, in a namespace of its own —
# a bare `LIB_DIR = ...` inside an `RSpec.describe` block assigns at the
# *lexical* scope, which is top level, so it would define `::LIB_DIR` and
# `::Run` for the whole suite.
module FormatterRunHelpers
  extend self

  LIB_DIR = File.expand_path("../../../lib", __dir__)
  RSPEC_EXE = Gem.bin_path("rspec-core", "rspec")
  DEFAULT_SINK = "log/test_results.jsonl"

  # The seed handed to every `order: :random` child. Fixed, not drawn: a run and
  # its control have to order their examples the same way for a whole-stream
  # diff to mean anything, and the banner text itself is part of what is
  # compared. The value is arbitrary.
  FIXED_SEED = 4242

  # A passing, a failing and a pending example, nested two levels deep, and
  # carrying **zero** `@intent:` annotations — the roadmap's cold-start case,
  # and the one the payload must still describe completely.
  MIXED_SUITE = <<~RUBY
    RSpec.describe "user" do
      context "when signed in" do
        it "can order an item" do
          sleep 0.002
          expect(1 + 1).to eq(2)
        end

        it "cannot order an item that is out of stock" do
          sleep 0.002
          expect(:in_stock).to eq(:out_of_stock)
        end

        it "can cancel an order" do
          pending "cancellation is not built yet"
          sleep 0.002
          raise "not implemented"
        end
      end
    end
  RUBY

  GREEN_SUITE = <<~RUBY
    RSpec.describe "user" do
      it "can sign in" do
        expect(true).to be(true)
      end
    end
  RUBY

  # A suite whose only interesting output does not come from an example at all.
  #
  # An exception raised in an `after(:context)` hook is not an example failure —
  # `Reporter#notify_non_example_exception` formats it and sends it through
  # `reporter.message` (`rspec-core-3.13.6 reporter.rb:163-170`), the same
  # channel as the `--seed` banner and "No examples found.". That channel is
  # served by whichever formatter listens for `:message`, and by
  # `FallbackMessageFormatter` when none does — which makes it the one path that
  # can acquire a *second* listener without anybody noticing.
  #
  # It did. The first attempt at SPGD-195's repair added `progress` at `:seed`
  # without noticing that `setup_default` had already appointed the fallback
  # (because this formatter did not implement `message`), so both printed and
  # every message came out twice: one error block without SpecGuard, two with
  # it (~335 bytes against ~546 — the block count is the stable figure and the
  # one asserted below; the totals carry the run's wall-clock digits and move
  # by a byte or two between invocations). Every suite in this file up to that
  # point was a pure example suite with no message path at all, so nothing went
  # red — the same shape as the bug this file exists to pin, one level in.
  NON_EXAMPLE_ERROR_SUITE = <<~RUBY
    RSpec.describe "checkout" do
      after(:context) { raise "TEARDOWN-BLEW-UP" }

      it "totals the basket" do
        expect(1 + 1).to eq(2)
      end
    end
  RUBY

  # Every shape slice 2 has to classify, in one file:
  #
  #   line  3  preceding-comment annotation      -> annotated
  #   line  7  no annotation at all              -> unannotated
  #   line 11  same-line trailing annotation     -> annotated
  #   line 16  unterminated literal (malformed)  -> unannotated
  #   line 21  parses, but `entiity` is not a schema property -> unannotated
  #   line 27  annotated, nested inside a context -> annotated
  #
  # The nested one is not decoration: `metadata[:line_number]` is the `it` line
  # regardless of how deeply the example is nested, and an implementation that
  # reached for the describe's line instead would get every one of these wrong
  # while still producing a plausible-looking payload.
  ANNOTATED_SUITE = <<~RUBY
    RSpec.describe "user" do
      # @intent: { entity: "Order", action: "checkout", behavior: "returns 402 payment required on expired card", layer: "request" }
      it "can order an item" do
        expect(1 + 1).to eq(2)
      end

      it "has no annotation" do
        expect(1 + 1).to eq(2)
      end

      it "surfaces the decline reason" do # @intent: {entity:"Order",action:"refund",behavior:"restores stock levels when a paid order is refunded",layer:"unit"}
        expect(1 + 1).to eq(2)
      end

      # @intent: { entity: "Order", action: "total",
      it "has a malformed annotation" do
        expect(1 + 1).to eq(2)
      end

      # @intent: { entiity: "Order", action: "total", behavior: "sums line item prices after the discount", layer: "unit" }
      it "has a schema-invalid annotation" do
        expect(1 + 1).to eq(2)
      end

      context "when signed in" do
        # @intent: { entity: 'Order', action: 'cancel', behavior: 'releases the reserved stock on cancellation', layer: 'unit' }
        it "can cancel an order" do
          expect(1 + 1).to eq(2)
        end
      end
    end
  RUBY

  # The shape that separates "one line of lookback" from "one line of lookback,
  # comment form only". Line 4 carries a trailing annotation *and* an example;
  # line 5 carries a different example and no annotation at all. `it { ... }`
  # one-liners are idiomatic RSpec, so nothing here is contrived — a lookback
  # that ignored the form would report both as annotated, with the same intent,
  # and inflate the platform's annotated ratio with a purpose nobody declared.
  ONE_LINER_SUITE = <<~RUBY
    RSpec.describe "Order" do
      subject { 1 }

      it { is_expected.to eq(1) } # @intent: { entity: "Order", action: "checkout", behavior: "returns 402 payment required on expired card", layer: "request" }
      it { is_expected.to be_positive }
    end
  RUBY

  # A table-driven loop: the `it` is written once, on line 4, so all three
  # examples report the same `metadata[:line_number]`. Nothing here is
  # contrived — this is how anyone writes a parameterised case table, and under
  # a `(file_path, line_number)` key all three collapse onto one row.
  LOOP_SUITE = <<~RUBY
    RSpec.describe "Order" do
      [["visa", 200], ["expired", 402], ["stolen", 403]].each do |card, status|
        it "returns \#{status} for a \#{card} card" do
          expect(status).to be_positive
        end
      end
    end
  RUBY

  # A shared example group defined in `spec/support/shared.rb` and run from two
  # different spec files. Every one of the four examples is *defined* at the
  # same two coordinates, and `spec/support/shared.rb` is not a `*_spec.rb` at
  # all — so under the old key the two files that actually ran the tests appear
  # nowhere in the payload.
  SHARED_EXAMPLE_FILES = {
    "spec/support/shared.rb" => <<~RUBY,
      RSpec.shared_examples "a persisted record" do
        it "has an identifier" do
          expect(1).to be_positive
        end

        it "survives a reload" do
          expect(true).to be(true)
        end
      end
    RUBY
    "spec/orders_spec.rb" => <<~RUBY,
      require_relative "support/shared"

      RSpec.describe "Order" do
        it_behaves_like "a persisted record"
      end
    RUBY
    "spec/users_spec.rb" => <<~RUBY
      require_relative "support/shared"

      RSpec.describe "User" do
        it_behaves_like "a persisted record"
      end
    RUBY
  }.freeze

  # Makes the annotation lookup's one external dependency blow up, from inside
  # the child process, without touching lib/. Stands in for the family the
  # lookup cannot control: an unreadable spec file, a spec file that is not
  # valid UTF-8, a vendored schema that will not compile.
  SABOTAGE = <<~RUBY
    require "specguard/rspec"
    # SPGD-867: sabotage the LOOKUP, not the Scanner. The backend path answers
    # from the validator's report and never calls `Scanner.scan_text`, so a
    # scanner sabotage would now be dead code — the failure mode this block
    # pins is "the annotation half blows up", whatever layer it blows up in.
    # Runner is on the loaded chain (`specguard/rspec` requires it), and an
    # IOError here is outside the ValidatorError band AnnotationLookup rescues,
    # so it reaches the formatter envelope exactly as the scanner raise did.
    module SpecGuard::RSpec::ValidatorBackend
      class Runner
        def check(*) = raise(IOError, "sabotaged lookup")
      end
    end
  RUBY

  # The README's `RSpec.configure` wiring, copied out rather than paraphrased —
  # this is the block a reader pastes into `spec/spec_helper.rb`, and the point
  # of the `:ruby` wiring is that what runs here is what the README says. It
  # registers SpecGuard's formatter and *nothing else*, which is precisely the
  # condition SPGD-195 turned into a silent run.
  RUBY_WIRING = <<~RUBY
    require "specguard/rspec/formatter"

    RSpec.configure do |config|
      config.add_formatter(SpecGuard::RSpecFormatter)
    end
  RUBY

  # `sink_exists` is carried separately from `lines` because `lines` collapses
  # absent-and-empty into the same `[]`: without it, "the sink was never
  # created" and "the sink was created and left empty" are indistinguishable,
  # and only the former is the property SPGD-154 criterion 2 asks for.
  Run = Struct.new(:exit_status, :stdout, :stderr, :lines, :sink_exists, keyword_init: true) do
    def payload = JSON.parse(lines.last)
  end

  # Unset in every child unless an example asks for them. The formatter's
  # configuration seeds from the *real* ENV, so a developer or a CI job that
  # exported `SPECGUARD_API_KEY` for its own reasons would otherwise turn every
  # run below into an HTTP delivery — and each of these examples asserts on a
  # local file that would then never be written. `nil` deletes the variable in
  # the child (`Process.spawn`'s env contract).
  #
  # The provider variables below are here for the same reason, one level up: the
  # envelope's commit/branch/run/shard fields fall back to whichever CI exported
  # them, so a child inheriting the real job's `GITHUB_SHA` reports THAT commit
  # rather than the throwaway root's absence of one. Every example asserting on
  # those fields then passes on a laptop and fails on CI — which is exactly how
  # this list came to be written, when "the commit cannot be determined" turned
  # red on Actions and green everywhere else.
  #
  # The list is **derived**, not transcribed. Every variable the gem reads is
  # named in one of {SpecGuard::RSpec::Configuration}'s `*_KEYS` constants, and
  # enumerating those constants — rather than the four, or the eight, that
  # happened to exist the day this was written — means a newly declared list is
  # cleared here from the moment it exists, with no edit to this file.
  #
  # The hand-typed version drifted twice, and the second repair shipped a list
  # that was still incomplete: it was missing `SPECGUARD_OUTPUT_PATH`, which is
  # the variable {#run_rspec} resolves its *own* sink from. On a machine that
  # exported it the child wrote to the exported path while the assertions read
  # the default one, so every sink-asserting example here failed — green on a
  # laptop, red on that machine.
  #
  # The sibling list in `configuration_spec.rb` is spelled out by hand on
  # purpose and must stay that way: it *asserts* what the gem reads, and a pin
  # that derives from the thing it pins can never fail. This hash asserts
  # nothing — it is harness setup, and it wants to track the code silently.
  # That pin is also what keeps this derivation honest in the other direction:
  # it fixes the *set* of matching constants, so an unrelated future constant
  # ending in `_KEYS` fails there, by name, before it can quietly widen what
  # this clears.
  HERMETIC_ENV = SpecGuard::RSpec::Configuration
                 .constants.grep(/_KEYS\z/)
                 .flat_map { |list| SpecGuard::RSpec::Configuration.const_get(list) }
                 .to_h { |key| [key, nil] }
                 .freeze

  # Runs `rspec` as its own process in a throwaway project root, and reads back
  # everything an example might want to assert on before the root is removed.
  #
  # `--require` is not decoration: RSpec resolves `--format <constant>` by
  # constant lookup and only then guesses a path, and the path it guesses for
  # `SpecGuard::RSpecFormatter` is `spec_guard/r_spec_formatter`. RSpec
  # processes requires before it loads formatters, so this is the `.rspec`
  # incantation the README documents.
  #
  # == Why `wiring:` exists
  #
  # The README documents two ways to install this formatter, and for a long time
  # only one of them was ever run here. The default `:rspec_flags` wiring adds
  # `--format progress` on top of the `.rspec` block — which meant every example
  # in this file was *supplied* the human formatter by the harness, and the
  # "runs alongside progress rather than replacing it" guard below could not
  # fail no matter how badly the other wiring behaved. It did behave badly:
  # SPGD-195, where the README's Ruby form printed zero bytes for a failing
  # suite. (The README carried that same `--format progress` line at the time,
  # which is why the two documented wirings behaved differently at all; it is
  # gone from the README now that neither form needs it.)
  #
  # `:rspec_flags` keeps the explicit `--format progress` on purpose. It is the
  # "developer who named their own formatter" case, and it is what the other
  # ninety-odd examples in this file want: a run whose human output does not
  # depend on the repair being present.
  #
  # `:ruby` is the other documented form, written out verbatim — a
  # `spec_helper.rb` carrying nothing but
  # `config.add_formatter(SpecGuard::RSpecFormatter)`, with **no `--format`
  # argument at all**, so SpecGuard's is genuinely the only formatter anyone
  # registered. An assertion about human output is only worth something under
  # this wiring.
  #
  # `:none` is the control the other three are measured against: the same suite,
  # the same child process, no SpecGuard at all. Criterion 1 asks for output
  # "byte-comparable to the same suite without the formatter", and that is a
  # claim about two runs — a substring assertion cannot make it, and a hand-typed
  # expected string is just the fixture restating itself. See {#stdout_shape}.
  #
  # `:ruby_with_failure_list` is `--format failures`, and it is here because it
  # is the shape that catches an over-eager repair. `FailureListFormatter` prints
  # one line per failure and **no summary**, so a repair that asks "will anything
  # print a summary?" reads it as nobody reporting and bolts a whole progress run
  # onto a formatter the developer explicitly chose. Measured on `MIXED_SUITE`:
  # 61 bytes of failure list became ~963 bytes of dots, backtrace and summary.
  # `--format documentation`
  # cannot catch that — documentation does print a summary.
  #
  # @param suite [String, nil] the single-file case, written to `sample_spec.rb`.
  # @param wiring [Symbol] `:rspec_flags` (default) — the README's `.rspec`
  #   block plus an explicit `--format progress`; `:ruby` — the README's
  #   `RSpec.configure` block, and nothing else; `:ruby_with_documentation` —
  #   that same block from a developer who also asked for
  #   `--format documentation`; `:ruby_with_failure_list` — that same block from
  #   a developer who asked for `--format failures`; `:none` — no SpecGuard, the
  #   control; or `:failure_list_only` — `--format failures` without SpecGuard,
  #   the control for the one above.
  # @param files [Hash{String=>String}] additional files, by root-relative path.
  #   Intermediate directories are created. Every key matching `*_spec.rb` is
  #   passed to `rspec` as a target; anything else is a support file, reachable
  #   from a spec by `require_relative`. This is what lets a shared example group
  #   be exercised the only way it can be — defined in one file, run from two.
  # @param prepare [#call] optional hook, handed the project root, returning
  #   environment overrides for the child.
  # @param sabotage [Boolean] load {SABOTAGE} into the child before the
  #   formatter runs, so the annotation lookup's scanner raises.
  # @param order [Symbol, nil] `nil` (default) leaves the child on RSpec's
  #   defined ordering; `:random` runs it under `--order random --seed
  #   #{FIXED_SEED}`.
  #
  #   This exists because defined ordering hides a whole output path. Under it
  #   `seed_used?` is false and RSpec prints no seed banner, so every run this
  #   file spawned was blind to the one notification {#seed}'s repair has to
  #   forward by hand — see the random-ordering example in the parity block.
  #   The seed is fixed rather than drawn so that a run and its control order
  #   their examples identically and the whole-stream diff stays meaningful.
  # @param dry_run [Boolean] pass `--dry-run`, so RSpec builds and reports every
  #   example without executing a single body.
  # @return [Run]
  def run_rspec(suite = nil, wiring: :rspec_flags, files: {}, prepare: nil, sabotage: false,
                order: nil, dry_run: false)
    Dir.mktmpdir do |root|
      sources = suite ? { "sample_spec.rb" => suite }.merge(files) : files
      sources.each do |path, contents|
        full_path = File.join(root, path)
        FileUtils.mkdir_p(File.dirname(full_path))
        File.write(full_path, contents)
      end
      targets = sources.keys.grep(/_spec\.rb\z/)
      # SPGD-867: validation is the binary's job and resolution is default-on,
      # so the child process must find a validator. Point it at the offline
      # replay stub (see spec/support/validator_stub.rb) — the suite must not
      # download — and carry the stub script's own env, because capture3 with
      # an env hash REPLACES the environment rather than extending it.
      env = HERMETIC_ENV
              .merge(ValidatorStub.stub_env)
              .merge({ "SPECGUARD_VALIDATE_INTENT" => ValidatorStub.install_stubbable })
              .merge(prepare ? prepare.call(root) : {})

      case wiring
      when :rspec_flags
        requires = ["--require", "specguard/rspec/formatter"]
        formats = ["--format", "SpecGuard::RSpecFormatter", "--format", "progress"]
      when :ruby
        File.write(File.join(root, "spec_helper.rb"), RUBY_WIRING)
        requires = ["--require", "./spec_helper.rb"]
        formats = []
      when :ruby_with_documentation
        File.write(File.join(root, "spec_helper.rb"), RUBY_WIRING)
        requires = ["--require", "./spec_helper.rb"]
        formats = ["--format", "documentation"]
      when :ruby_with_failure_list
        File.write(File.join(root, "spec_helper.rb"), RUBY_WIRING)
        requires = ["--require", "./spec_helper.rb"]
        formats = ["--format", "failures"]
      when :none
        requires = []
        formats = []
      when :failure_list_only
        requires = []
        formats = ["--format", "failures"]
      else
        raise ArgumentError, "unknown wiring: #{wiring.inspect}"
      end

      if sabotage
        File.write(File.join(root, "sabotage.rb"), SABOTAGE)
        requires += ["--require", "./sabotage.rb"]
      end

      ordering =
        case order
        when nil then []
        when :random then ["--order", "random", "--seed", FIXED_SEED.to_s]
        else raise ArgumentError, "unknown order: #{order.inspect}"
        end

      stdout, stderr, status = Open3.capture3(
        env, RbConfig.ruby, "-I", LIB_DIR, RSPEC_EXE,
        *requires,
        *formats,
        *ordering,
        *(dry_run ? ["--dry-run"] : []),
        *targets,
        chdir: root
      )

      # SPGD-810: which file the child wrote depends on whether it had a key —
      # keyless runs land on the local sink, everything else (refusals,
      # undeliverable envelopes) on the replay queue. Resolving the harness's
      # sink the same way the child resolved its own is what keeps the
      # assertions reading the file that was actually written.
      keyless = env.fetch("SPECGUARD_API_KEY", nil).nil?
      default_sink = keyless ? "log/test_results.local.jsonl" : DEFAULT_SINK
      sink_var = keyless ? "SPECGUARD_LOCAL_OUTPUT_PATH" : "SPECGUARD_OUTPUT_PATH"
      sink = File.join(root, env.fetch(sink_var, default_sink) || default_sink)
      sink_exists = File.exist?(sink)
      lines = sink_exists ? File.readlines(sink, chomp: true) : []

      Run.new(exit_status: status.exitstatus, stdout: stdout, stderr: stderr, lines: lines,
              sink_exists: sink_exists)
    end
  end

  # Two runs' stdout, reduced to the part that is supposed to be equal.
  #
  # Criterion 1 is a claim about *two runs* — "byte-comparable to the same suite
  # without the formatter" — so it has to be asserted by comparing them, not by
  # matching substrings a passing implementation and a broken one both contain.
  # The duplicated-message regression is the case in point: every substring the
  # `:ruby` block asserted was still present when every message was printed
  # twice.
  #
  # Only the two wall-clock numbers are erased, because they are the only thing
  # that legitimately differs between two runs of the same suite (SpecGuard's
  # load time lands in "files took"). Everything else — dots, marks, ordering,
  # blank lines, and above all *how many times* each block appears — is compared
  # byte for byte.
  def stdout_shape(stdout)
    stdout.gsub(/[\d.]+ seconds/, "<t> seconds")
  end

  # Everything a child needs to POST to the stub. `commit_sha` is supplied
  # because the throwaway project root is not a git checkout — which is what
  # makes omitting it a *test case* rather than an accident (see "when the
  # commit cannot be determined").
  def transport_env(server, **overrides)
    {
      "SPECGUARD_ENDPOINT" => server.endpoint,
      "SPECGUARD_API_KEY" => "sgk_abc123",
      "SPECGUARD_COMMIT_SHA" => "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2",
      "SPECGUARD_BRANCH" => "main",
      "SPECGUARD_TIMEOUT" => "5"
    }.merge(overrides.transform_keys(&:to_s))
  end

  # A regular file where a directory has to go. Chosen over `chmod` on purpose:
  # these suites run as root in CI containers, and root ignores the permission
  # bits — a `chmod 0500` "unwritable path" is quietly writable again, and the
  # example passes without having tested anything.
  def blocked_sink
    lambda do |root|
      File.write(File.join(root, "blocker"), "not a directory")
      # SPGD-810: these keyless runs write the local sink, so that is the path
      # that has to be blocked for the write to fail.
      { "SPECGUARD_LOCAL_OUTPUT_PATH" => "blocker/test_results.jsonl" }
    end
  end
end

# `Ingest::Payload`'s per-spec rules, restated.
#
# The platform lives in another repository and this gem must not depend on it,
# so the contract is transcribed rather than imported — with the file:line it
# was transcribed from on every rule, which is the only thing that makes the
# copy auditable when the original moves.
#
# The transcription is verified: run against what this formatter writes, the
# real `app/services/ingest/payload.rb` — eval'd verbatim with only `present?`
# and `presence` shimmed — returns `valid?=true` with an empty error list, and
# derives `total_specs_count=6 annotated_specs_count=3`. Against slice 1's
# output, the same file returns one error *per spec*
# ("status must be one of annotated, unannotated") and the controller
# (`Api::V1::IngestsController#create`) renders 400 via `render_bad_request`.
#
# Note what the second probe also showed: without `status`, the platform's
# `Ingest::Payload#annotated_specs` — which *rejects* `"unannotated"` rather
# than selecting `"annotated"` — counted all six as annotated. So the field
# is not merely required; it is the one that stops the headline metric being
# 100% for a suite with no annotations in it at all.
module IngestContract
  STATUSES = %w[annotated unannotated].freeze # Ingest::Payload::STATUSES

  module_function

  # @return [Array<String>] one message per violated rule; empty means the
  #   platform would accept this spec entry.
  def errors_for(spec, index)
    label = "specs[#{index}]"
    errors = []

    # Ingest::Payload#validate_file_path
    unless spec["file_path"].is_a?(String) && !spec["file_path"].to_s.strip.empty?
      errors << "#{label}: file_path is required and must be a non-empty string"
    end

    # Ingest::Payload#validate_line_number
    unless spec["line_number"].is_a?(Integer) && spec["line_number"].positive?
      errors << "#{label}: line_number is required and must be a positive integer"
    end

    # Ingest::Payload#validate_status
    errors << "#{label}: status must be one of #{STATUSES.join(', ')}" unless STATUSES.include?(spec["status"])

    errors + intent_errors(spec, label)
  end

  # Ingest::Payload#validate_intent
  def intent_errors(spec, label)
    intent = spec["intent"]

    case spec["status"]
    when "annotated"
      return ["#{label}: intent is required when status is \"annotated\""] if intent.nil?
      return ["#{label}: intent must be a JSON object"] unless intent.is_a?(Hash)

      # `Ingest::Payload#validate_intent` calls `OpenTestIntent.validation_errors`
      # — the platform re-validates every annotated intent against the same
      # OpenTestIntent schema this gem vendors. SPGD-867 deleted the gem's
      # json_schemer loader (validation is the binary's job), so this
      # TEST-ONLY helper validates with json_schemer directly — a development
      # dependency, same as the offline validator stub.
      require "json_schemer"
      (@schemer ||= JSONSchemer.schema(JSON.parse(File.read(SpecGuard::RSpec::SCHEMA_PATH))))
        .validate(intent).to_a.map { |error| "#{label}: intent is invalid — #{error['error']}" }    when "unannotated"
      intent.nil? ? [] : ["#{label}: intent must be null when status is \"unannotated\""]
    else
      []
    end
  end

end

# The formatter in a real `rspec` process, which is the only place two of its
# promises can actually be observed:
#
#   * that it is **additive** — the human formatter still runs (criterion 1);
#   * that it **never blocks CI** — the exit code the shell sees is the suite's
#     alone, even when the sink is broken (criterion 5).
#
# In-process assertions cannot see either: a formatter's exception escapes
# `RSpec::Core::Runner.run` and takes RSpec's exit code with it, so "the process
# still exited 0" is a claim about a process. Shelling out is also how
# exit_contract_spec.rb tests the linter's exit codes, and it keeps the fixture
# suite out of `spec/fixtures/` — these suites are written into a tmpdir, so
# spec_helper's fixture-leak guard has nothing to catch.
RSpec.describe "SpecGuard::RSpecFormatter in a real rspec run" do
  include FormatterRunHelpers

  describe "a suite with a passing, a failing and a pending example, and no annotations" do
    # Once for the whole block: each example here interrogates a different part
    # of the same run, and spawning a fresh `rspec` process per assertion buys
    # nothing but seconds.
    before(:context) { @run = run_rspec(FormatterRunHelpers::MIXED_SUITE) }

    let(:run) { @run }
    let(:specs) { run.payload["specs"] }

    # Criterion 1. The reason to check for progress's marks specifically: a
    # formatter that *replaced* the human one would still leave a summary on
    # stdout, so "there was output" proves nothing.
    # @intent: { entity: "RSpecFormatter child run", action: "run alongside the human formatter", behavior: "the formatter rides beside format progress in a real child rspec run without replacing its marks", layer: "integration" }
    it "runs alongside --format progress rather than replacing it" do
      expect(run.stdout).to include(".F*")
      expect(run.stdout).to include("3 examples, 1 failure, 1 pending")
    end

    # @intent: { entity: "RSpecFormatter child run", action: "write the sink", behavior: "the child run appends exactly one JSON object for the whole suite", layer: "integration" }
    it "appends exactly one JSON object for the run" do
      expect(run.lines.length).to eq(1)
    end

    # Criterion 4.
    # @intent: { entity: "RSpecFormatter child run", action: "record every example", behavior: "every example in the suite is recorded, not only an annotated subset", layer: "integration" }
    it "records every example in the suite, not just an annotated subset" do
      expect(specs.length).to eq(3)
    end

    # Criterion 3. The composed string is the point: `full_description` is what
    # makes a test identifiable across runs, and it only exists once the
    # describe, the context and the it are joined.
    # @intent: { entity: "RSpecFormatter child run", action: "record every example", behavior: "each example is named by its full composed description", layer: "integration" }
    it "names each example by its full, composed description" do
      expect(specs.map { |spec| spec["name"] }).to eq(
        [
          "user when signed in can order an item",
          "user when signed in cannot order an item that is out of stock",
          "user when signed in can cancel an order"
        ]
      )
    end

    # Criterion 2.
    # @intent: { entity: "RSpecFormatter child run", action: "record every example", behavior: "passing, failing and pending outcomes are each recorded as such", layer: "integration" }
    it "records each example's outcome" do
      expect(specs.map { |spec| spec["outcome"] }).to eq(%w[passed failed pending])
    end

    # @intent: { entity: "RSpecFormatter child run", action: "record every example", behavior: "every example records a real duration, pending ones included", layer: "integration" }
    it "records a real duration for every example, pending ones included" do
      expect(specs.map { |spec| spec["duration"] }).to all(be_a(Float).and(be > 0))
    end

    # @intent: { entity: "RSpecFormatter child run", action: "record every example", behavior: "each example is located by a path relative to the project root", layer: "integration" }
    it "records where each example lives, relative to the project root" do
      expect(specs.map { |spec| spec["file_path"] }).to all(eq("sample_spec.rb"))
      expect(specs.map { |spec| spec["line_number"] }).to eq([3, 8, 13])
    end

    # @intent: { entity: "RSpecFormatter child run", action: "wrap the envelope", behavior: "the rows arrive wrapped in the six-key run envelope", layer: "integration" }
    it "wraps them in a run envelope" do
      expect(run.payload.keys)
        .to contain_exactly("commit_sha", "branch", "ci_run_id", "shard_id", "duration_seconds", "specs")
      expect(run.payload["duration_seconds"]).to be_a(Float).and be > 0
    end

    # A suite with no annotations is the cold-start case, and it must still say
    # so *positively*. "No annotations here" and "this producer does not report
    # annotations" are different facts, and only one of them is true.
    # @intent: { entity: "RSpecFormatter child run", action: "report unannotated suites", behavior: "an unannotated suite reports every example unannotated with a null intent", layer: "integration" }
    it "reports every example as unannotated, with a null intent" do
      expect(specs.map { |spec| spec["status"] }).to all(eq("unannotated"))
      expect(specs.map { |spec| spec["intent"] }).to all(be_nil)
    end

    # @intent: { entity: "RSpecFormatter child run", action: "match the platform row shape", behavior: "each entry carries exactly the fields the platform spec entry is made of", layer: "integration" }
    it "carries exactly the fields the platform's spec entry is made of" do
      expect(specs.first.keys)
        .to contain_exactly("id", "spec_file_path", "file_path", "line_number", "name", "duration",
                            "outcome", "status", "intent")
    end

    # Criterion 3, on the ordinary suite: no two rows share an identity even
    # when nothing about the suite is unusual.
    # @intent: { entity: "RSpecFormatter child run", action: "identify examples", behavior: "every example gets an id of its own", layer: "integration" }
    it "gives every example an id of its own" do
      expect(specs.map { |spec| spec["id"] }.uniq.length).to eq(specs.length)
    end

    # The ordinary case: nothing is shared, so the file that ran the example and
    # the file that defined it are the same file.
    # @intent: { entity: "RSpecFormatter child run", action: "identify examples", behavior: "the owning spec file reported is the file the examples are written in", layer: "integration" }
    it "reports the owning spec file as the file the examples are written in" do
      expect(specs.map { |spec| spec["spec_file_path"] }).to all(eq("sample_spec.rb"))
    end

    # @intent: { entity: "RSpecFormatter child run", action: "leave the exit status alone", behavior: "the suite own exit status passes through untouched", layer: "integration" }
    it "leaves the suite's own exit status alone" do
      expect(run.exit_status).to eq(1)
    end

    # @intent: { entity: "RSpecFormatter child run", action: "stay quiet when healthy", behavior: "a healthy child run says nothing on stderr", layer: "integration" }
    it "says nothing on stderr when everything works" do
      expect(run.stderr).to be_empty
    end
  end

  # SPGD-1417. The lookup binds its read root when the formatter is built —
  # suite start, before any spec file loads — and a suite is free to move the
  # working directory after that. Run for real, in a child, because the thing
  # under test is the whole chain: rspec-core's own relativization hands the
  # lookup repo-relative paths, and only a real cwd move can make the row and
  # the read disagree.
  #
  # Two files, deliberately: the lookup builds one index per file, so a single
  # file straddling the move would have its index built by the first row and
  # answer the second from the memo — green on any root behaviour at all. The
  # second file is the one whose FIRST lookup happens inside the moved
  # directory; the first file is the control that proves the fixtures and the
  # stub validator annotate at all. The chdir sits in a `before(:all)` /
  # `after(:all)` pair rather than an `around` hook so the row is captured
  # inside the moved directory however rspec orders its notifications, and
  # restored before the child writes its relative sink path.
  describe "a suite that changes directory mid-run (SPGD-1417)" do
    def annotated_before
      <<~RUBY
        RSpec.describe "before the move" do
          # @intent: { entity: "Order", action: "checkout", behavior: "returns 402 payment required on expired card", layer: "request" }
          it "records before the suite moves" do
            expect(1).to eq(1)
          end
        end
      RUBY
    end

    def annotated_after
      <<~RUBY
        ROOT = Dir.pwd

        RSpec.describe "after the move" do
          before(:all) { Dir.chdir(File.join(ROOT, "sub")) }
          after(:all) { Dir.chdir(ROOT) }

          # @intent: { entity: "Order", action: "refund stock", behavior: "a refund restores the stock the order consumed", layer: "unit" }
          it "still records after the suite moved" do
            expect(1).to eq(1)
          end
        end
      RUBY
    end

    before(:context) do
      @run = run_rspec(annotated_before, files: {
                         "elsewhere/after_spec.rb" => annotated_after,
                         "sub/.keep" => ""
                       })
    end

    let(:run) { @run }
    let(:specs) { run.payload["specs"] }

    def row_for(path)
      specs.find { |spec| spec["file_path"] == path }
    end

    # @intent: { entity: "RSpecFormatter child run", action: "annotate across a mid-run chdir", behavior: "a readable annotated spec whose first lookup happens after the suite changed directory still reports annotated with its intent", layer: "integration" }
    it "still annotates the spec first read after the suite moved" do
      expect(run.exit_status).to eq(0)

      after_row = row_for("elsewhere/after_spec.rb")
      expect(after_row).not_to be_nil
      expect(after_row["status"]).to eq("annotated")
      expect(after_row["intent"]).to include("entity" => "Order", "action" => "refund stock")
    end

    # The control, asserted as its own example rather than implied by the one
    # above: with broken fixtures or a broken stub, both rows would read
    # unannotated and the example above would say nothing about the chdir.
    # @intent: { entity: "RSpecFormatter child run", action: "annotate across a mid-run chdir", behavior: "the spec read before the move keeps annotating, so the sibling assertion is about the chdir and not about broken fixtures", layer: "integration" }
    it "keeps annotating the spec read before the move" do
      before_row = row_for("sample_spec.rb")
      expect(before_row).not_to be_nil
      expect(before_row["status"]).to eq("annotated")
      expect(before_row["intent"]).to include("entity" => "Order", "action" => "checkout")
    end
  end

  # SPGD-1429, end to end. The block above pins SPGD-1417's half of the
  # pipeline — the lookup's read root, bound at construction — and it passes
  # only because its control row relativizes BEFORE the move, binding
  # rspec-core's regex at the construction directory: the two roots agree by
  # luck. The `SHALLOWER` direction is the one that breaks that luck. A suite
  # whose first file chdirs to an ANCESTOR at load time — before anything has
  # relativized, and therefore before the regex's first read — makes the two
  # roots disagree: rows relativize against the moved-to ancestor
  # (`<root>/sample_spec.rb` reads as `<tmpdir-name>/sample_spec.rb`) while
  # the lookup resolves those spellings against the construction directory,
  # doubling the segment into `<root>/<tmpdir-name>/...`, which no file
  # answers. Every readable, correctly annotated spec in the run ships
  # `unannotated` / `intent: null` — byte-for-byte what a genuinely
  # unannotated row reports — with no warning, no degraded flag and an
  # unchanged exit code.
  #
  # The ordering is the discriminator, not the chdir. This whole file's
  # deeper-chdir block leans on a row recorded before the move; this suite
  # has no such row. The chdir is the FIRST statement of the FIRST file
  # loaded (`sample_spec.rb` is always the harness's first target), so the
  # run's first relativization cannot land before the move — a pin that
  # recorded any row first, or that moved deeper, is green on the unfixed
  # code. The `after(:all)` restores the cwd before the child writes its
  # relative sink path, for the same reason the block above restores its own.
  #
  # The control arm runs an identical suite that never moves: construction
  # and the first relativization happen in the same directory, so both roots
  # bind there naturally. It exists so a rig that degraded to "neither arm
  # annotates" fails rather than passing on equality — broken fixtures or a
  # broken stub validator would otherwise make the moved arm's assertion
  # vacuous.
  describe "a suite whose first lookup happens after the suite moves to a shallower directory (SPGD-1429)" do
    def annotated_shallower_mover
      <<~RUBY
        ROOT = Dir.pwd
        Dir.chdir(File.dirname(ROOT))

        RSpec.describe "orders" do
          after(:all) { Dir.chdir(ROOT) }

          # @intent: { entity: "Order", action: "checkout", behavior: "returns 402 payment required on expired card", layer: "request" }
          it "totals the basket" do
            expect(1).to eq(1)
          end
        end
      RUBY
    end

    def annotated_no_move
      <<~RUBY
        RSpec.describe "orders" do
          # @intent: { entity: "Order", action: "checkout", behavior: "returns 402 payment required on expired card", layer: "request" }
          it "totals the basket" do
            expect(1).to eq(1)
          end
        end
      RUBY
    end

    before(:context) do
      @moved = run_rspec(annotated_shallower_mover)
      @control = run_rspec(annotated_no_move)
    end

    let(:moved) { @moved }
    let(:control) { @control }

    def row_for(run, path)
      run.payload["specs"].find { |spec| spec["file_path"] == path }
    end

    # @intent: { entity: "RSpecFormatter child run", action: "annotate after a shallower move", behavior: "a readable annotated suite still annotates when its first lookup happens after the suite moved to a shallower directory, with the file register spelled against the construction root", layer: "integration" }
    it "still annotates the suite whose first lookup lands after the move" do
      expect(moved.exit_status).to eq(0)

      moved_row = row_for(moved, "sample_spec.rb")
      expect(moved_row).not_to be_nil
      expect(moved_row["status"]).to eq("annotated")
      expect(moved_row["intent"]).to include("entity" => "Order", "action" => "checkout")
    end

    # The control, asserted as its own example rather than implied by the one
    # above: with broken fixtures or a broken stub, both runs would read
    # unannotated and the example above would say nothing about the roots.
    # @intent: { entity: "RSpecFormatter child run", action: "annotate without a move", behavior: "the identical suite that never changes directory keeps annotating, so the sibling assertion is about the two roots and not about broken fixtures", layer: "integration" }
    it "keeps annotating the identical suite that never moves" do
      expect(control.exit_status).to eq(0)

      control_row = row_for(control, "sample_spec.rb")
      expect(control_row).not_to be_nil
      expect(control_row["status"]).to eq("annotated")
      expect(control_row["intent"]).to include("entity" => "Order", "action" => "checkout")
    end
  end

  # Criterion 1, under the wiring that can actually fail it.
  #
  # The block above hands its child `--format progress` on the command line, so
  # its "runs alongside progress" guard is asserting about a formatter the
  # *harness* supplied — correct, and unfalsifiable. SPGD-195 lived in the gap:
  # RSpec adds its default human formatter only when no formatter was
  # registered at all (`rspec-core-3.13.6 formatters.rb:127`), so the README's
  # `RSpec.configure` wiring — SpecGuard's formatter and nothing else — made the
  # list non-empty, suppressed `progress`, and printed **zero bytes** for a
  # failing suite. Telemetry was perfect; the developer got no dots, no failure,
  # no diff, no `file:line` and no re-run command, and still exit 1.
  #
  # Every example here therefore runs with `wiring: :ruby`, where SpecGuard's is
  # the only formatter anyone asked for. Delete the repair in
  # `RSpecFormatter#seed` and this block goes red; the block above stays green.
  describe "a suite wired the README's Ruby way, with no other formatter" do
    before(:context) do
      @run = run_rspec(FormatterRunHelpers::MIXED_SUITE, wiring: :ruby)
    end

    let(:run) { @run }

    # @intent: { entity: "RSpecFormatter ruby wiring", action: "run with no other formatter", behavior: "a suite wired the readme ruby way still prints the progress marks, so the run is not silent", layer: "integration" }
    it "still prints progress's marks, so the run is not silent" do
      expect(run.stdout).to include(".F*")
    end

    # The four things a developer needs in order to act on a red suite. Asserted
    # separately from the dots because a formatter that emitted marks and
    # swallowed the failure body would satisfy the line above and still leave
    # nobody able to fix anything.
    # @intent: { entity: "RSpecFormatter ruby wiring", action: "run with no other formatter", behavior: "the failure, its diff, its location and the re-run command still print", layer: "integration" }
    it "prints the failure, its diff, its location and the re-run command" do
      expect(run.stdout).to include("Failures:")
      expect(run.stdout).to include("expected: :out_of_stock")
      expect(run.stdout).to include("sample_spec.rb:10")
      expect(run.stdout).to include("rspec ./sample_spec.rb:8")
    end

    # @intent: { entity: "RSpecFormatter ruby wiring", action: "run with no other formatter", behavior: "the summary line still prints", layer: "integration" }
    it "prints the summary line" do
      expect(run.stdout).to include("3 examples, 1 failure, 1 pending")
    end

    # Criterion 5 is about stdout, and criterion 3 is what keeps the repair from
    # being a trade: the telemetry this wiring produces is the same telemetry
    # the `.rspec` wiring produces.
    # @intent: { entity: "RSpecFormatter ruby wiring", action: "run with no other formatter", behavior: "the ruby wiring captures the same telemetry the rspec-file wiring does", layer: "integration" }
    it "captures the same telemetry as the .rspec wiring" do
      expect(run.lines.length).to eq(1)
      expect(run.payload["specs"].length).to eq(3)
      expect(run.payload["specs"].first.keys).to contain_exactly(
        "id", "spec_file_path", "file_path", "line_number", "name",
        "duration", "outcome", "status", "intent"
      )
    end

    # Criterion 4. The never-block-CI contract is untouched by any of this: the
    # exit code was already correct when the output was missing.
    # @intent: { entity: "RSpecFormatter ruby wiring", action: "leave the exit status alone", behavior: "the ruby wiring leaves the suite exit status alone", layer: "integration" }
    it "leaves the suite's own exit status alone" do
      expect(run.exit_status).to eq(1)
    end

    # @intent: { entity: "RSpecFormatter ruby wiring", action: "stay quiet when healthy", behavior: "the ruby wiring says nothing on stderr when it works", layer: "integration" }
    it "says nothing on stderr" do
      expect(run.stderr).to be_empty
    end
  end

  # Criterion 1, stated the way the criterion states it: *byte-comparable to the
  # same suite without the formatter*.
  #
  # The block above asserts on substrings, which is what you want when you are
  # naming the four things a developer needs off a red suite — but a substring
  # cannot see a line printed twice, and cannot see a line RSpec would have
  # printed that nobody did. Both of those have now happened here. So this block
  # runs each wiring against a `:none` control and diffs the whole stream.
  #
  # `NON_EXAMPLE_ERROR_SUITE` is the load-bearing half. `reporter.message` is
  # served by a *different* formatter from the one that prints dots and
  # summaries — `FallbackMessageFormatter` when nothing else listens for
  # `:message` — so restoring the default without accounting for it gives that
  # notification two listeners and prints every message twice. Measured before
  # the fix: one error block at the control, two under the README's Ruby
  # wiring. Every other suite in this file is a pure
  # example suite with no message path, so nothing else here can see it.
  describe "output parity with a run that has no SpecGuard at all" do
    {
      "the README's Ruby wiring" => :ruby,
      "the README's .rspec wiring" => :rspec_flags
    }.each do |description, wiring|
      context "under #{description}" do
        # One control per suite, shared across both examples below — these are
        # subprocess runs, and there are four of them in this block already.
        before(:context) do
          @mixed_control = run_rspec(FormatterRunHelpers::MIXED_SUITE, wiring: :none)
          @message_control = run_rspec(FormatterRunHelpers::NON_EXAMPLE_ERROR_SUITE, wiring: :none)
        end

        # @intent: { entity: "RSpecFormatter output parity", action: "match a plain run byte for byte", behavior: "a failing suite prints exactly what RSpec alone would have printed", layer: "integration" }
        it "prints a failing suite exactly as RSpec would have" do
          run = run_rspec(FormatterRunHelpers::MIXED_SUITE, wiring: wiring)

          expect(stdout_shape(run.stdout)).to eq(stdout_shape(@mixed_control.stdout))
          expect(run.stdout).not_to be_empty
        end

        # Exactly once, and in the control's own words. `scan(...).length == 1`
        # would catch the duplication too, but the whole-stream comparison also
        # catches a message that went missing — which is the failure mode of the
        # obvious alternative repair, where this formatter implements `message`
        # as a no-op to suppress the fallback and then nothing prints it at all.
        # @intent: { entity: "RSpecFormatter output parity", action: "match a plain run byte for byte", behavior: "a non-example error prints exactly as RSpec alone would have printed it", layer: "integration" }
        it "prints a non-example error exactly as RSpec would have" do
          run = run_rspec(FormatterRunHelpers::NON_EXAMPLE_ERROR_SUITE, wiring: wiring)

          expect(stdout_shape(run.stdout)).to eq(stdout_shape(@message_control.stdout))
          expect(run.stdout.scan("An error occurred in an `after(:context)` hook.").length).to eq(1)
          expect(run.stdout).to include("TEARDOWN-BLEW-UP")
        end
      end
    end

    # The third output path the repair touches, and the last one this file was
    # blind to.
    #
    # Restoring the default formatter mid-`:seed` means the newcomer misses the
    # `:seed` notification currently being dispatched, so
    # `restore_suppressed_default_formatter` hands it that notification by hand.
    # Under RSpec's *defined* ordering — which every other run in this file uses
    # — `seed_used?` is false and the seed banner is never printed by anyone, so
    # dropping that forwarding changes nothing observable and the whole suite
    # stays green. Under `--order random` it is the difference between a
    # developer being able to reproduce a flaky failure and not: deleting the
    # forwarding loop costs `MIXED_SUITE` its head banner and the blank line
    # above it — a 27-byte hole, and the *only* difference between the two
    # streams. Quoted as a delta rather than as two totals on purpose: the
    # totals carry the run's wall-clock digits, so they move between two
    # invocations of this same suite, while the 27 bytes are exactly those two
    # lines and do not.
    #
    # Only `:ruby` is exercised here on purpose. Under the `.rspec` wiring
    # `progress` is registered before the run starts, so the restore returns
    # early and there is nothing to forward — a `:rspec_flags` copy of this
    # example would pass no matter what the forwarding loop did, which is the
    # exact defect shape this file exists to stop.
    context "under the README's Ruby wiring, with randomised ordering" do
      before(:context) do
        @random_control = run_rspec(
          FormatterRunHelpers::MIXED_SUITE, wiring: :none, order: :random
        )
      end

      # Guards the diff below against passing vacuously. If a future rspec-core
      # stopped printing the banner, or the `order:` plumbing silently failed to
      # reach the child, both streams would lose it together and the comparison
      # would agree about nothing. This pins that the control really does carry
      # the thing the comparison is here to protect — head and tail.
      # @intent: { entity: "RSpecFormatter output parity", action: "match a randomised run", behavior: "the control run prints the seed banner twice, proving the parity harness can see it", layer: "integration" }
      it "has a control that prints the seed banner twice" do
        expect(@random_control.stdout.scan(/Randomized with seed #{FormatterRunHelpers::FIXED_SEED}/).length)
          .to eq(2)
      end

      # @intent: { entity: "RSpecFormatter output parity", action: "match a randomised run", behavior: "a randomised run prints exactly as RSpec alone would have, seed banner included", layer: "integration" }
      it "prints a randomised run exactly as RSpec would have, banner included" do
        run = run_rspec(FormatterRunHelpers::MIXED_SUITE, wiring: :ruby, order: :random)

        expect(stdout_shape(run.stdout)).to eq(stdout_shape(@random_control.stdout))
      end
    end

    # And the telemetry is still there — the parity above is worth nothing if it
    # was bought by not capturing anything.
    # @intent: { entity: "RSpecFormatter output parity", action: "match a randomised run", behavior: "the randomised run is captured as telemetry while matching the control output byte for byte", layer: "integration" }
    it "captures the run while matching the control byte for byte" do
      run = run_rspec(FormatterRunHelpers::NON_EXAMPLE_ERROR_SUITE, wiring: :ruby)

      expect(run.lines.length).to eq(1)
      expect(run.payload["specs"].length).to eq(1)
    end
  end

  # Criterion 2 again, under the wiring that separates "restore the default when
  # the run would otherwise be silent" from "restore the default whenever
  # nothing prints a summary".
  #
  # `--format failures` (`FailureListFormatter`) reports the run — one line per
  # failure — and never prints a summary. The first attempt at this repair asked
  # only whether some formatter would print a summary, so it read this developer
  # as unserved and added a whole progress run on top of the formatter they had
  # explicitly named. Measured on `MIXED_SUITE`, which is what both examples
  # below run: 61 bytes became ~963. `--format documentation` cannot catch
  # that, because documentation prints a summary and is therefore recognised
  # either way.
  describe "a suite whose developer explicitly chose --format failures" do
    before(:context) do
      @control = run_rspec(FormatterRunHelpers::MIXED_SUITE, wiring: :failure_list_only)
      @run = run_rspec(FormatterRunHelpers::MIXED_SUITE, wiring: :ruby_with_failure_list)
    end

    let(:run) { @run }

    # @intent: { entity: "RSpecFormatter chosen formatter", action: "respect an explicit failures choice", behavior: "a suite that chose format failures prints the failure list and only that", layer: "integration" }
    it "prints the failure list, and only the failure list" do
      expect(run.stdout).to eq(@control.stdout)
      expect(run.stdout).to eq("./sample_spec.rb:8:cannot order an item that is out of stock\n")
    end

    # @intent: { entity: "RSpecFormatter chosen formatter", action: "respect an explicit failures choice", behavior: "neither progress marks nor a summary are added beside the chosen formatter", layer: "integration" }
    it "adds neither progress marks nor a summary" do
      expect(run.stdout).not_to include("3 examples")
      expect(run.stdout).not_to include("Failures:")
    end

    # @intent: { entity: "RSpecFormatter chosen formatter", action: "respect an explicit failures choice", behavior: "the failures-only run still captures its telemetry and leaves the exit status alone", layer: "integration" }
    it "still captures its telemetry and leaves the exit status alone" do
      expect(run.lines.length).to eq(1)
      expect(run.payload["specs"].length).to eq(3)
      expect(run.exit_status).to eq(1)
    end
  end

  # Criterion 2 — the other side of the repair, and the one a careless fix
  # breaks. A developer who named their own formatter has already been served by
  # RSpec, so restoring the default on top of it would give them documentation
  # *and* a row of progress dots.
  #
  # This is also why the repair cannot live in the user's `spec_helper` as
  # `add_formatter(:progress) if config.formatters.empty?`:
  # `configuration_options.rb:21-25` applies `--require` before `--format`, so
  # the list is `[]` inside the helper even for the run below, and that version
  # would fail here.
  describe "a suite whose developer explicitly chose --format documentation" do
    before(:context) do
      @run = run_rspec(FormatterRunHelpers::MIXED_SUITE, wiring: :ruby_with_documentation)
    end

    let(:run) { @run }

    # @intent: { entity: "RSpecFormatter chosen formatter", action: "respect an explicit documentation choice", behavior: "a suite that chose format documentation prints documentation output", layer: "integration" }
    it "prints documentation output" do
      expect(run.stdout).to include("can order an item")
    end

    # Exactly once: a second human formatter would repeat every example name.
    # The *passing* example is the one to count — RSpec itself reprints the
    # failing and pending ones in its "Failures:" and "Pending:" sections, so
    # counting those would assert about documentation's own layout rather than
    # about how many formatters are attached.
    # @intent: { entity: "RSpecFormatter chosen formatter", action: "respect an explicit documentation choice", behavior: "each example name prints exactly once", layer: "integration" }
    it "prints each example's name exactly once" do
      expect(run.stdout.scan("can order an item").length).to eq(1)
      expect(run.stdout.scan("3 examples, 1 failure, 1 pending").length).to eq(1)
    end

    # Progress's marks are the signature of an unwanted second formatter, but
    # `include(".F*")` is the wrong way to look for them and passes vacuously:
    # progress emits one mark per example with no newline, so alongside
    # documentation the marks are scattered one-per-line rather than contiguous.
    # What a second formatter actually does to this output is push
    # documentation's lines off the left margin — the mark for the *previous*
    # example lands in front of the next one's line, turning
    # `    cannot order an item…` into `.    cannot order an item…`.
    #
    # The failing example's listing line is the one to check: it is the first
    # line printed after an example that progress would have marked, and
    # `(FAILED - 1)` picks it out from documentation's listing without also
    # matching the "Failures:" section's own restatement of the same name.
    # @intent: { entity: "RSpecFormatter chosen formatter", action: "respect an explicit documentation choice", behavior: "no progress dots appear alongside the documentation output", layer: "integration" }
    it "does not add progress dots alongside it" do
      listing = run.stdout.lines.grep(/\(FAILED - 1\)/)

      expect(listing.length).to eq(1)
      expect(listing.first).to eq("    cannot order an item that is out of stock (FAILED - 1)\n")
    end

    # @intent: { entity: "RSpecFormatter chosen formatter", action: "respect an explicit documentation choice", behavior: "the documentation run captures its telemetry and leaves the exit status alone", layer: "integration" }
    it "captures its telemetry and leaves the exit status alone" do
      expect(run.lines.length).to eq(1)
      expect(run.payload["specs"].length).to eq(3)
      expect(run.exit_status).to eq(1)
    end
  end

  # Criterion 2: all four placements, resolved in one real run — plus the two
  # downgrades, because an implementation that got those wrong would still get
  # these four right.
  describe "a suite exercising every annotation shape" do
    before(:context) { @run = run_rspec(FormatterRunHelpers::ANNOTATED_SUITE) }

    let(:run) { @run }
    let(:specs) { run.payload["specs"] }
    let(:by_name) { specs.to_h { |spec| [spec["name"], spec] } }

    def status_of(name) = by_name.fetch("user #{name}")["status"]

    # @intent: { entity: "RSpecFormatter annotation shapes", action: "run the shape suite", behavior: "the six-example suite covering every annotation shape runs to completion", layer: "integration" }
    it "runs all six examples" do
      expect(run.stdout).to include("6 examples, 0 failures")
      expect(specs.length).to eq(6)
    end

    # @intent: { entity: "RSpecFormatter annotation shapes", action: "resolve the comment form", behavior: "an example with a comment annotation on the line above ships annotated", layer: "integration" }
    it "annotates an example from the comment line above it" do
      expect(status_of("can order an item")).to eq("annotated")
      expect(by_name.fetch("user can order an item")["intent"])
        .to include("entity" => "Order", "action" => "checkout", "layer" => "request")
    end

    # @intent: { entity: "RSpecFormatter annotation shapes", action: "resolve the trailing form", behavior: "an example with a trailing annotation on its own line ships annotated", layer: "integration" }
    it "annotates an example from a trailing annotation on its own line" do
      expect(status_of("surfaces the decline reason")).to eq("annotated")
      expect(by_name.fetch("user surfaces the decline reason")["intent"]).to include("action" => "refund")
    end

    # `metadata[:line_number]` is the `it` line however deeply the example is
    # nested, so a context adds no offset to reason about.
    # @intent: { entity: "RSpecFormatter annotation shapes", action: "resolve nested examples", behavior: "an example nested inside a context resolves its annotation by lookback", layer: "integration" }
    it "annotates an example nested inside a context" do
      expect(by_name.fetch("user when signed in can cancel an order"))
        .to include("status" => "annotated", "line_number" => 27)
    end

    # @intent: { entity: "RSpecFormatter annotation shapes", action: "mark the unannotated", behavior: "an example with no annotation reports unannotated", layer: "integration" }
    it "reports an example with no annotation as unannotated" do
      expect(status_of("has no annotation")).to eq("unannotated")
      expect(by_name.fetch("user has no annotation")["intent"]).to be_nil
    end

    # Criterion 3, end to end. Both of these are annotations the *linter* exits
    # 1 over. Here they cost their own example's metadata and nothing else.
    # @intent: { entity: "RSpecFormatter annotation shapes", action: "downgrade malformed ones", behavior: "a malformed annotation downgrades to unannotated rather than shipping or failing the run", layer: "integration" }
    it "downgrades a malformed annotation rather than shipping or failing on it" do
      expect(by_name.fetch("user has a malformed annotation"))
        .to include("status" => "unannotated", "intent" => nil, "outcome" => "passed")
    end

    # @intent: { entity: "RSpecFormatter annotation shapes", action: "downgrade malformed ones", behavior: "a schema-invalid annotation downgrades the same way", layer: "integration" }
    it "downgrades a schema-invalid annotation the same way" do
      expect(by_name.fetch("user has a schema-invalid annotation"))
        .to include("status" => "unannotated", "intent" => nil, "outcome" => "passed")
    end

    # @intent: { entity: "RSpecFormatter annotation shapes", action: "downgrade malformed ones", behavior: "a downgraded example still ships its name, duration and outcome", layer: "integration" }
    it "still ships the name, duration and outcome of a downgraded example" do
      downgraded = by_name.fetch("user has a malformed annotation")

      expect(downgraded["duration"]).to be_a(Float)
      expect(downgraded["line_number"]).to eq(16)
    end

    # @intent: { entity: "RSpecFormatter annotation shapes", action: "keep quiet through it all", behavior: "the whole shape suite produces no stderr output", layer: "integration" }
    it "keeps quiet about all of it" do
      expect(run.stderr).to be_empty
      expect(run.exit_status).to eq(0)
    end

    # Criterion 4 — the criterion that proves slice 3 is unblocked. Asserted
    # per entry rather than as a single count, so a failure names the spec and
    # the rule instead of moving a total from 6 to 5.
    describe "the platform's ingest contract" do
      # @intent: { entity: "RSpecFormatter ingest contract", action: "satisfy the platform", behavior: "every example produces a spec entry the platform ingest accepts", layer: "integration" }
      it "produces a spec entry the platform accepts, for every example" do
        violations = specs.each_with_index.flat_map { |spec, index| IngestContract.errors_for(spec, index) }

        expect(violations).to be_empty
      end

      # @intent: { entity: "RSpecFormatter ingest contract", action: "satisfy the platform", behavior: "every spec status is one the platform enum admits", layer: "integration" }
      it "gives every spec a status the platform's enum admits" do
        expect(specs.map { |spec| spec["status"] } - IngestContract::STATUSES).to be_empty
      end

      # @intent: { entity: "RSpecFormatter ingest contract", action: "satisfy the platform", behavior: "annotated specs carry an intent object and unannotated ones carry none", layer: "integration" }
      it "gives every annotated spec an intent object, and every unannotated one none" do
        annotated, unannotated = specs.partition { |spec| spec["status"] == "annotated" }

        expect(annotated.map { |spec| spec["intent"] }).to all(be_a(Hash))
        expect(annotated.length).to eq(3)
        expect(unannotated.map { |spec| spec["intent"] }).to all(be_nil)
      end

      # The counts the platform derives from this payload
      # (`Ingest::Payload#test_run_attributes`), and the reason `status` is
      # load-bearing rather than informational: this ratio is the headline
      # dashboard metric.
      # @intent: { entity: "RSpecFormatter ingest contract", action: "satisfy the platform", behavior: "the rows support the annotated ratio the platform derives rather than a vacuous full coverage", layer: "integration" }
      it "supports the annotated ratio the platform derives, rather than a vacuous 100%" do
        annotated = specs.count { |spec| spec["status"] == "annotated" }

        expect(annotated).to eq(3)
        expect(annotated).to be < specs.length
      end
    end
  end

  # The two shapes that make `(file_path, line_number)` the wrong key, run for
  # real. A double cannot prove either of these: it is told what `id` to answer,
  # so it would agree with any implementation. Only RSpec deciding for itself
  # says whether the identity actually separates these examples.
  describe "a table-driven loop, where one `it` produces several examples" do
    before(:context) { @run = run_rspec(FormatterRunHelpers::LOOP_SUITE) }

    let(:run) { @run }
    let(:specs) { run.payload["specs"] }

    # @intent: { entity: "RSpecFormatter table-driven loop", action: "report every iteration", behavior: "a loop producing three examples from one definition runs all three", layer: "integration" }
    it "runs all three examples" do
      expect(run.stdout).to include("3 examples, 0 failures")
      expect(specs.length).to eq(3)
    end

    # The defect, stated as the measurement. All three are written on line 3 —
    # that is what the loop *is* — so the coordinate has one distinct value for
    # three examples.
    # @intent: { entity: "RSpecFormatter table-driven loop", action: "report every iteration", behavior: "all three report the one shared definition coordinate", layer: "integration" }
    it "reports one shared definition coordinate for all three" do
      expect(specs.map { |spec| spec["line_number"] }).to all(eq(3))
      expect(specs.map { |spec| [spec["file_path"], spec["line_number"]] }.uniq.length).to eq(1)
    end

    # Criterion 1. Three rows, three identities — so a per-example duration and
    # a per-example outcome each have somewhere to live.
    # @intent: { entity: "RSpecFormatter table-driven loop", action: "report every iteration", behavior: "each of the three still gets an id of its own", layer: "integration" }
    it "still gives each of the three an id of its own" do
      expect(specs.map { |spec| spec["id"] }.uniq.length).to eq(3)
    end

    # RSpec's own re-run argument, verbatim: `rspec './loop_spec.rb[1:2]'` runs
    # exactly the second case and nothing else. Keeping the `./` prefix is the
    # point — it is what makes the value paste-able rather than merely unique.
    # @intent: { entity: "RSpecFormatter table-driven loop", action: "report every iteration", behavior: "each id is the argument that re-runs exactly that one example", layer: "integration" }
    it "makes each id the argument that re-runs that one example" do
      expect(specs.map { |spec| spec["id"] })
        .to eq(["./sample_spec.rb[1:1]", "./sample_spec.rb[1:2]", "./sample_spec.rb[1:3]"])
    end

    # @intent: { entity: "RSpecFormatter table-driven loop", action: "report every iteration", behavior: "each example is still distinctly named and every row is still accepted", layer: "integration" }
    it "still names each example distinctly, and still accepts every row" do
      expect(specs.map { |spec| spec["name"] }).to eq(
        ["Order returns 200 for a visa card",
         "Order returns 402 for a expired card",
         "Order returns 403 for a stolen card"]
      )
      violations = specs.each_with_index.flat_map { |spec, index| IngestContract.errors_for(spec, index) }
      expect(violations).to be_empty
    end
  end

  describe "a shared example group run from two different spec files" do
    before(:context) { @run = run_rspec(files: FormatterRunHelpers::SHARED_EXAMPLE_FILES) }

    let(:run) { @run }
    let(:specs) { run.payload["specs"] }

    # @intent: { entity: "RSpecFormatter shared example group", action: "report every inclusion", behavior: "a shared group included from two files runs both files worth of examples", layer: "integration" }
    it "runs both files' worth of examples" do
      expect(run.stdout).to include("4 examples, 0 failures")
      expect(specs.length).to eq(4)
    end

    # The defect, again as a measurement. Four examples, two coordinates — and
    # both coordinates name a file the linter never even scans, because
    # `spec/support/shared.rb` is not a `*_spec.rb`.
    # @intent: { entity: "RSpecFormatter shared example group", action: "report every inclusion", behavior: "all four report the shared support file as their definition site", layer: "integration" }
    it "reports every one of them as defined in the shared support file" do
      expect(specs.map { |spec| spec["file_path"] }).to all(eq("spec/support/shared.rb"))
      expect(specs.map { |spec| [spec["file_path"], spec["line_number"]] }.uniq.length).to eq(2)
    end

    # Criterion 2, first half.
    # @intent: { entity: "RSpecFormatter shared example group", action: "report every inclusion", behavior: "each of the four still gets an id of its own", layer: "integration" }
    it "still gives each of the four an id of its own" do
      expect(specs.map { |spec| spec["id"] }.uniq.length).to eq(4)
    end

    # Criterion 2, second half — and the whole reason `spec_file_path` is a
    # separate field. Without it the two files that actually ran these tests
    # appear nowhere in the payload, so a duration-by-file report attributes all
    # four to a `spec/support/` helper.
    # @intent: { entity: "RSpecFormatter shared example group", action: "report every inclusion", behavior: "the including spec file is named as the file that ran each example", layer: "integration" }
    it "names the including spec file as the file that ran each example" do
      expect(specs.map { |spec| spec["spec_file_path"] })
        .to contain_exactly("spec/orders_spec.rb", "spec/orders_spec.rb",
                            "spec/users_spec.rb", "spec/users_spec.rb")
    end

    # @intent: { entity: "RSpecFormatter shared example group", action: "report every inclusion", behavior: "each id roots at the including file so re-running one is unambiguous", layer: "integration" }
    it "roots each id at the including file too, so re-running one is unambiguous" do
      expect(specs.map { |spec| spec["id"] }).to contain_exactly(
        "./spec/orders_spec.rb[1:1:1]", "./spec/orders_spec.rb[1:1:2]",
        "./spec/users_spec.rb[1:1:1]", "./spec/users_spec.rb[1:1:2]"
      )
    end

    # @intent: { entity: "RSpecFormatter shared example group", action: "report every inclusion", behavior: "all four entries still satisfy the platform ingest contract", layer: "integration" }
    it "still produces a spec entry the platform accepts, for all four" do
      violations = specs.each_with_index.flat_map { |spec, index| IngestContract.errors_for(spec, index) }

      expect(violations).to be_empty
    end

    # @intent: { entity: "RSpecFormatter shared example group", action: "report every inclusion", behavior: "the suite exit status is kept and stderr stays empty", layer: "integration" }
    it "keeps the suite's own exit status and says nothing on stderr" do
      expect(run.exit_status).to eq(0)
      expect(run.stderr).to be_empty
    end
  end

  # A trailing annotation belongs to the example it was written on, and to no
  # other. The lookback window is one line wide either way; what this run pins
  # is that the *form* decides who may look through it.
  describe "a suite of one-liner examples with a trailing annotation" do
    before(:context) { @run = run_rspec(FormatterRunHelpers::ONE_LINER_SUITE) }

    let(:run) { @run }
    let(:specs) { run.payload["specs"] }
    let(:by_name) { specs.to_h { |spec| [spec["name"], spec] } }

    # @intent: { entity: "RSpecFormatter one-liner suite", action: "run the one-liners", behavior: "both one-line examples in the suite run", layer: "integration" }
    it "runs both examples" do
      expect(run.stdout).to include("2 examples, 0 failures")
      expect(specs.length).to eq(2)
    end

    # @intent: { entity: "RSpecFormatter one-liner suite", action: "scope trailing annotations", behavior: "the trailing annotation belongs to the example it was written on", layer: "integration" }
    it "annotates the example the annotation was written on" do
      expect(by_name.fetch("Order is expected to eq 1"))
        .to include("status" => "annotated", "line_number" => 4)
    end

    # The defect this fixture exists for: line 5 declared nothing, and a payload
    # that says otherwise is not a gap in the data, it is wrong data.
    # @intent: { entity: "RSpecFormatter one-liner suite", action: "scope trailing annotations", behavior: "that annotation is not lent to the example on the next line", layer: "integration" }
    it "does not lend that annotation to the example on the next line" do
      expect(by_name.fetch("Order is expected to be positive"))
        .to include("status" => "unannotated", "intent" => nil, "line_number" => 5)
    end

    # Stated as the number the dashboard reads, because that is where the
    # inflation would show up: 2 of 2 annotated for a file with one annotation.
    # @intent: { entity: "RSpecFormatter one-liner suite", action: "scope trailing annotations", behavior: "the run reports exactly one annotated example, not two", layer: "integration" }
    it "reports one annotated example, not two" do
      expect(specs.count { |spec| spec["status"] == "annotated" }).to eq(1)
    end

    # @intent: { entity: "RSpecFormatter one-liner suite", action: "satisfy the platform", behavior: "both entries still satisfy the platform ingest contract", layer: "integration" }
    it "still produces a spec entry the platform accepts, for both examples" do
      violations = specs.each_with_index.flat_map { |spec, index| IngestContract.errors_for(spec, index) }

      expect(violations).to be_empty
    end
  end

  describe "the run envelope" do
    # @intent: { entity: "RSpecFormatter run envelope", action: "read the environment", behavior: "a child run takes its commit and branch from the environment it was handed", layer: "integration" }
    it "takes the commit and branch from the environment" do
      run = run_rspec(FormatterRunHelpers::GREEN_SUITE, prepare: lambda { |_root|
        { "SPECGUARD_COMMIT_SHA" => "abc123", "SPECGUARD_BRANCH" => "feature/x" }
      })

      expect(run.payload).to include("commit_sha" => "abc123", "branch" => "feature/x")
    end

    # SPGD-810: a keyless run writes the local sink, so this is the path the
    # gem must honour for it.
    # @intent: { entity: "RSpecFormatter run envelope", action: "honour the local path", behavior: "a configured local output path is honoured by the child run", layer: "integration" }
    it "honours a configured local output path" do
      run = run_rspec(FormatterRunHelpers::GREEN_SUITE,
                      prepare: ->(_root) { { "SPECGUARD_LOCAL_OUTPUT_PATH" => "tmp/telemetry.jsonl" } })

      expect(run.lines.length).to eq(1)
    end
  end

  # Criterion 5, at the level that matters: the number the shell reads back.
  #
  # A `raise` in a formatter hook does not merely log — it escapes
  # `RSpec::Core::Runner.run`, so RSpec's exit code is never returned and the
  # process exits 1. Without the rescue, the green case below exits 1 with
  # "1 example, 0 failures" printed directly above it.
  describe "when the sink cannot be written" do
    before(:context) do
      @green = run_rspec(FormatterRunHelpers::GREEN_SUITE, prepare: blocked_sink)
      @red = run_rspec(FormatterRunHelpers::MIXED_SUITE, prepare: blocked_sink)
    end

    # @intent: { entity: "RSpecFormatter unwritable sink", action: "never redden a green suite", behavior: "an unwritable sink still exits zero for a green child suite", layer: "integration" }
    it "still exits 0 for a green suite" do
      expect(@green.stdout).to include("1 example, 0 failures")
      expect(@green.exit_status).to eq(0)
    end

    # @intent: { entity: "RSpecFormatter unwritable sink", action: "never touch a red one", behavior: "an unwritable sink still exits one for a failing child suite", layer: "integration" }
    it "still exits 1 for a failing suite" do
      expect(@red.stdout).to include("3 examples, 1 failure, 1 pending")
      expect(@red.exit_status).to eq(1)
    end

    # @intent: { entity: "RSpecFormatter unwritable sink", action: "warn once off stdout", behavior: "the sink failure warns once on stderr while stdout stays the human formatter own", layer: "integration" }
    it "warns once on stderr, and leaves stdout to the human formatter" do
      expect(@green.stderr.scan(/SpecGuard: test telemetry failed/).length).to eq(1)
      expect(@green.stdout).not_to include("SpecGuard:")
    end

    # @intent: { entity: "RSpecFormatter unwritable sink", action: "write nothing partial", behavior: "a failing sink writes nothing at all rather than a partial line somewhere else", layer: "integration" }
    it "writes nothing at all rather than a partial line somewhere else" do
      expect(@green.lines).to be_empty
    end
  end

  # Criteria 1, 3, 4 and 5, at the only level where the promise they are all
  # variations on can actually be observed: the number the shell reads back.
  #
  # In-process assertions cannot see it. A telemetry failure that escapes a
  # formatter hook takes `RSpec::Core::Runner.run`'s exit code with it, and
  # "the process still exited 0" is a claim about a process. So these run a
  # real `rspec` against a real socket, and check the exit status every time —
  # including in the cases where SpecGuard is the thing that is broken.
  describe "delivering the run to a real endpoint" do
    describe "when the endpoint accepts it" do
      before(:context) do
        StubIngestEndpoint.run(status: 202) do |server|
          @run = run_rspec(FormatterRunHelpers::MIXED_SUITE,
                           prepare: ->(_root) { transport_env(server) })
          @requests = server.requests
        end
      end

      let(:run) { @run }
      let(:request) { @requests.first }

      # Criterion 1.
      # @intent: { entity: "RSpecFormatter delivery", action: "POST once on success", behavior: "an accepted run POSTs exactly once to the endpoint", layer: "integration" }
      it "POSTs the run exactly once" do
        expect(@requests.length).to eq(1)
      end

      # @intent: { entity: "RSpecFormatter delivery", action: "POST once on success", behavior: "the POST targets the platform path with a bearer key and a JSON body", layer: "integration" }
      it "posts to the platform's path, with a Bearer key and a JSON body" do
        expect(request.path).to eq("/api/v1/ingest")
        expect(request.headers["authorization"]).to eq("Bearer sgk_abc123")
        expect(request.headers["content-type"]).to eq("application/json")
      end

      # @intent: { entity: "RSpecFormatter delivery", action: "POST once on success", behavior: "the whole run, envelope and every example, goes in one body", layer: "integration" }
      it "sends the whole run, envelope and every example" do
        expect(request.json).to include("commit_sha" => "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2",
                                        "branch" => "main")
        expect(request.json["specs"].length).to eq(3)
        expect(request.json["duration_seconds"]).to be_a(Float).and be > 0
      end

      # The delivered body is the *whole* claim of this slice: it is what
      # produces a 202 rather than a 400, and it is transcribed from the
      # platform's own validator (see {IngestContract}) rather than assumed.
      # @intent: { entity: "RSpecFormatter delivery", action: "satisfy the ingest contract", behavior: "the body sent is one the platform ingest contract accepts", layer: "integration" }
      it "sends a body the platform's ingest contract accepts" do
        violations = request.json["specs"].each_with_index.flat_map do |spec, index|
          IngestContract.errors_for(spec, index)
        end

        expect(violations).to be_empty
      end

      # Criterion 7, on the envelope rather than the specs. These four rules
      # are `Ingest::Payload`'s own (`validate_commit_sha`, `validate_branch`,
      # `validate_duration_seconds`, `validate_specs`), and every one of them
      # rejects the *whole run* rather than one row.
      # @intent: { entity: "RSpecFormatter delivery", action: "satisfy the ingest contract", behavior: "the envelope sent is one the platform ingest contract accepts", layer: "integration" }
      it "sends an envelope the platform's ingest contract accepts" do
        body = request.json

        expect(body["commit_sha"]).to be_a(String).and satisfy { |v| !v.strip.empty? }
        expect(body["branch"]).to be_a(String).or be_nil
        expect(body["duration_seconds"]).to be_a(Numeric).and be >= 0
        expect(body["specs"]).to be_an(Array)
      end

      # The local file is the fallback, not a second copy: writing both would
      # double a shared CI sink's contents on every successful run.
      # @intent: { entity: "RSpecFormatter delivery", action: "stay clean on success", behavior: "a delivered run writes no local file", layer: "integration" }
      it "writes no local file when the run was delivered" do
        expect(run.lines).to be_empty
      end

      # @intent: { entity: "RSpecFormatter delivery", action: "stay clean on success", behavior: "a delivered run says nothing on stderr", layer: "integration" }
      it "says nothing on stderr" do
        expect(run.stderr).to be_empty
      end

      # @intent: { entity: "RSpecFormatter delivery", action: "stay clean on success", behavior: "the delivered run still leaves the suite exit status alone", layer: "integration" }
      it "leaves the suite's own exit status alone" do
        expect(run.stdout).to include("3 examples, 1 failure, 1 pending")
        expect(run.exit_status).to eq(1)
      end
    end

    # Criterion 3. The whole reason this slice exists: `Net::HTTP` returns
    # these as ordinary values, so the formatter's `rescue` sees nothing at all
    # and a naive implementation loses the run in complete silence.
    {
      400 => "a payload the endpoint refuses",
      401 => "a key the endpoint does not accept",
      500 => "an endpoint that is having a bad day"
    }.each do |status, description|
      describe "when the endpoint answers #{status} — #{description}" do
        before(:context) do
          StubIngestEndpoint.run(status: status) do |server|
            @green = run_rspec(FormatterRunHelpers::GREEN_SUITE,
                               prepare: ->(_root) { transport_env(server) })
            @red = run_rspec(FormatterRunHelpers::MIXED_SUITE,
                             prepare: ->(_root) { transport_env(server) })
          end
        end

        # @intent: { entity: "RSpecFormatter refused delivery", action: "never redden a green suite", behavior: "a refused delivery still exits zero for a green suite", layer: "integration" }
        it "still exits 0 for a green suite" do
          expect(@green.stdout).to include("1 example, 0 failures")
          expect(@green.exit_status).to eq(0)
        end

        # @intent: { entity: "RSpecFormatter refused delivery", action: "never touch a red one", behavior: "a refused delivery still exits one for a failing suite", layer: "integration" }
        it "still exits 1 for a failing suite" do
          expect(@red.stdout).to include("3 examples, 1 failure, 1 pending")
          expect(@red.exit_status).to eq(1)
        end

        # Naming the status is the requirement, not decoration: a 401 means
        # "rotate the key" and a 400 means "this gem built a body the platform
        # refused". Those are different people's problems.
        # @intent: { entity: "RSpecFormatter refused delivery", action: "warn once naming the status", behavior: "the refusal warns once on stderr naming the status code", layer: "integration" }
        it "warns once on stderr, naming the status code" do
          expect(@green.stderr.scan(/SpecGuard:/).length).to eq(1)
          expect(@green.stderr).to include("HTTP #{status}")
        end

        # @intent: { entity: "RSpecFormatter refused delivery", action: "leave stdout alone", behavior: "stdout stays the human formatter own through a refusal", layer: "integration" }
        it "leaves stdout to the human formatter" do
          expect(@green.stdout).not_to include("SpecGuard:")
        end

        # Silent loss becomes recoverable loss. The suite is over by the time
        # anyone reads the warning, so a run discarded here cannot be re-run.
        # @intent: { entity: "RSpecFormatter refused delivery", action: "keep the run", behavior: "the refused payload is written to the local fallback rather than dropped", layer: "integration" }
        it "writes the payload to the local fallback rather than dropping it" do
          expect(@green.lines.length).to eq(1)
          expect(@red.payload["specs"].length).to eq(3)
        end
      end
    end

    # Criterion 4. A raised exception takes the same path as a refused
    # response — the caller has one outcome to handle, not two.
    describe "when the request cannot be made at all" do
      before(:context) do
        # Port 1 is privileged and nothing is on it, so the connection is
        # refused immediately; `.invalid` is reserved by RFC 2606 and can never
        # resolve, so no test can accidentally depend on a real host.
        @refused = run_rspec(FormatterRunHelpers::GREEN_SUITE, prepare: lambda { |_root|
          { "SPECGUARD_ENDPOINT" => "http://127.0.0.1:1", "SPECGUARD_API_KEY" => "sgk_abc123",
            "SPECGUARD_COMMIT_SHA" => "abc123", "SPECGUARD_TIMEOUT" => "5" }
        })
        @unresolvable = run_rspec(FormatterRunHelpers::MIXED_SUITE, prepare: lambda { |_root|
          { "SPECGUARD_ENDPOINT" => "http://specguard.invalid", "SPECGUARD_API_KEY" => "sgk_abc123",
            "SPECGUARD_COMMIT_SHA" => "abc123", "SPECGUARD_TIMEOUT" => "5" }
        })
      end

      # @intent: { entity: "RSpecFormatter undeliverable request", action: "never redden a green suite", behavior: "a refused connection still exits zero for a green suite", layer: "integration" }
      it "still exits 0 for a green suite when the connection is refused" do
        expect(@refused.stdout).to include("1 example, 0 failures")
        expect(@refused.exit_status).to eq(0)
      end

      # @intent: { entity: "RSpecFormatter undeliverable request", action: "never touch a red one", behavior: "an unresolvable host still exits one for a failing suite", layer: "integration" }
      it "still exits 1 for a failing suite when the host does not resolve" do
        expect(@unresolvable.stdout).to include("3 examples, 1 failure, 1 pending")
        expect(@unresolvable.exit_status).to eq(1)
      end

      # @intent: { entity: "RSpecFormatter undeliverable request", action: "warn and name the cause", behavior: "the undeliverable request warns once naming the underlying error", layer: "integration" }
      it "warns once and names the underlying error" do
        expect(@refused.stderr.scan(/SpecGuard:/).length).to eq(1)
        expect(@refused.stderr).to match(/Errno::|SocketError/)
      end

      # @intent: { entity: "RSpecFormatter undeliverable request", action: "keep the run", behavior: "both undeliverable shapes fall back to the local file", layer: "integration" }
      it "falls back to the local file, for both of them" do
        expect(@refused.lines.length).to eq(1)
        expect(@unresolvable.payload["specs"].length).to eq(3)
      end
    end

    # Criterion 6. `Net::HTTP`'s stock 60s open + 60s read is up to two minutes
    # added to every CI run against a hung endpoint, which is squarely against
    # "a 20,000-example run must not be meaningfully slowed". The budget is
    # asserted as wall clock, because that is the thing being promised.
    # @intent: { entity: "RSpecFormatter silent endpoint", action: "honour the timeout budget", behavior: "an endpoint that never answers is given up on within the configured budget", layer: "integration" }
    it "gives up on an endpoint that never answers, within the configured budget" do
      StubIngestEndpoint.run(hang: true) do |server|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        run = run_rspec(FormatterRunHelpers::GREEN_SUITE,
                        prepare: ->(_root) { transport_env(server, SPECGUARD_TIMEOUT: "1") })
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        expect(run.exit_status).to eq(0)
        expect(run.stderr).to include("Net::ReadTimeout")
        expect(run.lines.length).to eq(1)
        # Generous against a loaded CI box, and still an order of magnitude
        # under the 120s a default-configured Net::HTTP would have spent.
        expect(elapsed).to be < 30
      end
    end

    # Criterion 5. The throwaway project root is not a git checkout and no
    # provider variable is set, so `commit_sha` really is blank — and
    # `Ingest::Payload#validate_commit_sha` rejects that outright, discarding
    # every example rather than the one empty field. Ten seconds of CI time to
    # be told so is pure loss.
    describe "when the commit cannot be determined" do
      before(:context) do
        StubIngestEndpoint.run(status: 202) do |server|
          @run = run_rspec(FormatterRunHelpers::GREEN_SUITE, prepare: lambda { |_root|
            { "SPECGUARD_ENDPOINT" => server.endpoint, "SPECGUARD_API_KEY" => "sgk_abc123" }
          })
          @requests = server.requests
        end
      end

      # @intent: { entity: "RSpecFormatter unknown commit", action: "stay off the wire", behavior: "a run whose commit cannot be determined issues no POST at all", layer: "integration" }
      it "issues no POST at all" do
        expect(@requests).to be_empty
      end

      # @intent: { entity: "RSpecFormatter unknown commit", action: "take the fallback", behavior: "the unknown-commit run takes the fallback sink instead", layer: "integration" }
      it "takes the fallback sink instead" do
        expect(@run.lines.length).to eq(1)
        expect(@run.payload["commit_sha"]).to be_nil
      end

      # @intent: { entity: "RSpecFormatter unknown commit", action: "say why", behavior: "the warning says why rather than leaving the operator to guess", layer: "integration" }
      it "says why, rather than leaving the operator to guess" do
        expect(@run.stderr).to include("the commit could not be determined")
      end

      # @intent: { entity: "RSpecFormatter unknown commit", action: "keep the exit status", behavior: "the run still exits on the suite own terms", layer: "integration" }
      it "still exits on the suite's own terms" do
        expect(@run.exit_status).to eq(0)
      end
    end

    # Criterion 2, at the process level: no key means no network, full stop.
    # Asserted against a live stub rather than by stubbing `Transport`, because
    # "nothing arrived at a real socket" is the claim, and a subprocess is not
    # somewhere a double can reach anyway.
    # @intent: { entity: "RSpecFormatter keyless run", action: "stay offline without a key", behavior: "with no api key the child run attempts no HTTP call and writes the local file as before", layer: "integration" }
    it "attempts no HTTP call when there is no API key, and writes the file as before" do
      StubIngestEndpoint.run(status: 202) do |server|
        run = run_rspec(FormatterRunHelpers::GREEN_SUITE,
                        prepare: ->(_root) { { "SPECGUARD_ENDPOINT" => server.endpoint } })

        expect(server.requests).to be_empty
        expect(run.lines.length).to eq(1)
        expect(run.stderr).to be_empty
        expect(run.exit_status).to eq(0)
      end
    end
  end

  # `rspec --dry-run` builds and reports every example without executing one
  # body, and this is the only level at which that can be tested: dry-run mode
  # is a property of the *process* RSpec is running in, so the suite you are
  # reading cannot enter it without disabling itself.
  #
  # The dishonesty is worth stating exactly, because it is what the refusal is
  # for. Run normally, MIXED_SUITE is `3 examples, 1 failure, 1 pending` and
  # exits 1. Run with `--dry-run` it is `3 examples, 0 failures`, exits 0, and
  # every example carries `outcome: "passed"` with a duration around 1e-5s —
  # the cost of constructing an example, not of running one. Delivered, that is
  # an all-green, near-instant run that overwrites a repository's headline and
  # is indistinguishable from a fast, healthy suite.
  #
  # Each block below pairs the dry run with a *normal* run of the same suite
  # through the same harness. Without that control, an example asserting "no
  # POST arrived" and "no line was written" would pass just as happily if the
  # child had died on an unrecognised flag, or if the stub had never come up.
  describe "when rspec is invoked with --dry-run" do
    describe "with an API key and an endpoint in scope" do
      before(:context) do
        StubIngestEndpoint.run(status: 202) do |server|
          @dry = run_rspec(FormatterRunHelpers::MIXED_SUITE, dry_run: true,
                           prepare: ->(_root) { transport_env(server) })
          @dry_requests = server.requests

          @normal = run_rspec(FormatterRunHelpers::MIXED_SUITE,
                              prepare: ->(_root) { transport_env(server) })
          @normal_requests = server.requests - @dry_requests
        end
      end

      # The control, first: identical environment, identical suite, flag
      # removed. If this ever goes empty the assertions below are vacuous.
      # @intent: { entity: "RSpecFormatter dry run", action: "deliver the same suite without the flag", behavior: "the same suite in the same environment without the dry-run flag delivers normally", layer: "integration" }
      it "delivers the same suite in the same environment without the flag" do
        expect(@normal_requests.length).to eq(1)
        expect(@normal_requests.first.json["specs"].length).to eq(3)
      end

      # SPGD-154 criterion 1: "`rspec --dry-run` with SPECGUARD_API_KEY and
      # SPECGUARD_ENDPOINT set issues zero HTTP requests".
      # @intent: { entity: "RSpecFormatter dry run", action: "refuse to deliver", behavior: "a dry run with a key and endpoint in scope issues no HTTP request at all", layer: "integration" }
      it "issues no HTTP request at all" do
        expect(@dry_requests).to be_empty
      end

      # ...and the child really did run, with the flag really taking effect —
      # so "no request" is a refusal rather than a process that never started.
      # @intent: { entity: "RSpecFormatter dry run", action: "refuse to deliver", behavior: "the dry run still runs, reporting the dry-run own all-green summary", layer: "integration" }
      it "still ran the suite, reporting the dry run's own all-green summary" do
        expect(@dry.stdout).to include("3 examples, 0 failures")
      end

      # @intent: { entity: "RSpecFormatter dry run", action: "refuse to deliver", behavior: "a dry run writes no local fallback either, a refusal not being a delivery failure", layer: "integration" }
      it "writes no local fallback either — a refusal is not a delivery failure" do
        expect(@dry.lines).to be_empty
      end
    end

    describe "with no API key, so the local sink is the only candidate" do
      before(:context) do
        @dry = run_rspec(FormatterRunHelpers::GREEN_SUITE, dry_run: true)
        @normal = run_rspec(FormatterRunHelpers::GREEN_SUITE)
      end

      # Control again: this suite, this harness, this sink, without the flag.
      # @intent: { entity: "RSpecFormatter dry run", action: "keep the sink empty", behavior: "the same suite without the flag appends its line to the sink as usual", layer: "integration" }
      it "appends a line for the same suite without the flag" do
        expect(@normal.lines.length).to eq(1)
      end

      # SPGD-154 criterion 2: "`rspec --dry-run` with no API key appends no
      # line to log/test_results.jsonl (absent, or byte-identical to before)".
      # A .jsonl of zero-duration all-green runs is the same
      # corruption as a delivered one, deferred until something replays it.
      # @intent: { entity: "RSpecFormatter dry run", action: "keep the sink empty", behavior: "the dry run appends nothing to the local sink", layer: "integration" }
      it "appends nothing to log/test_results.jsonl" do
        expect(@dry.lines).to be_empty
      end

      # ...and the child really did run, with the flag really taking effect —
      # so "nothing was written" is a refusal rather than a process that never
      # started.
      # @intent: { entity: "RSpecFormatter dry run", action: "keep the sink empty", behavior: "the dry run still runs, reporting the all-green summary", layer: "integration" }
      it "still ran the suite, reporting the dry run's own all-green summary" do
        expect(@dry.stdout).to include("1 example, 0 failures")
      end

      # The stronger half of the same criterion, and the reason this is a
      # separate example: `lines` is `[]` for an absent sink *and* for an empty
      # one, so only `sink_exists` can distinguish "never appended" from
      # "appended nothing". `#append` is never reached at all.
      # @intent: { entity: "RSpecFormatter dry run", action: "keep the sink empty", behavior: "the dry run does not even create the sink file", layer: "integration" }
      it "does not even create the sink" do
        expect(@dry.sink_exists).to be(false)
        expect(@normal.sink_exists).to be(true)
      end
    end

    # SPGD-154 criterion 4: "the dry run's own exit code is unchanged and at
    # most one stderr line is emitted". The never-block-CI contract is not
    # suspended by the refusal:
    # a dry run is somebody's lint job, and it must exit on its own terms.
    describe "the contract the refusal must not break" do
      before(:context) do
        @dry = run_rspec(FormatterRunHelpers::MIXED_SUITE, dry_run: true)
      end

      # @intent: { entity: "RSpecFormatter dry run refusal contract", action: "keep the exit status", behavior: "the dry-run refusal leaves the dry run own exit status alone", layer: "integration" }
      it "leaves the dry run's own exit status alone" do
        expect(@dry.exit_status).to eq(0)
      end

      # @intent: { entity: "RSpecFormatter dry run refusal contract", action: "say it once", behavior: "the refusal is said once on stderr rather than leaving the user to wonder", layer: "integration" }
      it "says so once on stderr, rather than leaving the user to wonder" do
        expect(@dry.stderr.scan(/SpecGuard:/).length).to eq(1)
        expect(@dry.stderr).to include("dry run")
      end

      # @intent: { entity: "RSpecFormatter dry run refusal contract", action: "leave stdout alone", behavior: "stdout stays the human formatter own through the refusal", layer: "integration" }
      it "leaves stdout to the human formatter" do
        expect(@dry.stdout).not_to include("SpecGuard:")
      end
    end

    # SPGD-639. The refusal above throws away a verdict the formatter had
    # already computed: `status` comes from the annotation lookup, which reads
    # source text, so unlike `duration` and `outcome` it is fabricated by
    # neither dry-run mechanism. A dry run builds every example, so it holds
    # the whole numerator and denominator of the adoption metric.
    #
    # `ANNOTATED_SUITE` is the fixture for this and needs nothing added to it:
    # 6 examples, 3 annotated, with the malformed and schema-invalid cases
    # included precisely because they must count as unannotated in the report
    # exactly as they do in the payload.
    describe "reporting local annotation coverage instead of discarding it" do
      before(:context) do
        @dry = run_rspec(FormatterRunHelpers::ANNOTATED_SUITE, dry_run: true)
        @normal = run_rspec(FormatterRunHelpers::ANNOTATED_SUITE)
      end

      # @intent: { entity: "RSpecFormatter local coverage report", action: "name the numbers", behavior: "the report names the denominator, the numerator and the gap between them", layer: "integration" }
      it "names the denominator, the numerator and the gap" do
        expect(@dry.stderr).to include("6 examples, 3 annotated, 3 unannotated (50% annotated)")
      end

      # Exactly the three the fixture documents at its definition — the
      # unannotated one, the unterminated literal, and the `entiity` typo — and
      # exactly not the three that are annotated. A report that listed the
      # malformed ones as annotated, or skipped them, would be the same defect
      # the payload's `status` field exists to prevent.
      # @intent: { entity: "RSpecFormatter local coverage report", action: "list the gap", behavior: "precisely the unannotated examples are listed, each by its definition site", layer: "integration" }
      it "lists precisely the unannotated examples, by definition site" do
        worklist = @dry.stderr.lines.grep(/sample_spec\.rb:/).map(&:strip)

        expect(worklist.length).to eq(3)
        expect(worklist[0]).to start_with("sample_spec.rb:7")
        expect(worklist[1]).to start_with("sample_spec.rb:16")
        expect(worklist[2]).to start_with("sample_spec.rb:21")
        expect(worklist.join("\n")).to include("has no annotation", "has a malformed annotation",
                                               "has a schema-invalid annotation")
      end

      # The worklist carries `full_description`, not merely the site, so the
      # local list and the server's `latest_run.unannotated_examples` have the
      # same shape — and the nested example proves the description is the
      # example's own and not the file's.
      # @intent: { entity: "RSpecFormatter local coverage report", action: "carry the names", behavior: "each example full description travels alongside its site", layer: "integration" }
      it "carries each example's full description alongside its site" do
        expect(@dry.stderr).to include("user has no annotation")
      end

      # A fact about the working tree, not about the last delivered run. Those
      # legitimately differ the moment a spec is edited, which is the entire
      # point, so the line must not read as the dashboard's headline.
      # @intent: { entity: "RSpecFormatter local coverage report", action: "scope the claim", behavior: "the report says which tree it measured and does not claim to speak for the repository", layer: "integration" }
      it "says which tree it measured, and does not claim to speak for the repository" do
        expect(@dry.stderr).to include("this working tree")
        expect(@dry.stderr).not_to include("your repository")
      end

      # Criterion 6, measured rather than asserted. The local figure is
      # recomputed here from a payload captured by a *normal* run of the same
      # fixture, using the platform's own predicate (`annotated_specs` rejects
      # "unannotated"). Two counters over one source-derived field.
      # @intent: { entity: "RSpecFormatter local coverage report", action: "agree with the payload", behavior: "the report counts agree with the payload a normal run of the same tree produces", layer: "integration" }
      it "agrees with the payload a normal run of the same tree produces" do
        specs = JSON.parse(@normal.lines.fetch(0)).fetch("specs")
        unannotated = specs.reject { |spec| spec["status"] == "annotated" }

        expect(specs.length).to eq(6)
        expect(unannotated.length).to eq(3)
        expect(@dry.stderr).to include("#{specs.length} examples, " \
                                       "#{specs.length - unannotated.length} annotated, " \
                                       "#{unannotated.length} unannotated")
      end

      # SPGD-154 criteria 1 and 2, re-asserted against the suite that now has
      # something to say. A third destination was added; neither sink moved.
      # @intent: { entity: "RSpecFormatter local coverage report", action: "publish nothing", behavior: "the dry-run report publishes nothing, no POST, no sink line, not even a file", layer: "integration" }
      it "still publishes nothing — no POST, no line, not even a sink" do
        expect(@dry.lines).to be_empty
        expect(@dry.sink_exists).to be(false)
        expect(@normal.sink_exists).to be(true)
      end

      # @intent: { entity: "RSpecFormatter local coverage report", action: "stay off the outputs", behavior: "the report leaves the exit status and stdout alone", layer: "integration" }
      it "still leaves the exit status and stdout alone" do
        expect(@dry.exit_status).to eq(0)
        expect(@dry.stdout).to include("6 examples, 0 failures")
        expect(@dry.stdout).not_to include("SpecGuard:")
      end

      # One `SpecGuard:` voice per run, however many lines the report needs.
      # @intent: { entity: "RSpecFormatter local coverage report", action: "stay under one header", behavior: "the whole report stays under a single SpecGuard-prefixed header", layer: "integration" }
      it "keeps the whole report under a single SpecGuard-prefixed header" do
        expect(@dry.stderr.scan(/SpecGuard:/).length).to eq(1)
        expect(@dry.stderr.lines.length).to eq(5)
      end

      # The control that stops all of the above being vacuously green: without
      # the flag, this same suite says none of it and writes its line as usual.
      # @intent: { entity: "RSpecFormatter local coverage report", action: "stay silent on normal runs", behavior: "none of the report appears on a normal run, which delivers as before", layer: "integration" }
      it "says none of this on a normal run, which delivers as before" do
        expect(@normal.stderr).to be_empty
        expect(@normal.lines.length).to eq(1)
      end

      # The worklist is ordered by definition site, not by the order RSpec
      # happened to build the examples in — so two runs of the same tree
      # produce a diffable list.
      #
      # This example is only worth its runtime because the seed discriminates:
      # measured at `FIXED_SEED`, capture order is 7, 21, 16, so an
      # implementation that emitted the list as captured fails here. (Under the
      # file's default defined ordering the two orders coincide, which is why
      # none of the examples above can make this claim.)
      # @intent: { entity: "RSpecFormatter local coverage report", action: "order the worklist", behavior: "the unannotated worklist is ordered by site even when RSpec ran the examples shuffled", layer: "integration" }
      it "orders the worklist by site even when RSpec ran the examples shuffled" do
        shuffled = run_rspec(FormatterRunHelpers::ANNOTATED_SUITE, dry_run: true, order: :random)
        worklist = shuffled.stderr.lines.grep(/sample_spec\.rb:/).map(&:strip)

        expect(worklist.map { |line| line[/:(\d+)/, 1] }).to eq(%w[7 16 21])
      end
    end
  end

  # Criterion 6, at the process level, for slice 2's own failure modes.
  #
  # The lookup reads spec files off disk and compiles a JSON Schema, so it can
  # fail in ways slice 1's capture layer could not: a spec file that is not
  # readable, one that is not valid UTF-8, a vendored schema that will not load.
  # The suite under test here is otherwise entirely ordinary — what is broken is
  # SpecGuard, and the numbers below are the ones the shell reads back.
  describe "when the annotation scanner blows up" do
    before(:context) do
      @green = run_rspec(FormatterRunHelpers::GREEN_SUITE, sabotage: true)
      @red = run_rspec(FormatterRunHelpers::MIXED_SUITE, sabotage: true)
    end

    # @intent: { entity: "RSpecFormatter broken scanner", action: "never redden a green suite", behavior: "a scanner that blows up still exits zero for a green suite", layer: "integration" }
    it "still exits 0 for a green suite" do
      expect(@green.stdout).to include("1 example, 0 failures")
      expect(@green.exit_status).to eq(0)
    end

    # @intent: { entity: "RSpecFormatter broken scanner", action: "never touch a red one", behavior: "the broken scanner still exits one for a failing suite", layer: "integration" }
    it "still exits 1 for a failing suite" do
      expect(@red.stdout).to include("3 examples, 1 failure, 1 pending")
      expect(@red.exit_status).to eq(1)
    end

    # @intent: { entity: "RSpecFormatter broken scanner", action: "survive the blow-up", behavior: "the blow-up is survived with the run still recorded", layer: "integration" }
    it "warns once on stderr, and leaves stdout to the human formatter" do
      expect(@red.stderr.scan(/SpecGuard: test telemetry failed/).length).to eq(1)
      expect(@red.stdout).not_to include("SpecGuard:")
    end

    # The distinction the inner rescue exists for. A failure this deep must cost
    # the run its *annotations*, not its examples — a payload of zero specs
    # would be indistinguishable from a suite nobody ran.
    # @intent: { entity: "RSpecFormatter broken scanner", action: "survive the blow-up", behavior: "the affected examples are reported unannotated rather than lost", layer: "integration" }
    it "still records every example, as unannotated" do
      expect(@red.payload["specs"].length).to eq(3)
      expect(@red.payload["specs"].map { |spec| spec["status"] }).to all(eq("unannotated"))
    end

    # @intent: { entity: "RSpecFormatter broken scanner", action: "stay quiet", behavior: "the scanner failure says nothing that would pollute the run output", layer: "integration" }
    it "still produces a payload the platform would accept" do
      violations = @red.payload["specs"].each_with_index.flat_map do |spec, index|
        IngestContract.errors_for(spec, index)
      end

      expect(violations).to be_empty
    end
  end
end
