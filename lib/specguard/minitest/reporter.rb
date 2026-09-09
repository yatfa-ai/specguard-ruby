# frozen_string_literal: true

require "json"
require "fileutils"

# Configuration and Transport are the framework-free halves of the client
# (env resolution, wire delivery, the never-raise contract); both live under
# the rspec namespace because rspec shipped first, neither contains any RSpec.
# Required here rather than assumed because nothing else loads them on a
# minitest-only consumer's machine.
require_relative "../rspec/configuration"

# The annotation lookup is the third framework-free half: what counts as a
# test's annotation is a property of the source line, not of the framework
# that ran it, so the Minitest reporter asks the same {AnnotationLookup} the
# RSpec formatter does rather than carrying a second extractor (whose header
# already warns that a second extractor guarantees scanner and reporter
# eventually disagree about what an annotation is). Requiring it pulls the
# linter's chain — the same direction-safe require the formatter itself makes;
# `specguard/rspec` does not require `rspec/core`, so a minitest-only machine
# stays loadable.
require_relative "../rspec/annotation_lookup"

# The Minitest half of `specguard-ruby`. Everything the RSpec formatter knows
# about the platform — the envelope's field names, the transport's
# never-raise contract, the switch that a missing key is — is framework-free
# knowledge that already lives in `SpecGuard::RSpec::Configuration` and
# `SpecGuard::RSpec::Transport` (both named for the framework that happened to
# ship first, neither containing any RSpec). This adapter contributes only the
# part that is genuinely Minitest's: turning `Minitest::Result` objects into
# the same row shape the RSpec formatter emits, at the moment Minitest hands
# them to a reporter — and attaching each test's annotation the same way the
# formatter does, through the shared {SpecGuard::RSpec::AnnotationLookup} and
# its one-line lookback (SPGD-12 §2), so a Minitest row carries the same
# `status` / `intent` pair a RSpec row does.
#
# It is a duck-typed Minitest reporter (`start` / `record` / `report` /
# `passed?`) rather than a subclass of `Minitest::AbstractReporter`, because
# the composite only ever calls those four and a superclass would add
# assertions about documentation we do not need.
#
# ## Telemetry never fails the suite
#
# The same guarantee the RSpec formatter gives, arrived at the same way: every
# step is wrapped, a failed delivery costs one line on stderr and a line in the
# local sink, and `#passed?` is a constant `true` because Minitest folds it
# into the run's own verdict via `CompositeReporter#passed?` — `all?` over its
# reporters — and a telemetry reporter that could redden a suite would be a
# telemetry reporter somebody deletes.
module SpecGuard
  module Minitest
    class Reporter
      # `Ingest::Payload::STATUSES`, restated — the same call the RSpec
      # formatter makes. The platform validates every row against this pair,
      # so they are the contract and not a local naming choice.
      STATUS_ANNOTATED = "annotated"
      STATUS_UNANNOTATED = "unannotated"

      # Rows with no usable location are dropped rather than mangled: a row
      # whose file cannot be named fits no by-file aggregate on the platform
      # and would surface as noise. The RSpec formatter's `capture` makes the
      # equivalent call about a metadata-less example.
      class << self
        # `Dir.pwd` at load time, not per row: a reporter constructed inside a
        # test that changes the working directory would otherwise relativize
        # one suite's rows against two different roots.
        def repo_root
          Dir.pwd
        end
      end

      def initialize(configuration: SpecGuard::RSpec.configuration,
                     transport: nil, output: $stderr,
                     annotations: SpecGuard::RSpec::AnnotationLookup.new,
                     clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @configuration = configuration
        # Injected for the specs; the real thing is built the same way the
        # RSpec formatter builds it, from the same configuration object.
        @transport = transport
        @output = output
        @annotations = annotations
        @clock = clock
        @rows = []
        @started_at = nil
        @warned = false
      end

      def start
        @started_at = @clock.call
      end

      # Minitest's `CompositeReporter` calls this before every runnable, and
      # minitest 6 requires it on every reporter in the composite — a duck
      # type without it is not "a reporter that ignores prerecords", it is a
      # crash inside `Runnable#run` that takes the suite's exit code with it,
      # which is the one thing this class may never do. A no-op records
      # nothing: the row this adapter wants is the finished `Result`, not the
      # promise of one.
      def prerecord(_klass, _name); end

      # One `Minitest::Result` in, one wire row out. Guarded rather than
      # trusted for the same reason the RSpec formatter guards `capture`:
      # nothing a result object does while being read may cost the suite its
      # exit code.
      def record(result)
        row = row_for(result)
        return unless row

        @rows << row
      rescue ScriptError, StandardError
        nil
      end

      # Minitest calls this after every runnable has reported, on the same
      # reporter — the delivery point. A run that recorded nothing ships
      # nothing, mirroring the RSpec formatter's stance on an empty suite.
      def report
        return if @rows.empty?

        uniquify_ids!
        deliver(payload)
      rescue ScriptError, StandardError => e
        warn_once("could not ship test telemetry (#{e.class}: #{e.message}). The test run is unaffected.")
      end

      # Constant by contract — see the class comment. Public because
      # `CompositeReporter#passed?` is `all?` over its reporters and this one
      # must never be the reporter that flips a green suite red.
      def passed?
        true
      end

      private

      # The definition site is NOT unique per result for a generated test:
      # `define_method("test_x_#{param}")` in a loop (or any
      # generate_tests-style helper) stamps every instance with the SAME
      # `source_location` — the define_method call site — so N results share
      # one id, and the platform's ingest upserts
      # `unique_by %i[test_run_id example_id]` silently drops every repeat
      # but the first, taking each dropped row's outcome and duration with
      # it. `@rows` is complete here — every `record` has returned, and
      # parallel mode records from its worker threads through this one shared
      # reporter — so the collision is detectable exactly once, at delivery.
      # Every member of a colliding group is re-identified as
      # `"#{file}:#{line}##{Klass#method_name}"`, suffixed with the row's own
      # class-qualified wire `name` — not the bare method name, which stops
      # distinguishing results the moment TWO classes share one `define_method`
      # call site (Rails' declarative `test "desc"` helper is exactly that
      # shape: one `define_method` inside activesupport, shared by every test
      # class in the suite) and generate identically-named methods. The
      # class-qualified name is unique per result and deterministic, so the
      # suffixed ids are stable across runs. The token is read straight off
      # the row rather than stashed at `record` time: `row["name"]` already IS
      # `"#{result.klass}##{result.name}"`, so a sidecar would be a
      # byte-identical copy of a value already on the wire — redundant state
      # and one more thing that could leak. ALL members take the suffix,
      # never just later arrivals — parallel
      # mode's arrival order is fork scheduling, so "the first row keeps the
      # bare id" would make identity depend on it. Rows whose id no other
      # row claims — every plain `def test_` suite among them — keep the id
      # they always had, byte for byte. The id remains the run-local primary
      # key for one delivered payload and never a cross-run stable identity:
      # cross-run matching remains name + file, the platform's own rule.
      def uniquify_ids!
        counts = Hash.new(0)
        @rows.each { |row| counts[row["id"]] += 1 }
        @rows.each do |row|
          next unless counts[row["id"]] > 1

          row["id"] = "#{row["id"]}##{row["name"]}"
        end
      end

      # The envelope, in the platform's own field names (`Ingest::Payload`:
      # commit_sha / branch / ci_run_id / duration_seconds / specs) — the same
      # rule the RSpec formatter states at its `#payload`: this gem's settings
      # are named its way, every key in this Hash is named the platform's way,
      # and nothing translates between them.
      def payload
        {
          "commit_sha" => @configuration.commit_sha,
          "branch" => @configuration.branch,
          "ci_run_id" => @configuration.run_id,
          "shard_id" => @configuration.shard_id,
          "duration_seconds" => duration_seconds,
          "specs" => @rows
        }
      end

      # The delivery ladder, in the RSpec formatter's order, with the same two
      # sinks for the same two reasons: no key means the local development
      # record (`local_output_path` — a note that a run happened, not a queue);
      # a refused or failed delivery means the replay queue (`output_path` —
      # the file `specguard-ingest` re-delivers). A blank commit_sha means the
      # platform would refuse the whole run, so it is caught before the wall
      # clock is spent and the run goes to the replay queue. Anything else goes
      # to the transport, whose own contract is that nothing escapes it — a
      # non-success `Result` costs one stderr line and a queued run.
      def deliver(data)
        return append(data, @configuration.local_output_path) if @configuration.api_key.to_s.strip.empty?

        if @configuration.commit_sha.to_s.strip.empty?
          return fall_back(data, "no commit sha could be resolved (set SPECGUARD_COMMIT_SHA)")
        end

        result = (@transport || transport_for).deliver(data)
        return if result.success?

        # The transport's `reason` is already the operator-facing sentence for
        # both a refusal (status, what to do about it, the platform's own
        # words) and a failure (exception class and message) — nothing to add.
        fall_back(data, result.reason)
      end

      def transport_for
        require_relative "../rspec/transport"
        SpecGuard::RSpec::Transport.new(
          endpoint: @configuration.endpoint,
          api_key: @configuration.api_key,
          timeout: @configuration.timeout
        )
      end

      def row_for(result)
        # `source_location` is an Array `["path", line]` on minitest 6 and a
        # "path:line" String on minitest 5 — both are read, because which one
        # a consumer runs is not this gem's to choose.
        location = result.source_location
        file, line =
          if location.is_a?(Array)
            location
          else
            location.to_s.split(":", 2)
          end
        # A row without both halves of a location fits no by-file aggregate
        # and no stable identity; dropped rather than mangled, the same call
        # the RSpec formatter makes about a metadata-less example.
        return nil if file.to_s.strip.empty? || line.to_i.zero?

        file = relative_path(file)
        name = "#{result.klass}##{result.name}"
        line_number = line&.to_i
        intent = annotation_for(file, line_number)
        {
          # Minitest has no RSpec-style rerun path or nested ids, so the
          # definition site is the row's id — the run-local primary key for
          # this one delivered payload, never a cross-run stable identity
          # (cross-run matching remains name + file, the platform's own
          # rule). A definition site is NOT unique per result:
          # `define_method`-generated tests stamp every instance with the
          # same location, so rows can collide on this id within a run, and
          # `uniquify_ids!` is what re-identifies those rows at delivery
          # time. Nothing here promises uniqueness it does not have.
          "id" => "#{file}:#{line}",
          "spec_file_path" => file,
          "file_path" => file,
          "line_number" => line_number,
          "name" => name,
          "duration" => result.time,
          # The platform's three outcomes, mapped from Minitest's questions:
          # a skip is a pending (the suite's own vocabulary for "deliberately
          # not answered"), and a failure and an error are both "failed" —
          # Minitest distinguishes assertion failures from exceptions, the
          # wire contract does not, and inventing a fourth outcome here would
          # be a lie the schema refuses.
          "outcome" => outcome_for(result),
          # The RSpec formatter's rationale, restated: the key is written
          # explicitly because a present key says "we looked", where an absent
          # key is indistinguishable from "this producer does not report
          # annotations" — and without it the platform refuses the whole run
          # (`Ingest::Payload` requires `status` on EVERY row). `intent` is
          # likewise explicit: null when unannotated, which is exactly what
          # the platform demands of an unannotated row.
          "status" => intent.nil? ? STATUS_UNANNOTATED : STATUS_ANNOTATED,
          "intent" => intent
        }
      end

      # The lookup, inside its own envelope. `record`'s rescue would drop the
      # whole row — example, duration, outcome and all — to learn one row's
      # annotation, which is the trade the RSpec formatter already refused:
      # its annotation lookup runs inside a nested guard so a blow-up costs
      # the row only its annotation. The lookup degrades verdicts it could
      # not reach to nil itself (an unusable validator ships unannotated by
      # design); this envelope is for what escapes it anyway — file reads the
      # lookup does not expect, encoding faults, anything else — and it
      # routes through {#warn_once}, so the operator hears about it exactly
      # once however many rows are affected.
      def annotation_for(file, line)
        @annotations.intent_for(file: file, line: line)
      rescue ScriptError, StandardError => e
        warn_once("could not resolve annotations (#{e.class}: #{e.message}). " \
                  "Rows continue unannotated. The test run is unaffected.")
        nil
      end

      def outcome_for(result)
        return "pending" if result.skipped?
        return "failed" unless result.passed?

        "passed"
      end

      def relative_path(path)
        root = self.class.repo_root
        return path unless path.start_with?("#{root}/")

        path.delete_prefix("#{root}/")
      end

      def duration_seconds
        return 0.0 if @started_at.nil?

        (@clock.call - @started_at).round(3)
      end

      # One JSON run per line, to whichever file this delivery's outcome
      # warrants (see `#deliver` for which and why).
      def append(data, path)
        FileUtils.mkdir_p(File.dirname(path))
        File.open(path, "a") { |f| f.puts(JSON.generate(data)) }
      rescue ScriptError, StandardError => e
        warn_once("could not write telemetry to #{path} (#{e.class}: #{e.message}). The test run is unaffected.")
      end

      def fall_back(data, reason)
        warn_once("could not deliver test telemetry (#{reason}). Falling back to the replay queue. " \
                  "The test run is unaffected.")
        append(data, @configuration.output_path)
      end

      # Once per process, like the formatter's `warn_once`: fifty failing
      # deliveries is one problem, not fifty lines of it.
      def warn_once(message)
        return if @warned

        @warned = true
        @output.puts("SpecGuard: #{message}")
      end
    end
  end
end
