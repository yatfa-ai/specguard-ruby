# frozen_string_literal: true

require "tmpdir"
require "specguard/rspec/formatter"

require_relative "../../support/stub_ingest_endpoint"

# What the formatter captures, where it puts it, and — the part that matters
# most — what it does when any of that goes wrong.
#
# RSpec does not sandbox formatters. A raise in `example_finished`, `stop` or
# `close` escapes `RSpec::Core::Runner.run`, RSpec's own exit code is never
# returned, and the process exits 1 — a green suite turned red by telemetry.
# Every "does not raise" example below therefore fails the moment the
# corresponding rescue is removed, which is the whole point of writing them.
# The process-level half of that proof (real exit codes from a real subprocess)
# lives in formatter_run_spec.rb.
RSpec.describe SpecGuard::RSpecFormatter do
  subject(:formatter) { described_class.new(output, error_stream: errors, annotations: annotations) }

  let(:output) { StringIO.new }
  let(:errors) { StringIO.new }
  let(:sink) { File.join(tmpdir, "log", "test_results.jsonl") }
  let(:local_sink) { File.join(tmpdir, "log", "test_results.local.jsonl") }

  # Injected rather than real: what an annotation *is* belongs to
  # annotation_lookup_spec.rb, and resolving one here would make every example
  # below depend on a spec file existing at the path the double reports.
  # Answering nil is "unannotated", which is what every example that does not
  # say otherwise expects.
  let(:annotations) { instance_double(SpecGuard::RSpec::AnnotationLookup, intent_for: nil) }

  let(:intent) do
    { "entity" => "Order", "action" => "checkout",
      "behavior" => "returns 402 payment required on expired card", "layer" => "request" }
  end

  attr_reader :tmpdir

  # Each example gets its own project root, and the global configuration is
  # rebuilt around it — the formatter reads a process-wide singleton, so a spec
  # that leaked its output path would silently redirect every later one.
  #
  # `endpoint` and `api_key` are pinned to nil rather than left alone for the
  # same reason: `Configuration.new` seeds from the *real* ENV, so a developer
  # who happened to export `SPECGUARD_API_KEY` would have every example in this
  # file quietly POSTing somewhere instead of writing the file it asserts on.
  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      SpecGuard::RSpec.reset_configuration!
      SpecGuard::RSpec.configure do |config|
        config.output_path = File.join(dir, "log", "test_results.jsonl")
        config.local_output_path = File.join(dir, "log", "test_results.local.jsonl")
        config.commit_sha = "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2"
        config.branch = "main"
        # Pinned for the same reason `endpoint` and `api_key` are: `Configuration.new` seeds from
        # the real ENV, and this suite runs inside CI jobs that export `GITHUB_RUN_ID` — so left
        # alone, the envelope examples below would assert against whatever build happened to be
        # running them.
        config.run_id = "gha-1234567890"
        # And `shard_id` for a sharper version of it: this gem's own suite may itself be run under
        # `parallel_tests`, which exports `TEST_ENV_NUMBER` — so unpinned, these examples would
        # pass single-process and fail only when someone ran the suite in parallel.
        config.shard_id = "shard-2"
        config.endpoint = nil
        config.api_key = nil
      end
      example.run
    ensure
      SpecGuard::RSpec.reset_configuration!
    end
  end

  # `rerun_file_path` defaults to `file_path` and `id` is built from it, which is
  # exactly the relationship RSpec itself maintains
  # (`metadata.rb:160`, `metadata.rb:105`) — so the default double is an
  # *ordinary* example, where the owning file and the definition file coincide.
  # The shared-example case, where they diverge, is the one worth passing them
  # apart for.
  def build_example(name: "user when signed in can order an item",
                    file_path: "./spec/orders_spec.rb",
                    line_number: 4,
                    run_time: 0.0109,
                    status: :passed,
                    rerun_file_path: file_path,
                    id: "#{rerun_file_path}[1:1]")
    execution_result = instance_double(RSpec::Core::Example::ExecutionResult,
                                       run_time: run_time, status: status)

    instance_double(RSpec::Core::Example,
                    full_description: name,
                    id: id,
                    metadata: { file_path: file_path, line_number: line_number,
                                rerun_file_path: rerun_file_path },
                    execution_result: execution_result)
  end

  def finish(example)
    formatter.example_finished(instance_double(RSpec::Core::Notifications::ExampleNotification,
                                               example: example))
  end

  def sink_lines
    File.exist?(sink) ? File.readlines(sink, chomp: true) : []
  end

  def local_sink_lines
    File.exist?(local_sink) ? File.readlines(local_sink, chomp: true) : []
  end

  describe "registration" do
    # Criterion 1's precondition. RSpec only delivers the notifications a
    # formatter registered for, so a hook implemented but not registered is
    # dead code that fails silently — the run completes, the file never appears.
    #
    # `:seed` and `:message` are the odd ones out and are deliberately in the
    # list. This formatter has nothing to say about either.
    #
    # `:seed` is the first notification of a run and is where `#seed` restores
    # the human formatter that registering this one suppressed (SPGD-195). Drop
    # it from this list and that repair becomes dead code — a silent run, exactly
    # as before.
    #
    # `:message` is registered for the sake of the registration itself.
    # `setup_default` installs a `FallbackMessageFormatter` unless some already
    # registered formatter listens for `:message`
    # (`rspec-core-3.13.6 formatters.rb:133-135`), and that fallback then prints
    # every message a second time alongside the formatter `#seed` restores. Drop
    # `:message` here and `#message` becomes dead code *and* the duplication
    # comes back — this list is the only thing that decides whether either hook
    # is ever called.
    # @intent: { entity: "RSpecFormatter", action: "register with RSpec", behavior: "the formatter subscribes to exactly the five notifications it implements", layer: "unit" }
    it "is registered for the five notifications it implements" do
      registered = RSpec::Core::Formatters::Loader.formatters[described_class]

      expect(registered).to contain_exactly(:example_finished, :stop, :close, :seed, :message)
    end

    # @intent: { entity: "RSpecFormatter", action: "register with RSpec", behavior: "being a BaseFormatter, RSpec accepts it as an additional format alongside the usual one", layer: "unit" }
    it "is a BaseFormatter, so RSpec accepts it as an additional --format" do
      expect(described_class.ancestors).to include(RSpec::Core::Formatters::BaseFormatter)
    end

    # The constant-resolution trap: `SpecGuard::RSpec` is this gem's own
    # namespace, so an unqualified `RSpec::Core` inside `module SpecGuard`
    # resolves to `SpecGuard::RSpec::Core` and raises. If that ever creeps back
    # in, the superclass is the first thing to go wrong.
    # @intent: { entity: "RSpecFormatter", action: "register with RSpec", behavior: "the superclass is the real RSpec BaseFormatter, not the gem same-named namespace", layer: "unit" }
    it "inherits from the real RSpec's BaseFormatter, not from SpecGuard::RSpec" do
      expect(described_class.superclass).to equal(::RSpec::Core::Formatters::BaseFormatter)
    end
  end

  # The `#seed` hook restores the human formatter that registering this one
  # suppresses (SPGD-195), and it does that by mutating `RSpec.configuration` —
  # the *live, global* one, mid-run. Its real behaviour is pinned in
  # formatter_run_spec.rb, in a real `rspec` process where the output can
  # actually be observed. What these two examples pin instead is *when it
  # declines to act*, which a subprocess cannot show.
  #
  # A stand-in configuration is unavoidable here. The suite running this file
  # already has a `progress` formatter attached, so the hook's "somebody already
  # prints a summary" check would short-circuit every time and an assertion
  # against the real configuration would pass no matter what the guard did.
  # It is injected through the formatter's own `rspec_configuration` rather than
  # by stubbing `::RSpec.configuration`, because rspec-core keeps reading that
  # singleton while the example runs and would ask the double for `dry_run?`.
  describe "#seed" do
    let(:elsewhere) do
      instance_double(::RSpec::Core::Configuration, formatters: registered, default_formatter: "progress")
    end

    before do
      allow(elsewhere).to receive(:add_formatter)
      allow(formatter).to receive(:rspec_configuration).and_return(elsewhere)
    end

    # The guard that keeps this hook inert outside a real run. Every other
    # example in this file drives the hooks in-process against a formatter RSpec
    # never registered; without this check, each `seed` call would bolt a
    # progress formatter onto the suite that is running that very example.
    context "when this formatter is not among the configuration's formatters" do
      let(:registered) { [] }

      # @intent: { entity: "RSpecFormatter seed", action: "leave foreign runs alone", behavior: "when this formatter is not among the configured formatters, seed touches nothing", layer: "unit" }
      it "does not touch the configuration" do
        formatter.seed(nil)

        expect(elsewhere).not_to have_received(:add_formatter)
      end
    end

    # The other side, so the guard above cannot be satisfied by a hook that
    # simply never does anything.
    context "when this formatter is registered and nothing else reports the run" do
      let(:registered) { [formatter] }

      # @intent: { entity: "RSpecFormatter seed", action: "restore the default formatter", behavior: "when registered alone it restores the configured default formatter so the run still prints", layer: "unit" }
      it "restores the configured default formatter" do
        formatter.seed(nil)

        expect(elsewhere).to have_received(:add_formatter).with("progress")
      end
    end

    # The case that separates "somebody will print a summary" from "somebody is
    # reporting the run", and the reason the question is asked in the second
    # form. `--format failures` (`FailureListFormatter`) prints one line per
    # failure and never a summary, so a `dump_summary`-only check read this
    # developer as unserved and added a whole progress run on top of the
    # formatter they had named: 32 bytes of failure list became 427 bytes of
    # dots, backtrace and summary.
    #
    # The real class, not a double, because what is being pinned is a fact about
    # a formatter rspec-core ships — a double would just restate whichever answer
    # this spec was written to expect.
    context "when another formatter reports the run without printing a summary" do
      let(:registered) do
        [formatter, ::RSpec::Core::Formatters::FailureListFormatter.new(StringIO.new)]
      end

      # @intent: { entity: "RSpecFormatter seed", action: "leave foreign runs alone", behavior: "when another formatter already reports the run, seed leaves the configuration alone", layer: "unit" }
      it "leaves the configuration alone" do
        formatter.seed(nil)

        expect(elsewhere).not_to have_received(:add_formatter)
      end
    end
  end

  # `#message` is `RSpec::Core::Formatters::FallbackMessageFormatter` under this
  # class's roof, and it exists because of the registration rather than the other
  # way round: `setup_default` appoints that fallback unless some registered
  # formatter listens for `:message` (`formatters.rb:133-135`), and once `#seed`
  # restores `progress` — which listens for it too — the fallback prints every
  # message a second time. Listening here stops it being appointed, and this
  # method takes over its duty.
  #
  # The end-to-end proof is in formatter_run_spec.rb, where a suite whose
  # `after(:context)` hook raises is diffed against the same suite run without
  # SpecGuard. What these examples pin is the branch, which a subprocess cannot
  # isolate: the stand-in configuration is injected through `rspec_configuration`
  # for the same reason `#seed`'s is.
  describe "#message" do
    let(:notification) do
      ::RSpec::Core::Notifications::MessageNotification.new("An error occurred outside of examples")
    end

    let(:elsewhere) { instance_double(::RSpec::Core::Configuration, formatters: registered) }

    before { allow(formatter).to receive(:rspec_configuration).and_return(elsewhere) }

    # The last-resort case, and the one the fallback used to cover: this
    # formatter is the only listener, so the message has nowhere else to go.
    # Without this, suppressing the fallback would trade a duplicated message for
    # a missing one — which is the same defect as SPGD-195 wearing the opposite
    # sign.
    context "when no other registered formatter handles messages" do
      let(:registered) { [formatter] }

      # @intent: { entity: "RSpecFormatter message", action: "relay messages", behavior: "with no other message-handling formatter, message prints exactly the fallback RSpec would have printed", layer: "unit" }
      it "prints the message, exactly as RSpec's fallback would have" do
        formatter.message(notification)

        expect(output.string).to eq("An error occurred outside of examples\n")
      end
    end

    # The duplication case. `progress` handles `:message` via
    # `BaseTextFormatter`, so after `#seed` has restored it there are two
    # candidates and only one may print.
    context "when another registered formatter handles messages" do
      let(:registered) do
        [formatter, ::RSpec::Core::Formatters::ProgressFormatter.new(StringIO.new)]
      end

      # @intent: { entity: "RSpecFormatter message", action: "relay messages", behavior: "when another formatter handles messages this one stays quiet", layer: "unit" }
      it "stays quiet and lets that formatter print it" do
        formatter.message(notification)

        expect(output.string).to be_empty
      end
    end

    # The same inertness guard `#seed` carries. This object only owes anybody a
    # message because RSpec registered it and therefore skipped appointing its
    # own fallback; a formatter RSpec never registered — every other example in
    # this file — owes nothing and must write nothing.
    context "when this formatter is not among the configuration's formatters" do
      let(:registered) { [] }

      # @intent: { entity: "RSpecFormatter message", action: "leave foreign runs alone", behavior: "when not among the configured formatters, message writes nothing", layer: "unit" }
      it "writes nothing" do
        formatter.message(notification)

        expect(output.string).to be_empty
      end
    end
  end

  describe "#payload" do
    # @intent: { entity: "RSpecFormatter payload", action: "carry the run envelope", behavior: "the payload envelope carries commit, branch and duration from the configuration", layer: "unit" }
    it "carries the run envelope from the configuration" do
      formatter.stop(nil)

      expect(formatter.payload).to include(
        "commit_sha" => "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2",
        "branch" => "main"
      )
    end

    # Without this, a sharded suite has no way to say its N POSTs are one run,
    # and the platform records N `TestRun` rows each holding a fraction of the
    # denominator — a 20,000-example suite reported as ~5,000, attributed to the
    # right commit, with nothing on the dashboard able to show it is partial.
    #
    # The setting is `run_id` and the wire field is `ci_run_id` on purpose: the
    # keys of this Hash are the platform's names, spelled as `TestRun` spells
    # them, and the setting names are this gem's.
    # @intent: { entity: "RSpecFormatter payload", action: "carry the run envelope", behavior: "the ci run id is named with the platform own key rather than the gem setting name", layer: "unit" }
    it "names the CI run the shard belongs to, under the platform's own key" do
      formatter.stop(nil)

      expect(formatter.payload).to include("ci_run_id" => "gha-1234567890")
    end

    # The laptop path. A run nobody's CI provider named still ships a complete
    # envelope; the platform reads the nil as "this run is its own run".
    # @intent: { entity: "RSpecFormatter payload", action: "carry the run envelope", behavior: "a missing run id is an explicit null key, not an omitted one", layer: "unit" }
    it "sends an explicit null run id rather than omitting the key" do
      SpecGuard::RSpec.configure { |config| config.run_id = nil }
      formatter.stop(nil)

      expect(formatter.payload).to have_key("ci_run_id")
      expect(formatter.payload["ci_run_id"]).to be_nil
    end

    # The other half of the run identity. A CI run id survives a re-run by
    # design (`GITHUB_RUN_ID` is documented as unchanged across attempts), so
    # this is what lets the platform tell a shard reporting for the second time
    # from a shard reporting for the first — and therefore replace its numbers
    # rather than add them.
    # @intent: { entity: "RSpecFormatter payload", action: "carry the run envelope", behavior: "the shard id names which shard of the run this process is", layer: "unit" }
    it "names which shard of that run this process is" do
      formatter.stop(nil)

      expect(formatter.payload).to include("shard_id" => "shard-2")
    end

    # @intent: { entity: "RSpecFormatter payload", action: "carry the run envelope", behavior: "a missing shard id is an explicit null key, not an omitted one", layer: "unit" }
    it "sends an explicit null shard id rather than omitting the key" do
      SpecGuard::RSpec.configure { |config| config.shard_id = nil }
      formatter.stop(nil)

      expect(formatter.payload).to have_key("shard_id")
      expect(formatter.payload["shard_id"]).to be_nil
    end

    # @intent: { entity: "RSpecFormatter payload", action: "carry the run envelope", behavior: "the run duration is non-negative once the suite has stopped", layer: "unit" }
    it "reports a non-negative run duration once the suite has stopped" do
      formatter.stop(nil)

      expect(formatter.payload["duration_seconds"]).to be_a(Float).and be >= 0
    end

    # Criterion 4. The unannotated majority is the population SpecGuard exists
    # to measure; a formatter that filtered here would report an empty first run
    # to every new adopter.
    # @intent: { entity: "RSpecFormatter payload", action: "record examples", behavior: "one entry appears per example, in the order they finished", layer: "unit" }
    it "records one entry per example, in the order they finished" do
      3.times { |i| finish(build_example(name: "example #{i}", line_number: i + 1)) }

      expect(formatter.payload["specs"].map { |spec| spec["name"] })
        .to eq(["example 0", "example 1", "example 2"])
    end

    # Criterion 3, at the unit level; formatter_run_spec.rb proves the same
    # thing against a real nested describe/context.
    # @intent: { entity: "RSpecFormatter payload", action: "record examples", behavior: "the recorded name is the example full description, verbatim", layer: "unit" }
    it "records the name as full_description, verbatim" do
      finish(build_example(name: "user when signed in can order an item"))

      expect(formatter.payload["specs"].first["name"]).to eq("user when signed in can order an item")
    end

    # @intent: { entity: "RSpecFormatter payload", action: "record examples", behavior: "each entry records its line number, duration and outcome", layer: "unit" }
    it "records the line number, duration and outcome of each example" do
      finish(build_example(line_number: 42, run_time: 0.0109, status: :failed))

      expect(formatter.payload["specs"].first).to include(
        "line_number" => 42,
        "duration" => 0.0109,
        "outcome" => "failed"
      )
    end

    # A Symbol serializes to a JSON string either way, but leaving it a Symbol
    # here means an in-process consumer compares `:passed` against the `"passed"`
    # every JSON reader hands back, and quietly matches nothing.
    # @intent: { entity: "RSpecFormatter payload", action: "record examples", behavior: "the outcome is recorded as a String, not the Symbol RSpec reports", layer: "unit" }
    it "records the outcome as a String, not the Symbol RSpec reports" do
      finish(build_example(status: :pending))

      expect(formatter.payload["specs"].first["outcome"]).to eq("pending").and be_a(String)
    end

    describe "file paths" do
      # @intent: { entity: "RSpecFormatter payload", action: "normalize file paths", behavior: "the dot-slash prefix RSpec puts on project-relative paths is stripped", layer: "unit" }
      it "strips the ./ prefix RSpec puts on a project-relative path" do
        finish(build_example(file_path: "./spec/orders_spec.rb"))

        expect(formatter.payload["specs"].first["file_path"]).to eq("spec/orders_spec.rb")
      end

      # @intent: { entity: "RSpecFormatter payload", action: "normalize file paths", behavior: "an absolute path under the project root is relativized to it", layer: "unit" }
      it "relativizes an absolute path that lies under the project root" do
        finish(build_example(file_path: File.join(Dir.pwd, "spec", "orders_spec.rb")))

        expect(formatter.payload["specs"].first["file_path"]).to eq("spec/orders_spec.rb")
      end

      # @intent: { entity: "RSpecFormatter payload", action: "normalize file paths", behavior: "a path outside the project root stays absolute rather than being invented relative", layer: "unit" }
      it "leaves a path outside the project root absolute rather than inventing one" do
        finish(build_example(file_path: "/elsewhere/orders_spec.rb"))

        expect(formatter.payload["specs"].first["file_path"]).to eq("/elsewhere/orders_spec.rb")
      end
    end
  end

  # `(file_path, line_number)` is the coordinate of the *code*. Two ordinary
  # suite shapes — a table-driven loop, a shared example group — put several
  # examples on one coordinate, so it cannot be the key. These pin the two
  # fields that can be.
  #
  # What a double can prove here is that the formatter *records* both fields,
  # relativizes them like every other path, and never repurposes the coordinate.
  # It cannot prove that RSpec's real `id` is distinct across a loop, because the
  # double is simply told what to answer — that half is in formatter_run_spec.rb,
  # against a real `rspec` process.
  describe "#payload — example identity" do
    # @intent: { entity: "RSpecFormatter payload", action: "identify examples", behavior: "the row carries RSpec own example id", layer: "unit" }
    it "records RSpec's own example id" do
      finish(build_example(id: "./spec/orders_spec.rb[1:2]"))

      expect(formatter.payload["specs"].first["id"]).to eq("./spec/orders_spec.rb[1:2]")
    end

    # @intent: { entity: "RSpecFormatter payload", action: "identify examples", behavior: "several examples sharing one definition line still get one row each", layer: "unit" }
    it "keeps one row per example when several share a definition line" do
      3.times { |i| finish(build_example(line_number: 4, id: "./spec/table_spec.rb[1:#{i + 1}]")) }

      expect(formatter.payload["specs"].map { |spec| spec["id"] })
        .to eq(["./spec/table_spec.rb[1:1]", "./spec/table_spec.rb[1:2]", "./spec/table_spec.rb[1:3]"])
      expect(formatter.payload["specs"].map { |spec| spec["line_number"] }).to all(eq(4))
    end

    # @intent: { entity: "RSpecFormatter payload", action: "identify examples", behavior: "the spec file named is the one that ran the example, not only the one that defined it", layer: "unit" }
    it "names the spec file that ran the example, not only the one that defined it" do
      finish(build_example(file_path: "./spec/support/shared_examples.rb",
                           rerun_file_path: "./spec/orders_spec.rb"))

      expect(formatter.payload["specs"].first).to include(
        "spec_file_path" => "spec/orders_spec.rb",
        "file_path" => "spec/support/shared_examples.rb"
      )
    end

    # The ordinary case, which is nearly every example: the two coincide, so a
    # consumer that groups by `spec_file_path` groups by the file a reader would
    # have named anyway.
    # @intent: { entity: "RSpecFormatter payload", action: "identify examples", behavior: "an ordinary example reports the definition file as its owning file", layer: "unit" }
    it "reports the owning file as the definition file for an ordinary example" do
      finish(build_example(file_path: "./spec/orders_spec.rb"))

      expect(formatter.payload["specs"].first["spec_file_path"]).to eq("spec/orders_spec.rb")
    end

    # @intent: { entity: "RSpecFormatter payload", action: "identify examples", behavior: "the owning file loses its dot-slash prefix exactly like the file path does", layer: "unit" }
    it "strips the ./ prefix off the owning file, exactly as it does for file_path" do
      finish(build_example(file_path: File.join(Dir.pwd, "spec", "orders_spec.rb"),
                           rerun_file_path: "./spec/users_spec.rb"))

      expect(formatter.payload["specs"].first).to include(
        "spec_file_path" => "spec/users_spec.rb",
        "file_path" => "spec/orders_spec.rb"
      )
    end

    # RSpec defaults `:rerun_file_path` for every example it builds, so this is
    # unreachable in a real run — but a null here would silently drop a whole
    # file out of any by-file aggregate, and the definition site is the best
    # answer available.
    # @intent: { entity: "RSpecFormatter payload", action: "identify examples", behavior: "metadata without an owning file falls back to the definition file", layer: "unit" }
    it "falls back to the definition file when the metadata carries no owning file" do
      example = instance_double(RSpec::Core::Example,
                                full_description: "user can order an item",
                                id: "./spec/orders_spec.rb[1:1]",
                                metadata: { file_path: "./spec/orders_spec.rb", line_number: 4 },
                                execution_result: instance_double(RSpec::Core::Example::ExecutionResult,
                                                                  run_time: 0.01, status: :passed))
      finish(example)

      expect(formatter.payload["specs"].first["spec_file_path"]).to eq("spec/orders_spec.rb")
    end

    # The annotation is read off the `it` line, so the coordinate has to keep
    # meaning "definition site" however the example got there. A shared example
    # inherits the intent written next to the shared `it`, and repurposing
    # `file_path` to the including file would send the lookup to a line that
    # holds something else entirely.
    # @intent: { entity: "RSpecFormatter payload", action: "identify examples", behavior: "the annotation lookup is asked about the definition site, not the owning file", layer: "unit" }
    it "still asks the lookup about the definition site, not the owning file" do
      finish(build_example(file_path: "./spec/support/shared_examples.rb",
                           rerun_file_path: "./spec/orders_spec.rb",
                           line_number: 12))

      expect(annotations).to have_received(:intent_for)
        .with(file: "spec/support/shared_examples.rb", line: 12)
    end

    # Additive means additive: the seven fields the platform already reads must
    # come out of this change byte-identical for an ordinary example.
    # @intent: { entity: "RSpecFormatter payload", action: "identify examples", behavior: "adding the identity fields leaves every pre-existing payload field untouched", layer: "unit" }
    it "leaves every pre-existing field untouched" do
      allow(annotations).to receive(:intent_for).and_return(intent)
      finish(build_example(file_path: "./spec/orders_spec.rb", line_number: 42,
                           run_time: 0.0109, status: :failed))

      expect(formatter.payload["specs"].first).to include(
        "file_path" => "spec/orders_spec.rb",
        "line_number" => 42,
        "name" => "user when signed in can order an item",
        "duration" => 0.0109,
        "outcome" => "failed",
        "status" => "annotated",
        "intent" => intent
      )
    end
  end

  # Criterion 1. `status` is the field whose absence made slice 1's payload a
  # guaranteed 400: `Ingest::Payload#validate_status` appends an error for every
  # spec that lacks it, and `valid?` requires the error list to be empty, so the
  # run is rejected whole.
  describe "#payload — status and intent" do
    # @intent: { entity: "RSpecFormatter payload", action: "report annotation status", behavior: "an example the lookup resolves is reported annotated, carrying the intent", layer: "unit" }
    it "reports an example the lookup resolved as annotated, carrying the intent" do
      allow(annotations).to receive(:intent_for).and_return(intent)
      finish(build_example)

      expect(formatter.payload["specs"].first).to include("status" => "annotated", "intent" => intent)
    end

    # @intent: { entity: "RSpecFormatter payload", action: "report annotation status", behavior: "an example the lookup cannot resolve is reported unannotated", layer: "unit" }
    it "reports an example the lookup could not resolve as unannotated" do
      finish(build_example)

      expect(formatter.payload["specs"].first).to include("status" => "unannotated", "intent" => nil)
    end

    # `Ingest::Payload#validate_intent` reads intent by key, so a present null
    # and an absent key are equivalent to it. Writing it is for the human and
    # the archive: it is the difference between "we looked and found nothing"
    # and "this producer does not report annotations" — exactly the ambiguity
    # slice 1's payload could not resolve.
    # @intent: { entity: "RSpecFormatter payload", action: "report annotation status", behavior: "the intent key is written explicitly null rather than omitted", layer: "unit" }
    it "writes the intent key explicitly rather than omitting it" do
      finish(build_example)

      expect(formatter.payload["specs"].first).to have_key("intent")
    end

    # The lookup reads the file off disk, so it must be handed the path the
    # payload records and not RSpec's raw `./`-prefixed metadata — otherwise the
    # coordinate the platform stores and the coordinate the annotation was read
    # from are two different strings that only look alike.
    # @intent: { entity: "RSpecFormatter payload", action: "report annotation status", behavior: "the lookup is asked with the same file path the payload records and the example own line", layer: "unit" }
    it "asks about the same file path it records, and the example's own line" do
      finish(build_example(file_path: "./spec/orders_spec.rb", line_number: 42))

      expect(annotations).to have_received(:intent_for).with(file: "spec/orders_spec.rb", line: 42)
    end

    # @intent: { entity: "RSpecFormatter payload", action: "report annotation status", behavior: "each example is resolved independently of the others", layer: "unit" }
    it "resolves each example independently" do
      allow(annotations).to receive(:intent_for).and_return(intent, nil, intent)
      3.times { |i| finish(build_example(line_number: i + 1)) }

      expect(formatter.payload["specs"].map { |spec| spec["status"] })
        .to eq(%w[annotated unannotated annotated])
    end
  end

  # The README's **"What SpecGuard collects"** section enumerates every field
  # this gem transmits — six in the envelope, nine per example — with a line
  # each on what it holds and where it comes from. That enumeration is a promise
  # to a reader deciding whether this data may leave their perimeter, and a
  # promise only holds if breaking it breaks something.
  #
  # These two examples are that something. Nothing else in this file can be:
  # every other payload assertion here is `include`/`have_key`, which is
  # deliberately additive and stays green when a field is added. Correct for
  # them, useless for this — so these pin the **exact** key set with `eq` over
  # sorted keys, and a field added to `#payload` or `#capture` turns the suite
  # red instead of leaving the README describing a payload that no longer
  # exists.
  #
  # The hazard is measured rather than hypothetical: this payload has gained
  # fields in nearly every slice of the formatter's build-out — `ci_run_id` and
  # `shard_id` in one, `id` and `spec_file_path` in another.
  #
  # **If one of these just failed, you added or removed a transmitted field.**
  # That is allowed; shipping it undisclosed is not. Add the field to the right
  # table in the README section named above, then add it here. The section is
  # named rather than cited by line number on purpose — a line reference rots
  # the first time anything above it moves.
  describe "the disclosed key set" do
    let(:envelope_keys) { %w[branch ci_run_id commit_sha duration_seconds shard_id specs] }

    let(:spec_keys) do
      %w[duration file_path id intent line_number name outcome spec_file_path status]
    end

    # @intent: { entity: "RSpecFormatter payload", action: "disclose the key set", behavior: "the envelope transmits exactly the run fields the readme discloses", layer: "unit" }
    it "transmits exactly the run-envelope fields the README discloses" do
      formatter.stop(nil)

      expect(formatter.payload.keys.sort).to eq(envelope_keys)
    end

    # Both annotation outcomes, and `eq` over the whole mapped array rather than
    # `all(eq(...))`: an empty `specs` satisfies `all` vacuously, which would
    # make this pin report success having checked no example at all.
    # @intent: { entity: "RSpecFormatter payload", action: "disclose the key set", behavior: "each row transmits exactly the per-example fields the readme discloses", layer: "unit" }
    it "transmits exactly the per-example fields the README discloses" do
      allow(annotations).to receive(:intent_for).and_return(intent, nil)
      2.times { |i| finish(build_example(name: "example #{i}", line_number: i + 1)) }

      expect(formatter.payload["specs"].map { |spec| spec.keys.sort })
        .to eq([spec_keys, spec_keys])
    end
  end

  # The key-set pin above says *which* fields travel. This one says what two of
  # them can contain, because the README makes a claim about that too and the
  # claim is not the obvious one.
  #
  # README's "What SpecGuard collects" used to describe `spec_file_path` and
  # `file_path` as "relative to the project root", full stop. That is only true
  # of specs under the working directory. `#relative_path` delegates to
  # `::RSpec::Core::Metadata.relative_path`, which returns an **absolute** path
  # for a file outside it — so a spec vendored elsewhere, or handed to RSpec as
  # an absolute argument by a shard splitter or an IDE runner, sends its real
  # location off the machine in three fields at once. The section now says so,
  # and a reader deciding whether this may cross their perimeter is entitled to
  # have that be a maintained claim rather than a sentence someone once wrote.
  #
  # These examples call RSpec's own `relative_path` for real rather than
  # stubbing it — the behaviour under test belongs to rspec-core, so a double
  # here would only pin this file's belief about it. The absolute fixture is a
  # state the real producer genuinely reaches: it was reproduced end to end
  # before this was written, running a two-file suite with one spec inside a
  # project and one outside it, and the outside example transmitted
  # `/tmp/rp/outside/outside_spec.rb` in `id`, `spec_file_path` and `file_path`.
  #
  # **If one of these fails, the paths this gem transmits changed shape.** Fix
  # the two path rows and the machine-derived-paths paragraph in the README
  # section named above before touching the expectation.
  describe "the disclosed path values" do
    # @intent: { entity: "RSpecFormatter payload", action: "disclose path values", behavior: "a spec under the project root ships with the leading dot-slash stripped, as the readme table says", layer: "unit" }
    it "strips the leading ./ for a spec under the project root, as the table says" do
      finish(build_example(file_path: "./spec/orders_spec.rb"))

      spec = formatter.payload["specs"].first

      expect(spec.values_at("spec_file_path", "file_path"))
        .to eq(["spec/orders_spec.rb", "spec/orders_spec.rb"])
    end

    # The `id` row quotes `./spec/orders_spec.rb[1:2]` with the `./` intact,
    # unlike the two rows above it. That is not an inconsistency in the docs:
    # `#capture` writes `example.id` raw and never passes it through
    # `#relative_path`, so the prefix survives on the wire. Pinned because the
    # README quotes a literal value, and a quoted value that stops being true is
    # worse than no example at all.
    # @intent: { entity: "RSpecFormatter payload", action: "disclose path values", behavior: "the RSpec example id ships verbatim, dot-slash prefix and all", layer: "unit" }
    it "transmits RSpec's example id verbatim, ./ prefix and all" do
      finish(build_example(file_path: "./spec/orders_spec.rb", id: "./spec/orders_spec.rb[1:2]"))

      expect(formatter.payload["specs"].first["id"]).to eq("./spec/orders_spec.rb[1:2]")
    end

    # @intent: { entity: "RSpecFormatter payload", action: "disclose path values", behavior: "a spec outside the project root ships as an absolute path", layer: "unit" }
    it "transmits an absolute path for a spec outside the project root" do
      outside = "/tmp/vendored-suite/outside_spec.rb"

      finish(build_example(file_path: outside))

      spec = formatter.payload["specs"].first

      expect(spec.values_at("id", "spec_file_path", "file_path"))
        .to eq(["#{outside}[1:1]", outside, outside])
    end
  end

  describe "the JSONL sink" do
    # Criterion 2. Every example in this block runs with no API key, which is
    # the local-development default, and none of them may reach the network.
    # SPGD-810 criterion 1: a keyless run belongs to the *local* sink, and the
    # replay-queue file is neither created nor written.
    # @intent: { entity: "RSpecFormatter local sink", action: "stay offline without a key", behavior: "with no api key configured the formatter attempts no HTTP call at all", layer: "unit" }
    it "attempts no HTTP call at all when there is no API key" do
      allow(SpecGuard::RSpec::Transport).to receive(:new).and_call_original

      finish(build_example)
      formatter.close(nil)

      expect(SpecGuard::RSpec::Transport).not_to have_received(:new)
    end

    # @intent: { entity: "RSpecFormatter local sink", action: "append the run", behavior: "the run lands in the sink as a single JSON object on one line", layer: "unit" }
    it "appends the run as a single JSON object on one line" do
      finish(build_example)
      formatter.stop(nil)
      formatter.close(nil)

      expect(local_sink_lines.length).to eq(1)
      expect(JSON.parse(local_sink_lines.first)["specs"].length).to eq(1)
    end

    # @intent: { entity: "RSpecFormatter local sink", action: "append the run", behavior: "a missing output directory is created on first write", layer: "unit" }
    it "creates the output directory when it does not exist yet" do
      expect { formatter.close(nil) }.to change { File.directory?(File.dirname(local_sink)) }.to(true)
    end

    # JSONL, not JSON: a second run must not truncate the first.
    # @intent: { entity: "RSpecFormatter local sink", action: "append the run", behavior: "an existing sink file is appended to rather than replaced", layer: "unit" }
    it "appends to an existing file rather than replacing it" do
      2.times do
        described_class.new(output, error_stream: errors).tap do |run|
          run.stop(nil)
          run.close(nil)
        end
      end

      expect(local_sink_lines.length).to eq(2)
      expect(local_sink_lines).to all(satisfy { |line| JSON.parse(line).key?("specs") })
    end

    # @intent: { entity: "RSpecFormatter local sink", action: "append the run", behavior: "a run with no examples still writes a well-formed envelope", layer: "unit" }
    it "still writes a well-formed envelope for a run with no examples at all" do
      formatter.stop(nil)
      formatter.close(nil)

      expect(JSON.parse(local_sink_lines.first)).to include("specs" => [], "branch" => "main")
    end

    # `stop` is where the duration is sealed, but a run that never reaches it
    # must not write a null into a field the platform validates as numeric.
    # @intent: { entity: "RSpecFormatter local sink", action: "append the run", behavior: "a close without stop still reports a duration", layer: "unit" }
    it "still reports a duration when close is reached without stop" do
      formatter.close(nil)

      expect(JSON.parse(local_sink_lines.first)["duration_seconds"]).to be_a(Float).and be >= 0
    end

    # SPGD-810 criterion 1, both halves: written to the local sink, and the
    # replay queue is neither created nor written.
    # @intent: { entity: "RSpecFormatter local sink", action: "separate the two sinks", behavior: "a keyless run writes to the local sink, not the replay queue", layer: "unit" }
    it "writes a keyless run to the local sink, not the replay queue" do
      finish(build_example)
      formatter.close(nil)

      expect(local_sink_lines.length).to eq(1)
      expect(File.exist?(sink)).to be(false)
    end

    # SPGD-810 escape hatch: pointing both paths at one file reproduces the
    # pre-split single-file behaviour exactly.
    # @intent: { entity: "RSpecFormatter local sink", action: "separate the two sinks", behavior: "when both settings name the same file the run also reaches the replay queue", layer: "unit" }
    it "writes to the replay queue too when both paths name the same file" do
      SpecGuard::RSpec.configure { |config| config.local_output_path = config.output_path }

      finish(build_example)
      formatter.close(nil)

      expect(sink_lines.length).to eq(1)
    end
  end

  # Criterion 1, 3 and 4: which sink the run goes to, and what happens when the
  # chosen one does not accept it.
  #
  # The failure half is the reason this slice exists. `Net::HTTP` hands back
  # `Net::HTTPUnauthorized` as an ordinary return value, so a wrong API key
  # raises nothing — and the never-block-CI guard around every hook is a
  # `rescue`. A naive `deliver(payload)` inside it therefore produces no
  # exception, no warning, no log line and no file: the entire run's telemetry
  # gone, silently, which is what SPGD-12's "if the API key is wrong … it logs a
  # warning to stderr" forbids.
  describe "the HTTP sink" do
    def deliver_to(server, status: 202, **overrides)
      SpecGuard::RSpec.configure do |config|
        config.endpoint = server.endpoint
        config.api_key = "sgk_abc123"
        config.timeout = 5
        overrides.each { |key, value| config.public_send(:"#{key}=", value) }
      end

      finish(build_example)
      formatter.stop(nil)
      formatter.close(nil)
      server.requests.first
    end

    # @intent: { entity: "RSpecFormatter delivery", action: "POST the run", behavior: "with an api key configured the run is posted exactly once", layer: "unit" }
    it "POSTs the run once when an API key is configured" do
      StubIngestEndpoint.run do |server|
        deliver_to(server)

        expect(server.requests.length).to eq(1)
      end
    end

    # @intent: { entity: "RSpecFormatter delivery", action: "POST the run", behavior: "what goes on the wire is exactly what payload assembled, at the platform path", layer: "unit" }
    it "sends exactly what #payload assembled, to the platform's path" do
      StubIngestEndpoint.run do |server|
        request = deliver_to(server)

        expect(request.path).to eq("/api/v1/ingest")
        expect(request.headers["authorization"]).to eq("Bearer sgk_abc123")
        expect(request.json["specs"].length).to eq(1)
        expect(request.json).to include("commit_sha" => "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2",
                                        "branch" => "main",
                                        "ci_run_id" => "gha-1234567890",
                                        "shard_id" => "shard-2")
      end
    end

    # The point of POSTing at all: the local file is the *fallback*, not a
    # second copy. Writing both would double a shared CI sink's contents for
    # every successful run.
    # @intent: { entity: "RSpecFormatter delivery", action: "POST the run", behavior: "an accepted run writes no local file", layer: "unit" }
    it "writes no local file when the endpoint accepted the run" do
      StubIngestEndpoint.run do |server|
        deliver_to(server)

        expect(sink_lines).to be_empty
      end
    end

    # @intent: { entity: "RSpecFormatter delivery", action: "POST the run", behavior: "an accepted run says nothing on stderr", layer: "unit" }
    it "says nothing on stderr when the endpoint accepted the run" do
      StubIngestEndpoint.run do |server|
        deliver_to(server)

        expect(errors.string).to be_empty
      end
    end

    # @intent: { entity: "RSpecFormatter delivery", action: "POST the run", behavior: "delivery honours the configured timeout rather than the http library default", layer: "unit" }
    it "honours the configured timeout rather than Net::HTTP's 60 seconds" do
      allow(SpecGuard::RSpec::Transport).to receive(:new).and_call_original

      StubIngestEndpoint.run do |server|
        deliver_to(server, timeout: 3)

        expect(SpecGuard::RSpec::Transport)
          .to have_received(:new).with(hash_including(timeout: 3))
      end
    end

    # Criterion 3. Three statuses, because the *action* each implies is
    # different and a warning that only said "delivery failed" would leave the
    # reader unable to tell which of them they are looking at.
    [400, 401, 500].each do |status|
      context "when the endpoint answers #{status}" do
        # @intent: { entity: "RSpecFormatter delivery", action: "survive a refusal", behavior: "a refused status warns on stderr naming the status", layer: "unit" }
        it "warns on stderr, naming the status" do
          StubIngestEndpoint.run(status: status) do |server|
            deliver_to(server)

            expect(errors.string).to include(described_class::DELIVERY_WARNING_PREFIX)
            expect(errors.string).to include("HTTP #{status}")
          end
        end

        # The failure sink: silent loss becomes recoverable loss. The suite is
        # over by the time anyone reads the warning, so a run discarded here
        # cannot be re-produced — and `output_path` already exists to support
        # exactly this replay-from-file path.
        # @intent: { entity: "RSpecFormatter delivery", action: "survive a refusal", behavior: "the refused payload is written to the local fallback rather than dropped", layer: "unit" }
        it "writes the payload to the local fallback rather than dropping it" do
          StubIngestEndpoint.run(status: status) do |server|
            deliver_to(server)

            expect(sink_lines.length).to eq(1)
            expect(JSON.parse(sink_lines.first)["specs"].length).to eq(1)
          end
        end

        # @intent: { entity: "RSpecFormatter delivery", action: "survive a refusal", behavior: "a refusal never raises out of close", layer: "unit" }
        it "does not raise out of close" do
          StubIngestEndpoint.run(status: status) do |server|
            expect { deliver_to(server) }.not_to raise_error
          end
        end

        # @intent: { entity: "RSpecFormatter delivery", action: "survive a refusal", behavior: "the warning prints once, not once per problem in the run", layer: "unit" }
        it "warns once, not once per problem" do
          StubIngestEndpoint.run(status: status) do |server|
            deliver_to(server)

            expect(errors.string.lines.length).to eq(1)
          end
        end

        # @intent: { entity: "RSpecFormatter delivery", action: "survive a refusal", behavior: "the fallback file is named in the warning so the reader knows the run is recoverable", layer: "unit" }
        it "names the fallback file, so the reader knows the run is recoverable" do
          StubIngestEndpoint.run(status: status) do |server|
            deliver_to(server)

            expect(errors.string).to include(SpecGuard::RSpec.configuration.output_path)
          end
        end
      end
    end

    # The end-to-end of SPGD-584: the platform names the offending spec in the
    # refusal body, and that name has to survive all the way to the one line
    # the run is allowed — without costing the fallback write, and without
    # becoming two lines.
    describe "when the endpoint says why it refused" do
      let(:detail) do
        "spec 3 (spec/foo_spec.rb:9): line_number is required and must be a positive integer"
      end

      # @intent: { entity: "RSpecFormatter delivery", action: "report refusal reasons", behavior: "the platform reason for the refusal appears on the one warning line", layer: "unit" }
      it "puts the platform's reason on the one line it warns with" do
        StubIngestEndpoint.run(status: 400, body: JSON.generate("details" => [detail])) do |server|
          deliver_to(server)

          expect(errors.string).to include("HTTP 400", detail)
          expect(errors.string.lines.length).to eq(1)
        end
      end

      # Recoverable loss stays recoverable. Naming the cause is an addition to
      # the warning, not a substitute for keeping the run.
      # @intent: { entity: "RSpecFormatter delivery", action: "report refusal reasons", behavior: "a run the endpoint refused still lands in the fallback file", layer: "unit" }
      it "still writes the run to the fallback file" do
        StubIngestEndpoint.run(status: 400, body: JSON.generate("details" => [detail])) do |server|
          deliver_to(server)

          expect(sink_lines.length).to eq(1)
        end
      end

      # @intent: { entity: "RSpecFormatter delivery", action: "report refusal reasons", behavior: "a refusal of every spec in the run still comes out on one line", layer: "unit" }
      it "stays on one line when the endpoint refuses every spec in the run" do
        body = JSON.generate("details" => Array.new(500) { |i| "spec #{i}: name is required" })

        StubIngestEndpoint.run(status: 400, body: body) do |server|
          deliver_to(server)

          expect(errors.string.lines.length).to eq(1)
          expect(errors.string).to include("and 497 more")
        end
      end
    end

    # Criterion 4: a raised exception takes the same path as a refused
    # response. One outcome, one warning, one fallback write.
    describe "when the request cannot be made at all" do
      before do
        SpecGuard::RSpec.configure do |config|
          config.api_key = "sgk_abc123"
          config.endpoint = "http://127.0.0.1:1"
          config.timeout = 1
        end
      end

      # @intent: { entity: "RSpecFormatter delivery", action: "survive no endpoint", behavior: "a request that cannot be made at all warns and falls back rather than losing the run", layer: "unit" }
      it "warns and falls back rather than losing the run" do
        finish(build_example)
        formatter.close(nil)

        expect(errors.string).to include(described_class::DELIVERY_WARNING_PREFIX)
        expect(sink_lines.length).to eq(1)
      end

      # @intent: { entity: "RSpecFormatter delivery", action: "survive no endpoint", behavior: "an undeliverable request never raises out of close", layer: "unit" }
      it "does not raise out of close" do
        expect { formatter.close(nil) }.not_to raise_error
      end

      # @intent: { entity: "RSpecFormatter delivery", action: "survive no endpoint", behavior: "the underlying error is named so the cause is not a mystery", layer: "unit" }
      it "names the underlying error, so the cause is not a mystery" do
        formatter.close(nil)

        expect(errors.string).to match(/Errno::|SocketError/)
      end
    end

    # Criterion 5's second half, and the reason a pre-flight check is worth
    # having at all. `Ingest::Payload#validate_commit_sha` refuses a blank
    # commit and the controller renders 400, so the run would be discarded
    # whole — every example, not merely the empty field. Spending the run's
    # wall clock to be told that is pure loss.
    describe "when the commit could not be determined" do
      # @intent: { entity: "RSpecFormatter delivery", action: "gate on the commit", behavior: "a run whose commit could not be determined does not POST at all", layer: "unit" }
      it "does not POST at all" do
        StubIngestEndpoint.run do |server|
          deliver_to(server, commit_sha: nil)

          expect(server.requests).to be_empty
        end
      end

      # @intent: { entity: "RSpecFormatter delivery", action: "gate on the commit", behavior: "the unknown commit takes the fallback sink and the warning says why", layer: "unit" }
      it "takes the fallback sink and says why" do
        StubIngestEndpoint.run do |server|
          deliver_to(server, commit_sha: nil)

          expect(sink_lines.length).to eq(1)
          expect(errors.string).to include("the commit could not be determined")
        end
      end

      # @intent: { entity: "RSpecFormatter delivery", action: "gate on the commit", behavior: "a blank commit is treated the same as a missing one", layer: "unit" }
      it "treats a blank commit the same as a missing one" do
        StubIngestEndpoint.run do |server|
          deliver_to(server, commit_sha: "   ")

          expect(server.requests).to be_empty
        end
      end
    end

    # A key with nowhere to send it. Answered here rather than deep inside
    # `Net::HTTP`, because "no endpoint is configured" is a sentence somebody
    # can act on and `URI::InvalidURIError` is not.
    describe "when an API key is set but no endpoint is" do
      before { SpecGuard::RSpec.configure { |config| config.api_key = "sgk_abc123" } }

      # @intent: { entity: "RSpecFormatter delivery", action: "gate on the commit", behavior: "an api key with no endpoint falls back to the file and names the missing setting", layer: "unit" }
      it "falls back to the file and names the missing setting" do
        formatter.close(nil)

        expect(sink_lines.length).to eq(1)
        expect(errors.string).to include("SPECGUARD_ENDPOINT")
      end
    end

    # SPGD-810 criterion (c), pinned from both sides: a key with no endpoint,
    # and a blank commit, are *failed deliveries* — recoverable, and therefore
    # replay-queue material. Only the keyless branch moved to the local sink.
    describe "the replay queue's membership (SPGD-810)" do
      # @intent: { entity: "RSpecFormatter delivery", action: "route the replay queue", behavior: "a run blocked only by the missing keyless endpoint stays on the replay queue, off the local sink", layer: "unit" }
      it "keeps a keyless-endpoint run on the replay queue, off the local sink" do
        SpecGuard::RSpec.configure { |config| config.api_key = "sgk_abc123" }

        formatter.close(nil)

        expect(sink_lines.length).to eq(1)
        expect(File.exist?(local_sink)).to be(false)
      end

      # @intent: { entity: "RSpecFormatter delivery", action: "route the replay queue", behavior: "a blank-commit run also stays on the replay queue, off the local sink", layer: "unit" }
      it "keeps a blank-commit run on the replay queue, off the local sink" do
        StubIngestEndpoint.run do |server|
          deliver_to(server, commit_sha: nil)

          expect(sink_lines.length).to eq(1)
          expect(File.exist?(local_sink)).to be(false)
        end
      end
    end

    # The fallback's own failure mode. Both sinks are gone, the run really is
    # lost — but the process must still exit on the suite's own terms, and the
    # one warning the run is allowed must be the specific one.
    # @intent: { entity: "RSpecFormatter delivery", action: "survive double failure", behavior: "a fallback write that fails too is survived, with the warning still naming the HTTP status", layer: "unit" }
    it "survives a fallback write that fails too, still naming the HTTP status" do
      StubIngestEndpoint.run(status: 401) do |server|
        blocker = File.join(tmpdir, "blocker")
        File.write(blocker, "not a directory")

        expect { deliver_to(server, output_path: File.join(blocker, "results.jsonl")) }
          .not_to raise_error
        expect(errors.string).to include("HTTP 401")
      end
    end

    # SPGD-1413, and the other half of the example above: that one pins that the
    # run SURVIVES the double failure, this one pins what it SAYS about it.
    #
    # The discriminating assertion is the negative one. Every natural positive
    # clause here — the prefix, `HTTP 401`, the one-line count — passed
    # identically before this slice, because the old line carried all three;
    # what it also carried was `Falling back to <path>; the test run is
    # unaffected.` emitted *before* the write, and never corrected when that
    # write failed, because `emit_warning` returns on `@warned`. So the pin is
    # on the bytes that differ: the "unaffected" promise must be gone and the
    # queue that was never written must be named as lost. Reverting
    # `#sink_clause` to the old unconditional promise fails exactly this
    # example.
    #
    # The status is asserted alongside, because the reason the warn-before-write
    # ORDER was not reversed is that the status is the more actionable fact — a
    # slice that made the loss speak by dropping `HTTP 401` would have traded
    # one silence for another.
    # @intent: { entity: "RSpecFormatter delivery", action: "name a lost run", behavior: "a refused delivery whose replay queue cannot be written prints one line naming the status and the unwritten queue rather than claiming the test run is unaffected", layer: "unit" }
    it "names the loss instead of claiming the run was saved" do
      StubIngestEndpoint.run(status: 401) do |server|
        blocker = File.join(tmpdir, "blocker")
        File.write(blocker, "not a directory")
        queue = File.join(blocker, "results.jsonl")

        deliver_to(server, output_path: queue)

        # The load-bearing clause: nothing was saved, so the line must not say
        # the run is unaffected, and must name the queue it failed to write.
        expect(errors.string).not_to include("unaffected")
        expect(errors.string).to include("lost", queue)
        expect(File.exist?(queue)).to be(false)
        # The status survives, and so do the budget and the never-fail
        # contract: making the line true cost none of them.
        expect(errors.string).to include("HTTP 401")
        expect(errors.string.scan(/SpecGuard:/).length).to eq(1)
      end
    end
  end

  # The delivery decision that comes before every other one: was anything
  # actually measured?
  #
  # `rspec --dry-run` builds and reports every example without executing a
  # body, so `duration` becomes the cost of construction (~1e-5s) and `outcome`
  # becomes `passed` for code that never ran. Neither field carries a marker
  # saying so, `Ingest::Payload` validates neither, and
  # `Repository#latest_test_run` is last-writer-wins — so a lint job that
  # inherits an environment-level API key replaces the repository's headline
  # with all-green zeroes.
  #
  # Dry-run mode is a property of the process, so these examples stub the one
  # seam that reads it. The end-to-end proof — a real `rspec --dry-run` against
  # a real socket — is in formatter_run_spec.rb.
  describe "refusing to deliver a dry run" do
    def dry_run!(value = true)
      configuration = instance_double(RSpec::Core::Configuration, dry_run?: value)
      allow(formatter).to receive(:rspec_configuration).and_return(configuration)
    end

    # SPGD-154 criterion 5 ("the check is `::RSpec`-qualified and
    # `respond_to?`-guarded"), and the only example here that names the *cause*
    # rather than a downstream symptom.
    #
    # `SpecGuard::RSpec` is this gem's own namespace, so a bare
    # `RSpec.configuration` inside `module SpecGuard` reaches this gem's
    # Configuration — which has no `dry_run?`. Measured by mutating
    # `#rspec_configuration` and running this suite: with the formatter's
    # `respond_to?` guard in place that does not raise, it answers "not a dry
    # run" for every run and silently reinstates the defect the guard exists to
    # close. 23 examples fail suite-wide (`bundle exec rspec`, 601 examples);
    # this is the only one that says which line is wrong. Of the other 22, four
    # are process-level dry-run examples in formatter_run_spec.rb that can only
    # report the symptom, and 18 belong to the message relay, which reads the
    # same `#rspec_configuration` for `.formatters` — so most of that total is
    # collateral from a seam this ticket shares rather than owns.
    #
    # (Mutating both — bare `RSpec` *and* no `respond_to?` — is the state the
    # ticket warned about: a swallowed NoMethodError leaving a formatter that
    # delivers nothing at all. That one is not subtle; 110 fail suite-wide.)
    #
    # Both totals are whole-suite figures, so an edit anywhere in the tree can
    # move them without touching this file or the one it describes; the example
    # named above is the part of this claim that does not rot.
    # @intent: { entity: "RSpecFormatter dry-run guard", action: "read the real RSpec config", behavior: "the dry-run question is asked of the real RSpec configuration, not the gem same-named one", layer: "unit" }
    it "reads the real RSpec's configuration, not this gem's same-named one" do
      expect(formatter.send(:rspec_configuration)).to equal(::RSpec.configuration)
    end

    # @intent: { entity: "RSpecFormatter dry-run guard", action: "read the real RSpec config", behavior: "the question asked is one the gem own configuration cannot answer", layer: "unit" }
    it "is asking a question this gem's own configuration cannot answer" do
      expect(SpecGuard::RSpec.configuration).not_to respond_to(:dry_run?)
      expect(::RSpec.configuration).to respond_to(:dry_run?)
    end

    # The control for everything below: this suite is not itself a dry run, so
    # unstubbed the predicate must be false and delivery must be ordinary.
    # @intent: { entity: "RSpecFormatter dry-run guard", action: "deliver ordinary runs", behavior: "when RSpec is not in dry-run mode the run delivers normally", layer: "unit" }
    it "delivers normally when RSpec is not in dry-run mode" do
      expect(formatter.send(:dry_run?)).to be(false)

      finish(build_example)
      formatter.close(nil)

      expect(local_sink_lines.length).to eq(1)
    end

    context "when RSpec is in dry-run mode" do
      before { dry_run!(true) }

      # @intent: { entity: "RSpecFormatter dry-run guard", action: "refuse dry runs", behavior: "a dry run appends nothing to the local sink", layer: "unit" }
      it "appends nothing to the local sink" do
        finish(build_example)
        formatter.close(nil)

        expect(sink_lines).to be_empty
      end

      # @intent: { entity: "RSpecFormatter dry-run guard", action: "refuse dry runs", behavior: "a dry run issues no POST even with an api key and endpoint configured", layer: "unit" }
      it "issues no POST, even with an API key and an endpoint configured" do
        StubIngestEndpoint.run do |server|
          SpecGuard::RSpec.configure do |config|
            config.endpoint = server.endpoint
            config.api_key = "sgk_abc123"
            config.timeout = 5
          end

          finish(build_example)
          formatter.close(nil)

          expect(server.requests).to be_empty
        end
      end

      # SPGD-639 edited this example's *measurement*, not its claim, and this
      # is the note the ticket asked for rather than a quiet edit.
      #
      # The claim was always "one announcement per run, not one per example" —
      # which is why the body runs three examples through and why the title
      # says "exactly once". `lines.length == 1` was the mechanical form of
      # that claim back when the announcement was the only thing on stderr and
      # happened to be a single line. The dry-run report is deliberately
      # multi-line (one `SpecGuard:` header, then an unindented worklist), so
      # the old form now measures "the report is one line", which was never the
      # contract and is not a property anyone wants pinned.
      #
      # Restated as the number of `SpecGuard:`-prefixed lines, which is the same
      # contract `formatter_run_spec.rb` pins at the process level and the one
      # the budget-bypass in `#skip_dry_run` has to keep true. Note it is *not*
      # weakened to `>= 1`: three examples through a formatter that announced
      # per-example would read 3 here and still fail, so the regression the
      # original was built to catch is still caught.
      # @intent: { entity: "RSpecFormatter dry-run guard", action: "announce the refusal", behavior: "the dry-run refusal is said on stderr exactly once", layer: "unit" }
      it "says so on stderr, exactly once" do
        3.times { finish(build_example) }
        formatter.close(nil)

        expect(errors.string).to include(described_class::DRY_RUN_WARNING_PREFIX)
        expect(errors.string.scan(/SpecGuard:/).length).to eq(1)
      end

      # The other half of the line above, and the reason it can no longer be a
      # line count: the report enumerates *examples*, so three unannotated ones
      # get three worklist entries under the single header.
      # @intent: { entity: "RSpecFormatter dry-run guard", action: "announce the refusal", behavior: "every unannotated example is listed under the one refusal header", layer: "unit" }
      it "lists every unannotated example under that one header" do
        3.times { finish(build_example) }
        formatter.close(nil)

        worklist = errors.string.lines.grep(%r{spec/orders_spec\.rb:4})

        expect(worklist.length).to eq(3)
        expect(errors.string).to include("3 examples, 0 annotated, 3 unannotated (0% annotated)")
      end

      # Only the *delivery* decision changes. Capture is left exactly as it
      # was, so a caller — or a future replay path — can still inspect what the
      # run looked like without anything having been written anywhere.
      # @intent: { entity: "RSpecFormatter dry-run guard", action: "announce the refusal", behavior: "the refused run is still captured so the payload stays inspectable", layer: "unit" }
      it "still captures the run, so #payload remains inspectable" do
        finish(build_example)
        formatter.stop(nil)
        formatter.close(nil)

        expect(formatter.payload["specs"].length).to eq(1)
        expect(formatter.payload["duration_seconds"]).to be_a(Float)
      end

      # @intent: { entity: "RSpecFormatter dry-run guard", action: "announce the refusal", behavior: "the refusal never raises out of close", layer: "unit" }
      it "does not raise out of close" do
        expect { formatter.close(nil) }.not_to raise_error
      end

      # SPGD-639. SPGD-154's own scope said capture stays inspectable "so a
      # caller — or a future replay path — can still inspect what the run
      # looked like". This is the first thing built to inspect it, and these
      # examples pin the decisions the ticket asked to be made deliberately
      # rather than fallen into.
      describe "the local annotation-coverage report" do
        # Not a restatement of the two examples above. Those measure the
        # *shape* of the announcement; these measure the numbers in it against
        # a suite whose annotated/unannotated split is known and mixed, which
        # the shared `annotations` double (nil for everything) cannot produce.
        def mixed_suite!
          allow(annotations).to receive(:intent_for).and_return(intent, nil, intent, nil)
        end

        # @intent: { entity: "RSpecFormatter coverage report", action: "report the annotation split", behavior: "the local report names the annotated and unannotated split with each unannotated example at its site", layer: "unit" }
        it "reports the split, and names each unannotated example with its site" do
          mixed_suite!
          finish(build_example(name: "alpha", line_number: 1))
          finish(build_example(name: "beta", line_number: 2))
          finish(build_example(name: "gamma", line_number: 3))
          finish(build_example(name: "delta", line_number: 4))
          formatter.close(nil)

          expect(errors.string).to include("4 examples, 2 annotated, 2 unannotated (50% annotated)")
          # Site *and* name matched on one line, rather than as two `include`s
          # over the whole stream. Names were `"a"`/`"b"` and so on until the
          # SPGD-639 review pointed out that single characters are already
          # substrings of the boilerplate refusal ("bodies", "dry"), so the
          # name half of this example's claim could not fail — an
          # implementation that emitted sites and dropped names entirely passed
          # it. Distinctive names anchored to their own line make the assertion
          # mean what the title says.
          expect(errors.string).to match(%r{^\s+spec/orders_spec\.rb:2\s+beta$})
          expect(errors.string).to match(%r{^\s+spec/orders_spec\.rb:4\s+delta$})
          expect(errors.string).not_to include("spec/orders_spec.rb:1", "alpha")
          expect(errors.string).not_to include("spec/orders_spec.rb:3", "gamma")
        end

        # Criterion 5: the state the metric exists to reach is not an error,
        # and gets no worklist rather than an empty heading over nothing.
        # @intent: { entity: "RSpecFormatter coverage report", action: "report the annotation split", behavior: "a fully annotated suite is treated as the goal, not as a problem", layer: "unit" }
        it "treats a fully-annotated suite as the goal, not a problem" do
          allow(annotations).to receive(:intent_for).and_return(intent)
          2.times { finish(build_example) }
          formatter.close(nil)

          expect(errors.string).to include("2 examples, 2 annotated, 0 unannotated (100% annotated)")
          expect(errors.string).not_to include("by definition site")
          expect(errors.string.scan(/SpecGuard:/).length).to eq(1)
        end

        # The degenerate denominator. `close` runs even when nothing was
        # captured, so this path is reachable by anyone who dry-runs a filter
        # that matches nothing — and it must not divide by zero.
        # @intent: { entity: "RSpecFormatter coverage report", action: "report the annotation split", behavior: "a run with nothing to measure says so rather than dividing by zero", layer: "unit" }
        it "says there is nothing to measure rather than dividing by zero" do
          expect { formatter.close(nil) }.not_to raise_error

          expect(errors.string).to include("No examples were built")
          expect(errors.string).not_to include("%")
        end

        # The `@warned` decision, pinned in both directions.
        #
        # A spent budget must not swallow the report. This is the case where
        # the report matters *most*: the scanner failing classifies every
        # example `unannotated`, so a reader who saw only "0% annotated"
        # without the warning would blame their specs for SpecGuard's fault.
        # @intent: { entity: "RSpecFormatter coverage report", action: "share the warning budget", behavior: "the coverage report is not swallowed by a warning budget an earlier failure already spent", layer: "unit" }
        it "is not swallowed by a warning budget an earlier failure already spent" do
          allow(annotations).to receive(:intent_for).and_raise(IOError, "spec file vanished")
          finish(build_example)
          formatter.close(nil)

          expect(errors.string).to include(described_class::WARNING_PREFIX, "IOError")
          expect(errors.string).to include("1 example, 0 annotated, 1 unannotated")
        end

        # ...and the converse: nothing went wrong here, so the report must not
        # spend the budget a genuine later warning still needs.
        # @intent: { entity: "RSpecFormatter coverage report", action: "share the warning budget", behavior: "the coverage report leaves the warning budget unspent for a real warning that follows", layer: "unit" }
        it "leaves the warning budget unspent for a real warning that follows" do
          finish(build_example)
          formatter.close(nil)
          formatter.send(:warn_once, IOError.new("the sink went away"))

          expect(errors.string).to include("1 example, 0 annotated, 1 unannotated")
          expect(errors.string).to include(described_class::WARNING_PREFIX, "the sink went away")
        end

        # Rounding must not claim a boundary the suite has not reached. 199 of
        # 200 rounds to 100%, and a report that printed it would say a suite
        # with an unannotated spec in it was fully annotated — while its own
        # worklist, one line below, showed otherwise.
        # @intent: { entity: "RSpecFormatter coverage report", action: "round honestly", behavior: "the ratio never rounds up to full coverage while an example is still unannotated", layer: "unit" }
        it "never rounds up to 100% while an example is still unannotated" do
          expect(formatter.send(:annotated_percentage, 199, 200)).to eq(99)
          expect(formatter.send(:annotated_percentage, 200, 200)).to eq(100)
        end

        # @intent: { entity: "RSpecFormatter coverage report", action: "round honestly", behavior: "the ratio never rounds down to zero once an example is annotated", layer: "unit" }
        it "never rounds down to 0% once an example is annotated" do
          expect(formatter.send(:annotated_percentage, 1, 500)).to eq(1)
          expect(formatter.send(:annotated_percentage, 0, 500)).to eq(0)
        end

        # Criterion 4's second half, and the branch the SPGD-639 review
        # rejected the first attempt for leaving unfalsified.
        #
        # "A failure while building the report must not fail the run" has two
        # halves. The no-raise half was already covered by "does not raise out
        # of close". The *what-is-said-instead* half was not covered by
        # anything: mutating the fallback from `[DRY_RUN_REFUSAL]` to `[]` —
        # turning "degrade to the old behaviour" into precisely the silence the
        # branch exists to prevent — failed 0 of 1034 examples.
        #
        # `eq` rather than `include`, deliberately, and it is what makes this
        # example bite in both directions: an emptied fallback fails it (the
        # stream is bare), and so does one that emits the refusal *plus* a
        # half-built report, which would be worse than either — figures nobody
        # should trust, printed by the path that exists because they could not
        # be computed.
        # @intent: { entity: "RSpecFormatter coverage report", action: "survive report failure", behavior: "when the report cannot be built the refusal is reported and only the refusal", layer: "unit" }
        it "reports the refusal, and only the refusal, when the report cannot be built" do
          allow(formatter).to receive(:unannotated_worklist).and_raise(IOError, "scanner died mid-report")
          finish(build_example)
          formatter.close(nil)

          expect(errors.string.strip).to eq(described_class::DRY_RUN_REFUSAL)
          expect(errors.string).not_to include("Annotation coverage", "by definition site")
        end

        # The outer rescue's companion, which is a different claim from the one
        # above: not "what is said when the report cannot be built" but "what is
        # *kept* when it cannot be written".
        #
        # A dead stream here is unreportable by definition — there is nowhere to
        # say so. What must survive is the run's one warning, which a genuine
        # later failure still needs. Without the local rescue the exception
        # reaches `close`'s `never_fail_the_run`, which spends the budget on a
        # warning that goes to the same dead stream: a line nobody can read,
        # traded for one somebody needed.
        # @intent: { entity: "RSpecFormatter coverage report", action: "survive report failure", behavior: "a dead error stream means the warning budget is not spent", layer: "unit" }
        it "does not spend the run's one warning when the error stream is dead" do
          dead = instance_double(StringIO)
          allow(dead).to receive(:puts).and_raise(IOError, "stderr closed")
          formatter.instance_variable_set(:@error_stream, dead)
          finish(build_example)

          expect { formatter.close(nil) }.not_to raise_error

          formatter.instance_variable_set(:@error_stream, errors)
          formatter.send(:warn_once, IOError.new("the sink went away"))

          expect(errors.string).to include(described_class::WARNING_PREFIX, "the sink went away")
        end

        # The report is the *only* thing added. Both sinks stay refused.
        # @intent: { entity: "RSpecFormatter coverage report", action: "survive report failure", behavior: "a failed report publishes nothing to either sink", layer: "unit" }
        it "publishes nothing, to either sink" do
          StubIngestEndpoint.run do |server|
            SpecGuard::RSpec.configure do |config|
              config.endpoint = server.endpoint
              config.api_key = "sgk_abc123"
              config.timeout = 5
            end

            finish(build_example)
            formatter.close(nil)

            expect(server.requests).to be_empty
            expect(sink_lines).to be_empty
            expect(errors.string).to include("1 unannotated")
          end
        end
      end
    end

    # SPGD-154 criterion 5, second half ("a stubbed configuration without
    # `dry_run?` still delivers normally"). An RSpec build lacking the
    # predicate must fall through to *normal delivery* — the pre-existing
    # behaviour — rather than to a NoMethodError that never_fail_the_run would
    # swallow into silence.
    context "when the RSpec configuration has no #dry_run? at all" do
      before { allow(formatter).to receive(:rspec_configuration).and_return(Object.new) }

      # @intent: { entity: "RSpecFormatter dry-run guard", action: "tolerate old RSpec", behavior: "a configuration with no dry-run predicate is treated as an ordinary run", layer: "unit" }
      it "treats the run as an ordinary one" do
        expect(formatter.send(:dry_run?)).to be(false)
      end

      # @intent: { entity: "RSpecFormatter dry-run guard", action: "tolerate old RSpec", behavior: "such a run is delivered rather than swallowed into silence", layer: "unit" }
      it "delivers it, rather than swallowing a NoMethodError into silence" do
        finish(build_example)
        formatter.close(nil)

        expect(local_sink_lines.length).to eq(1)
        expect(errors.string).to be_empty
      end
    end
  end

  # SPGD-121 criterion 5: "a spec that fails if the rescue is removed".
  #
  # Deleting the `rescue` in `never_fail_the_run` fails 17 of this block's 19
  # examples. The count is BLOCK-scoped and says nothing about the rest: the
  # same mutation fails 18 in this file and 23 suite-wide (the other 5 are
  # process-level, in formatter_run_spec.rb's "when the sink cannot be written"
  # and "when the annotation scanner blows up"). All four figures come from one
  # `bundle exec rspec` of 1205 examples, sliced by scope — not from four
  # separate runs, and re-measured at that size by SPGD-1413.
  #
  # The 18th, outside this block, is "is not swallowed by a warning budget an
  # earlier failure already spent". SPGD-1413 removed a 19th: "survives a
  # fallback write that fails too" used to reach this rescue, because `#append`
  # let the queue's write raise. It now catches that failure itself and reports
  # it in the fall-back's own line, so the example no longer depends on this
  # guard — the run is still never failed by it, by a nearer rescue.
  #
  # The two examples that do NOT fail on deletion are "does NOT swallow an
  # interrupt" and "does NOT swallow an interrupt raised from the lookup", and
  # they are not slack in the guard — they pin the OPPOSITE mutation. Each fails
  # if the rescue is BROADENED, measured both ways: `rescue Exception`, and
  # adding `Interrupt` to the existing clause. Either one fails exactly those
  # two examples suite-wide and nothing else, so they are the only thing
  # standing between this rescue and the swallowed Ctrl-C that the formatter's
  # "Ctrl-C must stay Ctrl-C" note calls out as deliberate.
  describe "never failing the run" do
    def unwritable_sink!
      blocker = File.join(tmpdir, "blocker")
      File.write(blocker, "not a directory")
      SpecGuard::RSpec.configure { |config| config.local_output_path = File.join(blocker, "results.jsonl") }
    end

    # @intent: { entity: "RSpecFormatter", action: "never fail the run", behavior: "an unwritable output path is swallowed instead of raising out of close", layer: "unit" }
    it "swallows an unwritable output path instead of raising out of close" do
      unwritable_sink!

      expect { formatter.close(nil) }.not_to raise_error
    end

    # @intent: { entity: "RSpecFormatter", action: "never fail the run", behavior: "the unwritable path is named on stderr once with its underlying error", layer: "unit" }
    it "names the configured sink path on stderr, with the underlying error" do
      unwritable_sink!
      formatter.close(nil)

      expect(errors.string).to include(SpecGuard::RSpec.configuration.local_output_path)
      expect(errors.string).to match(/Errno::/)
    end

    # @intent: { entity: "RSpecFormatter", action: "never fail the run", behavior: "a sink raising an IO error mid-write is swallowed", layer: "unit" }
    it "swallows a sink that raises IOError" do
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(local_sink, "a").and_raise(IOError, "closed stream")

      expect { formatter.close(nil) }.not_to raise_error
      expect(errors.string).to include("IOError")
    end

    # The IOError arm is the one failure mode whose exception carries no path
    # at all — "closed stream" names no file — so the configured sink path in
    # the warning is the only thing that can tell the operator where to look.
    # @intent: { entity: "RSpecFormatter", action: "never fail the run", behavior: "a sink raising IOError still names the configured sink path on stderr", layer: "unit" }
    it "names the configured sink path when the write raises IOError" do
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(local_sink, "a").and_raise(IOError, "closed stream")

      formatter.close(nil)

      expect(errors.string).to include(SpecGuard::RSpec.configuration.local_output_path)
      expect(errors.string).to include("IOError")
    end

    # A bare `rescue` catches StandardError only. An autoload or a mixin
    # blowing up raises ScriptError, and would sail straight past it.
    # @intent: { entity: "RSpecFormatter", action: "never fail the run", behavior: "a ScriptError, which a bare rescue misses, is swallowed too", layer: "unit" }
    it "swallows a ScriptError, which a bare rescue would miss" do
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(local_sink, "a").and_raise(NotImplementedError, "nope")

      expect { formatter.close(nil) }.not_to raise_error
      expect(errors.string).to include("NotImplementedError")
    end

    # @intent: { entity: "RSpecFormatter", action: "never fail the run", behavior: "an example whose metadata cannot be read is swallowed", layer: "unit" }
    it "swallows an example whose metadata cannot be read" do
      broken = build_example
      allow(broken).to receive(:full_description).and_raise("boom")

      expect { finish(broken) }.not_to raise_error
    end

    # One bad example must not cost the run the other nineteen thousand.
    # @intent: { entity: "RSpecFormatter", action: "never fail the run", behavior: "the examples following a broken one keep being captured", layer: "unit" }
    it "keeps capturing the examples that follow a broken one" do
      broken = build_example
      allow(broken).to receive(:full_description).and_raise("boom")

      finish(broken)
      finish(build_example(name: "the one after"))

      expect(formatter.payload["specs"].map { |spec| spec["name"] }).to eq(["the one after"])
    end

    # @intent: { entity: "RSpecFormatter", action: "never fail the run", behavior: "a clock failure in stop is swallowed", layer: "unit" }
    it "swallows a clock failure in stop" do
      allow(formatter).to receive(:monotonic_now).and_raise("no clock")

      expect { formatter.stop(nil) }.not_to raise_error
    end

    # `seed` is the newest hook and the only one that reaches into
    # `RSpec.configuration` mid-run, so it has a failure mode the others do not:
    # `add_formatter` raises for a formatter name RSpec cannot resolve, which a
    # user with `config.default_formatter = "typo"` supplies. RSpec itself never
    # hits that line — it only adds the default when no formatter was registered
    # at all — so this repair is where such a typo first becomes an exception,
    # and `:seed` is dispatched from `Reporter#start`, before a single example
    # has run. Unguarded, a one-word config typo would abort the whole suite.
    # @intent: { entity: "RSpecFormatter", action: "never fail the run", behavior: "a failure while restoring the default formatter is swallowed", layer: "unit" }
    it "swallows a failure while restoring the default formatter" do
      allow(formatter).to receive(:restore_suppressed_default_formatter).and_raise("no such formatter")

      expect { formatter.seed(nil) }.not_to raise_error
      expect(errors.string).to include(described_class::WARNING_PREFIX)
    end

    # `message` reaches into `RSpec.configuration` for the same reason `seed`
    # does, and it is dispatched from a worse place: `reporter.message` carries
    # non-example exceptions and "No examples found.", and the first of those can
    # arrive before `Reporter#report` is even entered. A raise here would replace
    # the error the developer was being told about with one from the telemetry
    # gem.
    # @intent: { entity: "RSpecFormatter", action: "never fail the run", behavior: "a failure while relaying a message is swallowed", layer: "unit" }
    it "swallows a failure while relaying a message" do
      allow(formatter).to receive(:relay_message).and_raise("no configuration")

      expect { formatter.message(nil) }.not_to raise_error
      expect(errors.string).to include(described_class::WARNING_PREFIX)
    end

    # Criterion 6, extended to slice 2's code path. The annotation lookup reads
    # files off disk and compiles a JSON Schema, so it has failure modes the
    # rest of the capture layer does not — an unreadable spec file, a spec file
    # that is not valid UTF-8, a vendored schema that will not load.
    #
    # These are guarded *inside* `capture` rather than only by the envelope
    # around `example_finished`, and the difference is the whole point: the
    # outer envelope would drop the example entirely, so a project whose schema
    # failed to load would report a suite with no tests in it. Here it reports
    # a suite with no annotations in it, which is both true and recoverable.
    describe "when the annotation lookup itself fails" do
      before { allow(annotations).to receive(:intent_for).and_raise(broken_lookup) }

      let(:broken_lookup) { SpecGuard::RSpec::ValidatorError.new("could not resolve the validator") }

      # @intent: { entity: "RSpecFormatter", action: "survive lookup failure", behavior: "a failing annotation lookup never raises out of example finished", layer: "unit" }
      it "does not raise out of example_finished" do
        expect { finish(build_example) }.not_to raise_error
      end

      # @intent: { entity: "RSpecFormatter", action: "survive lookup failure", behavior: "the affected example is still recorded, as unannotated", layer: "unit" }
      it "still records the example, as unannotated" do
        finish(build_example(name: "can order an item"))

        expect(formatter.payload["specs"].first).to include(
          "name" => "can order an item", "status" => "unannotated", "intent" => nil
        )
      end

      # The fields the platform actually stores a run on. Losing an annotation
      # is a gap in one row; losing these is losing the example.
      # @intent: { entity: "RSpecFormatter", action: "survive lookup failure", behavior: "the affected example outcome and duration are still recorded", layer: "unit" }
      it "still records the example's outcome and duration" do
        finish(build_example(run_time: 0.0109, status: :failed))

        expect(formatter.payload["specs"].first).to include("duration" => 0.0109, "outcome" => "failed")
      end

      # @intent: { entity: "RSpecFormatter", action: "survive lookup failure", behavior: "the lookup failure is said on stderr once however many examples are affected", layer: "unit" }
      it "says so on stderr exactly once, however many examples are affected" do
        50.times { finish(build_example) }

        expect(errors.string.scan(described_class::WARNING_PREFIX).length).to eq(1)
        expect(errors.string).to include("ValidatorError")
      end

      # @intent: { entity: "RSpecFormatter", action: "survive lookup failure", behavior: "all fifty affected examples are still recorded", layer: "unit" }
      it "records all 50 of them anyway" do
        50.times { finish(build_example) }

        expect(formatter.payload["specs"].length).to eq(50)
      end

      # A ScriptError from the lookup would sail past a bare `rescue`.
      # @intent: { entity: "RSpecFormatter", action: "survive lookup failure", behavior: "a ScriptError from the lookup is swallowed too", layer: "unit" }
      it "swallows a ScriptError from the lookup too" do
        allow(annotations).to receive(:intent_for).and_raise(NotImplementedError, "nope")

        expect { finish(build_example) }.not_to raise_error
        expect(formatter.payload["specs"].first["status"]).to eq("unannotated")
      end

      # @intent: { entity: "RSpecFormatter", action: "survive lookup failure", behavior: "an interrupt raised from the lookup is not swallowed", layer: "unit" }
      it "does NOT swallow an interrupt raised from the lookup" do
        allow(annotations).to receive(:intent_for).and_raise(Interrupt)

        expect { finish(build_example) }.to raise_error(Interrupt)
      end
    end

    # A warning per example would bury the failure output of the suite it is
    # supposed to be reporting on.
    # @intent: { entity: "RSpecFormatter", action: "never fail the run", behavior: "exactly one warning prints however many things went wrong in one run", layer: "unit" }
    it "warns exactly once however many things go wrong" do
      broken = build_example
      allow(broken).to receive(:full_description).and_raise("boom")
      3.times { finish(broken) }
      unwritable_sink!
      formatter.close(nil)

      # One LINE, not one occurrence of the generic prefix: the broken example
      # spends the budget on the generic warning and the unwritable sink would
      # print its own locally-worded line, so a scan of WARNING_PREFIX alone
      # would stay at 1 even if the budget stopped covering the sink line.
      expect(errors.string.lines.length).to eq(1)
    end

    # @intent: { entity: "RSpecFormatter", action: "never fail the run", behavior: "nothing is ever written to the shared output stream, whatever happens", layer: "unit" }
    it "writes nothing to the shared output stream, whatever happens" do
      unwritable_sink!
      finish(build_example)
      formatter.close(nil)

      expect(output.string).to be_empty
    end

    # Ctrl-C must stay Ctrl-C. Reporting an interrupt as "telemetry failed" is
    # its own small lie, and would make a long suite harder to stop.
    # @intent: { entity: "RSpecFormatter", action: "never fail the run", behavior: "an interrupt is not swallowed, keeping ctrl-c working through the formatter", layer: "unit" }
    it "does NOT swallow an interrupt" do
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(local_sink, "a").and_raise(Interrupt)

      expect { formatter.close(nil) }.to raise_error(Interrupt)
    end
  end
end
