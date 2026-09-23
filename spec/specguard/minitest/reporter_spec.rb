# frozen_string_literal: true

require "stringio"
require "tmpdir"
require "minitest"

require "specguard/rspec/transport"
require "specguard/minitest/reporter"
require_relative "../../support/validator_stub"

# The Minitest adapter's unit contract: what a `::Minitest::Result` becomes on
# the wire, and what never happens (a raise, a red suite, a second warning).
# The end-to-end chain — plugin discovery, a real child run, a real POST — is
# plugin_spec.rb's business; nothing here starts a process or a server.
module SpecGuard
  module Minitest
    ::RSpec.describe Reporter do
      let(:base_env) do
        {
          "SPECGUARD_ENDPOINT" => "https://specguard.example.test",
          "SPECGUARD_API_KEY" => "sgk_unit",
          "SPECGUARD_COMMIT_SHA" => "1" * 40,
          "SPECGUARD_BRANCH" => "main",
          "SPECGUARD_RUN_ID" => "42"
        }.freeze
      end

      def configuration(env)
        SpecGuard::RSpec::Configuration.new(env: env)
      end

      # A real `::Minitest::Result`, built the way Minitest builds them — through
      # the same failure objects its own reporters see, so the outcome mapping
      # is exercised against `Result#passed?`/`#skipped?` rather than a stand-in
      # that agrees with the adapter by construction.
      # `location` takes either shape `Result#source_location` has across
      # minitest versions: the Array minitest 6 reports (the default here,
      # because that is what a consumer's modern suite sends) or the
      # "path:line" String minitest 5 reports.
      def result(outcome, klass: "FooTest", name: "test_bar", location: nil, time: 0.25)
        location ||= ["#{Reporter.repo_root}/spec/foo_test.rb", 12]
        result = ::Minitest::Result.new(name)
        result.klass = klass
        result.source_location = location
        result.time = time
        result.failures =
          case outcome
          when :passed then []
          when :skipped then [::Minitest::Skip.new("deliberately not answered")]
          when :assertion_failed then [::Minitest::Assertion.new("expected 1, got 2")]
          when :raised then [::Minitest::UnexpectedError.new(StandardError.new("boom"))]
          else raise outcome.to_s
          end
        result
      end

      # The third element is the *reachability* probe, and it answers a question
      # the captured payload cannot: `captured` is `nil` both when `deliver` was
      # never called and when it was called with nothing, so a pre-flight guard
      # asserted on `captured` alone would also pass for a guard that fired
      # after the request. `calls` counts invocations, so "never reached the
      # transport" is measured rather than inferred. Appended, not substituted:
      # every existing `recording_transport.first` and two-value destructure
      # reads exactly what it read before.
      def recording_transport(outcome: :success)
        captured = nil
        calls = 0
        transport = Object.new
        transport.define_singleton_method(:deliver) do |data|
          calls += 1
          captured = data
          SpecGuard::RSpec::Transport::Result.new(outcome: outcome,
            code: outcome == :success ? 202 : 400)
        end
        [transport, -> { captured }, -> { calls }]
      end

      describe "row mapping" do
        # @intent: { entity: "Minitest Reporter", action: "map a passed result", behavior: "a passing minitest result becomes a row with the platform field names, file and line split from the source location, and the recorded duration", layer: "unit" }
        it "maps a passed result to a passed row in the platform's field names" do
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new)
          reporter.record(result(:passed, time: 1.5))
          reporter.report

          row = reporter.instance_variable_get(:@rows).first
          expect(row).to match(
            "id" => "spec/foo_test.rb:12",
            "spec_file_path" => "spec/foo_test.rb",
            "file_path" => "spec/foo_test.rb",
            "line_number" => 12,
            "name" => "FooTest#test_bar",
            "duration" => 1.5,
            "outcome" => "passed",
            "status" => "unannotated",
            "intent" => nil
          )
        end

        # @intent: { entity: "Minitest Reporter", action: "map a skipped result", behavior: "a skipped result reports the platform pending outcome rather than a failure", layer: "unit" }
        it "maps a skip to the platform's pending, not to a failure" do
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new)
          reporter.record(result(:skipped))
          reporter.report

          expect(reporter.instance_variable_get(:@rows).first["outcome"]).to eq("pending")
        end

        # @intent: { entity: "Minitest Reporter", action: "map failing results", behavior: "an assertion failure and an unexpected raise both map to the same failed outcome", layer: "unit" }
        it "maps an assertion failure and a raised error to the same failed outcome" do
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new)
          reporter.record(result(:assertion_failed))
          reporter.record(result(:raised))
          reporter.report

          outcomes = reporter.instance_variable_get(:@rows).map { |row| row["outcome"] }
          expect(outcomes).to eq(%w[failed failed])
        end

        # @intent: { entity: "Minitest Reporter", action: "read legacy locations", behavior: "a path colon line location string in the minitest five shape splits into file_path and line_number like the array shape does", layer: "unit" }
        it "reads the path:line String minitest 5 reports, not only the Array 6 does" do
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new)
          reporter.record(result(:passed, location: "#{Reporter.repo_root}/spec/old_test.rb:7"))
          reporter.report

          expect(reporter.instance_variable_get(:@rows).first["file_path"]).to eq("spec/old_test.rb")
        end

        # @intent: { entity: "Minitest Reporter", action: "drop unnameable results", behavior: "a result whose location carries no line is dropped from the rows rather than emitted mangled", layer: "unit" }
        it "drops a result whose location cannot be named rather than mangling it" do
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new)
          reporter.record(result(:passed, location: "no-line-in-it"))
          reporter.report

          expect(reporter.instance_variable_get(:@rows)).to be_empty
        end
      end

      describe "the relativization root" do
        # `Reporter.repo_root` memoizes into a class-level ivar on the
        # singleton, so it outlives the example that first reads it — including
        # the reads the six `result` fixture sites in this file make. This
        # borrows it for one example and puts the process back exactly as it
        # was found: cleared before, so the block's own `Dir.pwd` is what
        # binds; restored after, whether or not anything was bound to begin
        # with. It lives here and not in `lib/` — the library has no reason to
        # offer a way to unbind a root that is meant to be bound once.
        def with_unbound_repo_root
          had = Reporter.instance_variable_defined?(:@repo_root)
          previous = Reporter.instance_variable_get(:@repo_root) if had
          Reporter.remove_instance_variable(:@repo_root) if had
          yield
        ensure
          if had
            Reporter.instance_variable_set(:@repo_root, previous)
          elsif Reporter.instance_variable_defined?(:@repo_root)
            Reporter.remove_instance_variable(:@repo_root)
          end
        end

        # @intent: { entity: "Minitest Reporter", action: "relativize rows against one root", behavior: "every row of one run is relativized against the root bound when the run began, so a working-directory change mid-suite does not emit some rows relative and others absolute", layer: "unit" }
        it "keeps every row of one run in one path register when the suite changes directory mid-run" do
          Dir.mktmpdir do |dir|
            # Captured literals, deliberately: every fixture path below is
            # built from `root`, a string read ONCE before the reporter exists
            # and never re-read. Deriving them from `Reporter.repo_root`
            # instead — the shape the six sites in this file use, correctly,
            # for a different question — would make the fixture and the
            # relativization root the same moving expression, so they would
            # move together and this example could not fail however the root
            # behaved.
            root = File.realpath(dir)
            FileUtils.mkdir_p(File.join(root, "sub"))

            rows = with_unbound_repo_root do
              Dir.chdir(root) do
                reporter = Reporter.new(configuration: configuration(base_env),
                                        transport: recording_transport.first, output: StringIO.new)
                reporter.record(result(:passed, location: ["#{root}/a_test.rb", 1]))
                Dir.chdir(File.join(root, "sub")) do
                  reporter.record(result(:passed, location: ["#{root}/b_test.rb", 2]))
                end
                reporter.report
                reporter.instance_variable_get(:@rows)
              end
            end

            # Both relative to the one root, so both name the same repository
            # the platform indexes them under. Unmemoized, the second row's
            # root has moved to `sub/`, `#relative_path`'s prefix guard stops
            # matching, and it ships absolute — a well-formed spelling of the
            # same file that no validation can tell apart from a different one.
            expect(rows.map { |row| row["file_path"] }).to eq(%w[a_test.rb b_test.rb])
            expect(rows.map { |row| row["id"] }).to eq(%w[a_test.rb:1 b_test.rb:2])
          end
        end
      end

      describe "generated-test identity" do
        # A `define_method("test_x_#{param}")` loop gives every generated
        # test the SAME source_location — the define_method call site — so
        # their definition-site ids collide, and the platform's ingest
        # upserts unique_by %i[test_run_id example_id]: every repeat but the
        # first is silently dropped at ingest, taking its outcome and
        # duration with it. The family must arrive as one row per result,
        # failures included, suffixed with the CLASS-QUALIFIED name so the
        # suffix keeps distinguishing even when two classes share one call
        # site (SPGD-1013), and the plain result next to it must keep the
        # id it always had.
        # @intent: { entity: "Minitest Reporter", action: "unique ids for generated tests", behavior: "three define_method results sharing one definition site each get a per-result id while a plain result keeps its bare definition-site id", layer: "unit" }
        it "gives each result of a define_method family its own id and leaves plain rows byte-identical" do
          transport, captured = recording_transport
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: transport, output: StringIO.new)
          family = %w[test_prices_eur_at_10 test_prices_usd_at_20 test_prices_gbp_at_30]
          family.each_with_index do |name, i|
            reporter.record(result(i.even? ? :assertion_failed : :passed,
                                   name: name,
                                   location: ["#{Reporter.repo_root}/spec/pricing_test.rb", 7]))
          end
          reporter.record(result(:passed))
          reporter.report

          rows = captured.call["specs"]
          expect(rows.map { |row| row["id"] }).to contain_exactly(
            "spec/pricing_test.rb:7#FooTest#test_prices_eur_at_10",
            "spec/pricing_test.rb:7#FooTest#test_prices_usd_at_20",
            "spec/pricing_test.rb:7#FooTest#test_prices_gbp_at_30",
            "spec/foo_test.rb:12"
          )
          # The point of the fix, restated as data: the two failures are
          # rows of their own, not collapsed into the family's first member.
          expect(rows.count { |row| row["outcome"] == "failed" }).to eq(2)
          # Whatever identity bookkeeping the collision repair does, none of
          # it may leak onto the wire: the nine-key contract holds for the
          # suffixed rows exactly as for every other.
          expect(rows.map { |row| row.keys })
            .to all(contain_exactly("id", "spec_file_path", "file_path", "line_number",
                                    "name", "duration", "outcome", "status", "intent"))
        end

        # The residual SPGD-995 deliberately left, closed by SPGD-1013: a
        # bare-method-name suffix still collides when TWO classes share ONE
        # `define_method` call site and generate identically-named methods —
        # Rails' declarative `test "desc"` helper is exactly that shape (one
        # call site inside activesupport, descriptions like "valid"/"invalid"
        # repeating across test files), so every such pair in a run merged
        # into one ingested row and the second row's outcome and duration
        # vanished at ingest. The suffix is the class-qualified wire name, so
        # `ATest#test_valid` and `BTest#test_valid` land as two distinct ids
        # and BOTH failures survive the upsert.
        # @intent: { entity: "Minitest Reporter", action: "suffix collisions class-qualified", behavior: "two classes sharing one definition site with identical method names deliver two rows carrying two distinct class-qualified suffixed ids", layer: "unit" }
        it "keeps same-named generated tests of two classes distinct when they share one definition site" do
          transport, captured = recording_transport
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: transport, output: StringIO.new)
          %w[ATest BTest].each do |klass|
            reporter.record(result(:assertion_failed, klass: klass, name: "test_valid",
                                                   location: ["#{Reporter.repo_root}/spec/residual_test.rb", 13]))
          end
          reporter.report

          rows = captured.call["specs"]
          expect(rows.length).to eq(2)
          expect(rows.map { |row| row["id"] }).to contain_exactly(
            "spec/residual_test.rb:13#ATest#test_valid",
            "spec/residual_test.rb:13#BTest#test_valid"
          )
          # The failure is the point: each class runs a failing generated
          # test, and each failure must arrive as a row the ingest upsert
          # keeps — not collapsed into the other class's row.
          expect(rows.count { |row| row["outcome"] == "failed" }).to eq(2)
        end

        # Parallel mode records from its worker threads through this one shared
        # reporter in nondeterministic order, so "the first arrival keeps the
        # bare id" would make identity depend on fork scheduling. Every
        # member of a colliding group gets the suffix, so the delivered ids
        # are the same set whatever order the results arrive in — which is
        # also why two runs of the same suite produce the same ids.
        # @intent: { entity: "Minitest Reporter", action: "keep generated ids arrival-order independent", behavior: "the same colliding family recorded in reverse arrival order yields the identical set of delivered ids", layer: "unit" }
        it "delivers the same id set whatever order a colliding family arrives in" do
          ids_for = lambda do |names|
            transport, captured = recording_transport
            reporter = Reporter.new(configuration: configuration(base_env),
                                    transport: transport, output: StringIO.new)
            names.each do |name|
              reporter.record(result(:passed, name: name,
                                              location: ["#{Reporter.repo_root}/spec/pricing_test.rb", 7]))
            end
            reporter.report
            captured.call["specs"].map { |row| [row["name"], row["id"]] }.sort
          end

          family = %w[test_prices_eur_at_10 test_prices_usd_at_20 test_prices_gbp_at_30]
          expect(ids_for.call(family)).to eq(ids_for.call(family.reverse))
        end

        # The platform's upsert key is run-global, so ids must be distinct
        # ACROSS the shards of one run, not merely within one payload. A
        # family split so that two members share a shard collides there and
        # is suffixed; the lone member in the other shard keeps the bare id
        # — which the suffixed ids cannot equal — so the three still land as
        # three distinct tests of the run.
        # @intent: { entity: "Minitest Reporter", action: "unique ids across shards", behavior: "a generated family split across two shard payloads still yields one distinct id per result", layer: "unit" }
        it "keeps a shard-split generated family one distinct id per result" do
          run_shard = lambda do |names|
            transport, captured = recording_transport
            reporter = Reporter.new(configuration: configuration(base_env),
                                    transport: transport, output: StringIO.new)
            names.each do |name|
              reporter.record(result(:passed, name: name,
                                              location: ["#{Reporter.repo_root}/spec/pricing_test.rb", 7]))
            end
            reporter.report
            captured.call["specs"].map { |row| row["id"] }
          end

          shard_one = run_shard.call(%w[test_prices_eur_at_10 test_prices_usd_at_20])
          shard_two = run_shard.call(%w[test_prices_gbp_at_30])

          expect((shard_one + shard_two).uniq.length).to eq(3)
        end
      end

      describe "annotations" do
        # The real lookup against the real offline validator stub — not a
        # double — because what is under test is precisely the delegation:
        # that the reporter hands the definition-site coordinates to
        # AnnotationLookup and ships whatever verdict comes back. A double
        # here would agree with the reporter by construction.
        def stub_validator_annotations
          SpecGuard::RSpec::AnnotationLookup.new(
            env: { "SPECGUARD_VALIDATE_INTENT" => ValidatorStub.install_stubbable }
              .merge(ValidatorStub.stub_env)
          )
        end

        def annotated_suite(source)
          file = File.join(Dir.mktmpdir, "suite_test.rb")
          File.write(file, source)
          file
        end

        # @intent: { entity: "Minitest Reporter", action: "attach annotations", behavior: "a comment form annotation on the line above the definition marks the row annotated with the parsed intent", layer: "unit" }
        it "attaches a comment-form annotation from the line above the definition" do
          file = annotated_suite(<<~RUBY)
            class OrdersTest < Minitest::Test
              # @intent: { entity: "Order", action: "refund stock", behavior: "a refund restores the stock the order consumed", layer: "unit" }
              def test_restores_stock
                assert_equal 1, 1
              end

              def test_unannotated
                assert_equal 1, 1
              end
            end
          RUBY
          line = File.readlines(file).index { |l| l.include?("def test_restores_stock") } + 1

          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new,
                                  annotations: stub_validator_annotations)
          reporter.record(result(:passed, location: [file, line]))
          reporter.report

          row = reporter.instance_variable_get(:@rows).first
          expect(row["status"]).to eq("annotated")
          expect(row["intent"]).to eq(
            "entity" => "Order", "action" => "refund stock",
            "behavior" => "a refund restores the stock the order consumed", "layer" => "unit"
          )
        end

        # @intent: { entity: "Minitest Reporter", action: "attach annotations", behavior: "a trailing form annotation on the definition line itself marks the row annotated", layer: "unit" }
        it "attaches a trailing annotation written on the definition line itself" do
          file = annotated_suite(<<~RUBY)
            class OrdersTest < Minitest::Test
              def test_surfaces_decline # @intent: { entity: "Order", action: "surface decline", behavior: "a declined order surfaces the decline reason to the buyer", layer: "unit" }
                assert_equal 1, 1
              end
            end
          RUBY
          line = File.readlines(file).index { |l| l.include?("def test_surfaces_decline") } + 1

          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new,
                                  annotations: stub_validator_annotations)
          reporter.record(result(:passed, location: [file, line]))
          reporter.report

          row = reporter.instance_variable_get(:@rows).first
          expect(row["status"]).to eq("annotated")
          expect(row["intent"]).to include("entity" => "Order", "action" => "surface decline")
        end

        # Criterion 3, at the row level: a malformed annotation is a verdict
        # of nil (the lookup's own downgrade — the linter, not the telemetry,
        # is the tool that fails a build over it), so the row ships
        # unannotated and the suite's verdict is untouched.
        # @intent: { entity: "Minitest Reporter", action: "downgrade malformed annotations", behavior: "a malformed annotation on a row downgrades that row to unannotated and never affects the suite verdict", layer: "unit" }
        it "downgrades a malformed annotation to unannotated and keeps the suite green" do
          file = annotated_suite(<<~RUBY)
            class OrdersTest < Minitest::Test
              # @intent: { entity: "Order",
              def test_typo
                assert_equal 1, 1
              end
            end
          RUBY
          line = File.readlines(file).index { |l| l.include?("def test_typo") } + 1

          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new,
                                  annotations: stub_validator_annotations)
          reporter.record(result(:passed, location: [file, line]))
          reporter.report

          row = reporter.instance_variable_get(:@rows).first
          expect(row["status"]).to eq("unannotated")
          expect(row["intent"]).to be_nil
          expect(reporter.passed?).to be(true)
        end

        # The nested envelope: the outer `record` rescue would drop the whole
        # row to learn one annotation, so the lookup runs inside its own and
        # a blow-up costs the row only its annotation.
        # @intent: { entity: "Minitest Reporter", action: "survive lookup failure", behavior: "a failing annotation lookup costs the row its annotation only, warns once, and never affects the suite verdict", layer: "unit" }
        it "ships the row unannotated when the annotation lookup raises" do
          broken = SpecGuard::RSpec::AnnotationLookup.new
          allow(broken).to receive(:intent_for).and_raise(IOError, "spec file vanished")
          output = StringIO.new
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: output,
                                  annotations: broken)
          reporter.record(result(:passed))
          reporter.report

          row = reporter.instance_variable_get(:@rows).first
          expect(row["status"]).to eq("unannotated")
          expect(row["intent"]).to be_nil
          expect(reporter.passed?).to be(true)
          expect(output.string.scan("SpecGuard:").length).to eq(1)
        end

        # The once-per-process budget, pinned with a driver that can lose
        # it. Every `record` routes its failing lookup through `warn_once`,
        # so a multi-row run multiplies the calls — and only the
        # `return if @warned` guard collapses them to one line. The
        # single-record sibling above drives that guarded path once, so its
        # `scan == 1` passes identically on correct code and on a reporter
        # that warns per row (measured 1-vs-1 with the guard stripped);
        # this driver discriminates (measured 1-vs-3 at three rows). The
        # transport delivers cleanly, so the annotation route is the run's
        # only warning source — the same shape the RSpec formatter's own
        # pin uses, fifty `finish` calls behind one `WARNING_PREFIX` scan.
        # @intent: { entity: "Minitest Reporter", action: "hold the warning budget", behavior: "a multi-row run whose every annotation lookup fails warns exactly once, keeps every row recorded and unannotated, and never affects the suite verdict", layer: "unit" }
        it "warns exactly once however many rows hit a failing annotation lookup" do
          broken = SpecGuard::RSpec::AnnotationLookup.new
          allow(broken).to receive(:intent_for).and_raise(IOError, "spec file vanished")
          transport, _, calls = recording_transport
          output = StringIO.new
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: transport, output: output,
                                  annotations: broken)
          3.times { reporter.record(result(:passed)) }
          reporter.report

          rows = reporter.instance_variable_get(:@rows)
          expect(rows.length).to eq(3)
          expect(rows.map { |row| row["status"] }).to all(eq("unannotated"))
          expect(rows.map { |row| row["intent"] }).to all(be_nil)
          expect(reporter.passed?).to be(true)
          expect(calls.call).to eq(1)
          expect(output.string.scan("SpecGuard:").length).to eq(1)
          expect(output.string).to include("IOError")
        end

        # The lookup is asked in the platform's own file vocabulary — the
        # relativized path the row ships — with the definition-site line.
        # @intent: { entity: "Minitest Reporter", action: "delegate coordinates", behavior: "the reporter asks the lookup with the relativized file path and the integer line the row carries", layer: "unit" }
        it "asks the lookup with the same file and line the row carries" do
          annotations = instance_double(SpecGuard::RSpec::AnnotationLookup, intent_for: nil)
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport.first, output: StringIO.new,
                                  annotations: annotations)
          reporter.record(result(:passed))
          reporter.report

          expect(annotations).to have_received(:intent_for)
            .with(file: "spec/foo_test.rb", line: 12)
        end

        # SPGD-1417. The lookup binds its read root when the reporter constructs
        # it; the rows a mid-suite chdir used to lose are exactly these — the
        # reporter relativizes the definition site against ITS bound root
        # (SPGD-1408), the lookup then opened that relative spelling against
        # the live cwd, and a readable annotated suite read back as
        # unannotated. Two files, deliberately: the lookup builds one index
        # per file, so one file straddling the move would have its index
        # built by the first row and answer the second from the memo — green
        # on any root behaviour at all. The second file is the one whose
        # FIRST lookup happens inside the moved directory; the first is the
        # control that proves the fixture and the stub validator annotate.
        # The memo isolation is the same discipline the "the relativization
        # root" block applies to the reporter's own root: cleared before, so
        # the block's chdir is what binds it; restored after, whether or not
        # anything was bound to begin with.
        # @intent: { entity: "Minitest Reporter", action: "annotate across a mid-run chdir", behavior: "a readable annotated suite still resolves after the run changes directory, the lookup reading against the root bound at its construction", layer: "unit" }
        it "still annotates a readable suite after the run changes directory mid-run" do
          Dir.mktmpdir do |dir|
            root = File.realpath(dir)
            FileUtils.mkdir_p(File.join(root, "sub"))
            before_file = File.join(root, "before_test.rb")
            after_file = File.join(root, "after_test.rb")
            [before_file, after_file].each do |path|
              File.write(path, <<~RUBY)
                class OrdersTest < Minitest::Test
                  # @intent: { entity: "Order", action: "refund stock", behavior: "a refund restores the stock the order consumed", layer: "unit" }
                  def test_restores_stock
                    assert_equal 1, 1
                  end
                end
              RUBY
            end
            line = File.readlines(before_file)
                        .index { |l| l.include?("def test_restores_stock") } + 1

            had_repo_root = Reporter.instance_variable_defined?(:@repo_root)
            previous_repo_root = Reporter.instance_variable_get(:@repo_root) if had_repo_root
            rows = nil
            begin
              Reporter.remove_instance_variable(:@repo_root) if had_repo_root
              Dir.chdir(root) do
                reporter = Reporter.new(configuration: configuration(base_env),
                                        transport: recording_transport.first, output: StringIO.new,
                                        annotations: stub_validator_annotations)
                # Recorded before the move: binds the reporter's own
                # relativization root (SPGD-1408) to `root`, so the second
                # row relativizes to the same repo-relative spelling — and
                # doubles as the positive control that the fixture and the
                # stub validator annotate at all.
                reporter.record(result(:passed, location: [before_file, line]))
                Dir.chdir(File.join(root, "sub")) do
                  reporter.record(result(:passed, location: [after_file, line]))
                end
                reporter.report
                rows = reporter.instance_variable_get(:@rows)
              end
            ensure
              if had_repo_root
                Reporter.instance_variable_set(:@repo_root, previous_repo_root)
              elsif Reporter.instance_variable_defined?(:@repo_root)
                Reporter.remove_instance_variable(:@repo_root)
              end
            end

            expect(rows.map { |row| row["file_path"] })
              .to eq(%w[before_test.rb after_test.rb])
            expect(rows.map { |row| row["status"] }).to eq(%w[annotated annotated])
            expect(rows.last["intent"]).to include("entity" => "Order", "action" => "refund stock")
          end
        end

        # SPGD-1421. The relativization root and the lookup's read root were
        # bound at two different MOMENTS — the reporter's memo lazily, on the
        # first row; the lookup's `Dir.pwd` at construction — and nothing made
        # them agree. The hurting direction is the SHALLOWER move: a run
        # constructed in `<root>/work` whose FIRST row lands after the cwd
        # moved to the ancestor `<root>` relativizes against `<root>` —
        # `<root>/work/sample_test.rb` reads as `work/sample_test.rb` — and
        # resolves that spelling against the construction directory, doubling
        # the segment into `<root>/work/work/sample_test.rb`, which no file
        # answers. Every readable, correctly annotated spec in the run ships
        # `unannotated` / `intent: nil`, byte-for-byte what a genuinely
        # unannotated row reports, so nothing downstream can detect the loss.
        # The ordering is the discriminator, not the chdir: a row recorded
        # before the move binds the memo to the construction directory and
        # the two roots agree by luck — exactly what the SPGD-1417 pin above
        # leans on with its pre-move control row. Both arms here construct in
        # `work`; the defect arm records its first row only after the move to
        # the shallower `root`. The control arm runs with no move at all, so
        # a rig that degraded to "neither arm annotates" fails rather than
        # passing on equality. Memo isolation per arm, the same discipline
        # the pin above applies: cleared before, so each arm's own
        # construction is what binds the root — never a value an earlier arm
        # left behind, which would agree with both arms by luck and make
        # this pin green on the unfixed code; restored after.
        # @intent: { entity: "Minitest Reporter", action: "annotate after a shallower move", behavior: "a readable annotated suite still annotates when its first row is recorded after the run moves to a shallower directory, both roots reading the one value bound at construction", layer: "unit" }
        it "annotates a suite whose first row is recorded after the run moves to a shallower directory" do
          Dir.mktmpdir do |dir|
            root = File.realpath(dir)
            work = File.join(root, "work")
            FileUtils.mkdir_p(work)
            file = File.join(work, "sample_test.rb")
            File.write(file, <<~RUBY)
              class OrdersTest < Minitest::Test
                # @intent: { entity: "Order", action: "refund stock", behavior: "a refund restores the stock the order consumed", layer: "unit" }
                def test_restores_stock
                  assert_equal 1, 1
                end
              end
            RUBY
            line = File.readlines(file)
                        .index { |l| l.include?("def test_restores_stock") } + 1

            # One arm, one fresh root: the memo is cleared so the arm's own
            # construction is what binds it, and restored afterwards whether
            # or not anything was bound to begin with.
            run_suite = lambda do |&block|
              had_repo_root = Reporter.instance_variable_defined?(:@repo_root)
              previous_repo_root = Reporter.instance_variable_get(:@repo_root) if had_repo_root
              rows = nil
              begin
                Reporter.remove_instance_variable(:@repo_root) if had_repo_root
                Dir.chdir(work) do
                  reporter = Reporter.new(configuration: configuration(base_env),
                                          transport: recording_transport.first, output: StringIO.new,
                                          annotations: stub_validator_annotations)
                  block.call(reporter)
                  reporter.report
                  rows = reporter.instance_variable_get(:@rows)
                end
              ensure
                if had_repo_root
                  Reporter.instance_variable_set(:@repo_root, previous_repo_root)
                elsif Reporter.instance_variable_defined?(:@repo_root)
                  Reporter.remove_instance_variable(:@repo_root)
                end
              end
              rows
            end

            # The control: no move at all — construction, the single row and
            # delivery all happen in `work`.
            control_rows = run_suite.call do |reporter|
              reporter.record(result(:passed, location: [file, line]))
            end

            # The defect arm: construction in `work`, FIRST row recorded only
            # after the move to the shallower `root`.
            moved_rows = run_suite.call do |reporter|
              Dir.chdir(root) do
                reporter.record(result(:passed, location: [file, line]))
              end
            end

            expect(control_rows.map { |row| row["status"] }).to eq(%w[annotated])
            expect(control_rows.first["intent"])
              .to include("entity" => "Order", "action" => "refund stock")
            expect(moved_rows.map { |row| row["file_path"] }).to eq(%w[sample_test.rb])
            expect(moved_rows.map { |row| row["status"] }).to eq(%w[annotated])
            expect(moved_rows.first["intent"])
              .to include("entity" => "Order", "action" => "refund stock")
          end
        end
      end

      describe "the ingestible floor" do
        # The platform rejects a payload whose rows omit `status`
        # (`Ingest::Payload#validate_status` runs per row, and
        # `STATUSES.include?(nil)` is false), and its own E2E capture server
        # cannot see that 400 — so the floor is pinned here, against the
        # envelope the transport is actually handed: every row carries the
        # full nine-key contract, an unannotated row's intent is explicitly
        # null, and status is always the platform's own vocabulary.
        # @intent: { entity: "Minitest Reporter", action: "pin the wire contract", behavior: "every row of a zero annotation envelope carries the full key set with status unannotated and an explicit null intent", layer: "unit" }
        it "carries status and an explicit null intent on every row of an annotation-free envelope" do
          transport, captured = recording_transport
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: transport, output: StringIO.new)
          reporter.start
          reporter.record(result(:passed))
          reporter.record(result(:skipped))
          reporter.record(result(:assertion_failed))
          reporter.report

          rows = captured.call["specs"]
          expect(rows.map { |row| row.keys })
            .to all(contain_exactly("id", "spec_file_path", "file_path", "line_number",
                                    "name", "duration", "outcome", "status", "intent"))
          expect(rows.map { |row| row["status"] }).to all(eq("unannotated"))
          expect(rows.map { |row| row["intent"] }).to all(be_nil)
        end

        # The annotated side of the same envelope: `intent` present and
        # schema-valid exactly when status says annotated.
        # @intent: { entity: "Minitest Reporter", action: "pin the wire contract", behavior: "an annotated row carries status annotated with the intent the lookup returned", layer: "unit" }
        it "carries the annotated status and intent together on an annotated row" do
          annotations = instance_double(SpecGuard::RSpec::AnnotationLookup)
          intent = { "entity" => "Order", "action" => "refund stock",
                     "behavior" => "a refund restores the stock the order consumed", "layer" => "unit" }
          allow(annotations).to receive(:intent_for).and_return(intent)
          transport, captured = recording_transport
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: transport, output: StringIO.new,
                                  annotations: annotations)
          reporter.start
          reporter.record(result(:passed))
          reporter.report

          row = captured.call["specs"].first
          expect(row).to include("status" => "annotated", "intent" => intent)
        end
      end

      describe "the envelope" do
        # @intent: { entity: "Minitest Reporter", action: "build the envelope", behavior: "the delivered envelope uses the platform wire names, including ci_run_id and shard_id, with duration measured by the injected clock", layer: "unit" }
        it "carries the platform's field names, not this gem's setting names" do
          transport, captured = recording_transport
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: transport, output: StringIO.new,
                                  clock: -> { 7.0 })
          reporter.start
          reporter.record(result(:passed))
          reporter.report

          expect(captured.call).to match(
            "commit_sha" => "1" * 40,
            "branch" => "main",
            "ci_run_id" => "42",
            "shard_id" => nil,
            "duration_seconds" => 0.0,
            "specs" => array_including(hash_including("outcome" => "passed"))
          )
        end
      end

      describe "the never-fail guarantee" do
        # @intent: { entity: "Minitest Reporter", action: "fall back to the sink on refusal", behavior: "a rejected delivery appends one line to the configured output path and prints exactly one warning instead of raising", layer: "unit" }
        it "writes the local sink instead of raising when the endpoint refuses" do
          Dir.mktmpdir do |dir|
            sink = File.join(dir, "test_results.jsonl")
            env = base_env.merge("SPECGUARD_OUTPUT_PATH" => sink)
            output = StringIO.new
            reporter = Reporter.new(configuration: configuration(env),
                                    transport: recording_transport(outcome: :rejected).first,
                                    output: output)
            reporter.record(result(:passed))
            expect { reporter.report }.not_to raise_error

            expect(File.exist?(sink)).to be(true)
            expect(File.readlines(sink).length).to eq(1)
            expect(output.string).to include("SpecGuard:")
            # Once, not once per delivery attempt — the run is one problem.
            expect(output.string.scan("SpecGuard:").length).to eq(1)
            expect(reporter.passed?).to be(true)
          end
        end

        # @intent: { entity: "Minitest Reporter", action: "sink silently without a key", behavior: "with no api key configured the reporter writes the local sink file and emits no warning at all", layer: "unit" }
        it "writes the sink without any warning when no key is configured" do
          Dir.mktmpdir do |dir|
            sink = File.join(dir, "test_results.local.jsonl")
            env = base_env.except("SPECGUARD_API_KEY").merge("SPECGUARD_LOCAL_OUTPUT_PATH" => sink)
            output = StringIO.new
            reporter = Reporter.new(configuration: configuration(env),
                                    transport: recording_transport.first, output: output)
            reporter.record(result(:passed))
            reporter.report

            expect(File.exist?(sink)).to be(true)
            expect(output.string).to be_empty
          end
        end

        # The ladder's middle arm, and the reason it is worth having at all.
        # `Ingest::Payload#validate_commit_sha` refuses a blank commit and the
        # controller renders 400, so the run would be discarded whole — every
        # example, not merely the empty field. Spending the run's wall clock to
        # be told that is pure loss, so the check is a *pre-flight*: it must
        # happen before the request, not after it.
        #
        # The blank state is reached by setting the attribute rather than the
        # env var, because the two are not equivalent here: `Configuration`
        # folds a whitespace-only `SPECGUARD_COMMIT_SHA` to nil and then falls
        # through to the git probe, which in a checkout answers a real sha — so
        # the env route would silently deliver a *valid* commit and test
        # nothing. The attribute is the state a git-less container actually
        # produces.
        #
        # @intent: { entity: "Minitest Reporter", action: "gate on the commit before the request", behavior: "a run whose commit could not be resolved never reaches the transport at all and lands on the replay queue instead of the local sink", layer: "unit" }
        it "never reaches the transport when no commit could be resolved, and queues the run for replay" do
          Dir.mktmpdir do |dir|
            queue = File.join(dir, "test_results.jsonl")
            local_sink = File.join(dir, "test_results.local.jsonl")
            env = base_env.merge("SPECGUARD_OUTPUT_PATH" => queue,
                                 "SPECGUARD_LOCAL_OUTPUT_PATH" => local_sink)
            config = configuration(env)
            config.commit_sha = "   "
            transport, _captured, calls = recording_transport
            output = StringIO.new
            reporter = Reporter.new(configuration: config, transport: transport, output: output)
            reporter.record(result(:passed))
            expect { reporter.report }.not_to raise_error

            # The pre-flight claim itself: the request was never made, so the
            # wall clock the guard exists to save was actually saved.
            expect(calls.call).to eq(0)
            # The replay queue, not the local sink — a blank commit is a failed
            # delivery a re-run can recover, unlike the keyless branch at :489.
            expect(File.readlines(queue).length).to eq(1)
            expect(File.exist?(local_sink)).to be(false)
            expect(output.string).to include("SPECGUARD_COMMIT_SHA")
            expect(output.string.scan("SpecGuard:").length).to eq(1)
            expect(reporter.passed?).to be(true)
          end
        end

        # The other half, and the one the suite could not feel before: without
        # the guard the operator is not merely left unwarned, they are handed a
        # *different* sentence. The run reaches the replay queue either way, so
        # only the warning's content separates "set SPECGUARD_COMMIT_SHA" from
        # a transport error that sends the reader to debug a network which is
        # not the problem.
        #
        # The transport is stubbed `:rejected` deliberately, so that the arm
        # below this one would produce its own warning if the request were
        # allowed through — which is what makes the substitution reproducible
        # here rather than a mere absence. The negative matcher is then the
        # load-bearing half: the positive clause alone would pass against any
        # warning that merely mentions a fallback, and the `HTTP 400 — the
        # endpoint rejected the payload` a live refusal produces is exactly the
        # shape it must not be.
        #
        # @intent: { entity: "Minitest Reporter", action: "name the real cause", behavior: "the unresolvable-commit warning names the missing setting and carries no transport-error shape, so the operator is not sent to debug a rejection that never happened", layer: "unit" }
        it "names the missing commit as the cause, never a transport error" do
          Dir.mktmpdir do |dir|
            env = base_env.merge("SPECGUARD_OUTPUT_PATH" => File.join(dir, "test_results.jsonl"))
            config = configuration(env)
            config.commit_sha = "   "
            output = StringIO.new
            reporter = Reporter.new(configuration: config,
                                    transport: recording_transport(outcome: :rejected).first,
                                    output: output)
            reporter.record(result(:passed))
            reporter.report

            expect(output.string).to include("no commit sha could be resolved")
            expect(output.string).not_to match(/Errno::|400|rejected/)
            expect(reporter.passed?).to be(true)
          end
        end

        # @intent: { entity: "Minitest Reporter", action: "never redden the suite", behavior: "a reporter whose delivery was rejected still reports itself passing, so telemetry cannot fail a suite", layer: "unit" }
        it "is always a passing reporter, so telemetry can never redden a suite" do
          reporter = Reporter.new(configuration: configuration(base_env),
                                  transport: recording_transport(outcome: :rejected).first,
                                  output: StringIO.new)
          expect(reporter.passed?).to be(true)
        end

        # An unwritable sink, made unwritable WITHOUT `chmod` — deliberately,
        # and the choice is load-bearing rather than stylistic. `chmod` makes a
        # path unwritable only for SOME uids: root ignores the permission bits
        # entirely, so under a root CI image a `0o500` fixture accepts the
        # write and the pin below passes on BOTH arms of the mutation — real
        # green, fake coverage, and nothing to notice it. A regular file
        # occupying the parent-directory name is unwritable for EVERY uid,
        # which is why this fixture is correct without knowing the uid it runs
        # under. (Both halves measured in this container, uid 1000 and uid 0.)
        #
        # It raises out of `FileUtils.mkdir_p` rather than `File.open`, because
        # `#append` calls mkdir_p first — measured `Errno::EEXIST`
        # ("File exists @ dir_s_mkdir"), NOT the `Errno::ENOTDIR` the fixture's
        # shape suggests. The pin below deliberately asserts on neither: the
        # discriminating fact is the sink PATH, which is stable across both.
        #
        # Ported from the RSpec twin's `unwritable_sink!`
        # (formatter_spec.rb:1472-1476), which makes the same choice.
        def unwritable_sink_path(dir)
          blocker = File.join(dir, "blocker")
          File.write(blocker, "not a directory")
          File.join(blocker, "test_results.local.jsonl")
        end

        # The keyless branch's warning lives in `#append_local`, not in
        # `#append` — SPGD-1413 moved it there so the fall-back path could keep
        # the run's one allotted line for the delivery status (see
        # `#fall_back`). What did not move is what this example pins: that
        # warning is shadowed by `#report`'s outer
        # `rescue ScriptError, StandardError`, so deleting it does NOT make the
        # run raise, does NOT redden the reporter, and does NOT remove the
        # warning — the outer handler SUBSTITUTES a different sentence ("could
        # not ship test telemetry"). Every natural assertion in this file —
        # `include("SpecGuard:")`, the one-warning scan, `passed?` — therefore
        # passes identically on both arms and pins nothing.
        #
        # The discriminator is WHICH sentence, and specifically the one fact an
        # outer handler cannot supply: an outer rescue is by construction more
        # generic than the inner one it shadows, so what is lost is always the
        # specific fact — here the configured sink PATH, the only thing that
        # tells an operator which file to go and fix. Assert on the bytes that
        # differ.
        #
        # Measured both ways this session: deleting `#append`'s rescue (so the
        # error reaches `#report`) and deleting `#append_local`'s `warn_once`
        # (so nothing names it) each fail this example and, in the first case,
        # its SPGD-1413 sibling below — nothing else in the file moves.
        #
        # @intent: { entity: "Minitest Reporter", action: "name the unwritable sink", behavior: "an unwritable sink is swallowed and the warning names the configured sink path, so the operator learns which file could not be written rather than a generic delivery failure", layer: "unit" }
        it "names the unwritable sink path in the warning instead of a generic failure" do
          Dir.mktmpdir do |dir|
            sink = unwritable_sink_path(dir)
            env = base_env.except("SPECGUARD_API_KEY").merge("SPECGUARD_LOCAL_OUTPUT_PATH" => sink)
            output = StringIO.new
            reporter = Reporter.new(configuration: configuration(env),
                                    transport: recording_transport.first, output: output)
            reporter.record(result(:passed))
            expect { reporter.report }.not_to raise_error

            # The load-bearing clause: the path, not merely "a warning". This
            # is what the outer handler's substituted sentence cannot carry.
            expect(output.string).to include(sink)
            expect(File.exist?(sink)).to be(false)
            expect(reporter.passed?).to be(true)
          end
        end

        # The sharper half of the same guard, and the arm that used to be
        # genuinely silent. `#fall_back` settles the delivery `reason` first — a
        # landed decision, stated in the RSpec twin's own comment, because the
        # run's one allotted warning is better spent on the more specific
        # message, the one naming the status code. SPGD-1400 pinned the
        # consequence on THIS path: when a delivery was refused AND the replay
        # queue was unwritable, `warn_once`'s one-per-process budget had already
        # been spent on a sentence promising the queue, `#append`'s rescue fired
        # into a no-op, and the run was dropped behind a line reading "The test
        # run is unaffected."
        #
        # SPGD-1413 made that line true without reversing the order: the sink
        # clause is composed AFTER the write, from `#append`'s own answer, so
        # the reason still comes first and the queue is reported rather than
        # promised. The loss now has a sentence — pinned by its own example
        # below, "names the loss instead of claiming the run was saved".
        #
        # This example is the survival half, unchanged and deliberately narrow.
        # Note what it still does NOT assert — a warning COUNT, which would be a
        # pin on the order rather than on the loss; the count contract has its
        # own pins at :447, :479, :586 and :645.
        #
        # @intent: { entity: "Minitest Reporter", action: "survive an unwritable replay queue", behavior: "a rejected delivery whose replay queue cannot be written neither raises nor reddens the run, and the queue file is simply absent", layer: "unit" }
        it "survives a rejected delivery whose replay queue cannot be written" do
          Dir.mktmpdir do |dir|
            queue = unwritable_sink_path(dir)
            env = base_env.merge("SPECGUARD_OUTPUT_PATH" => queue)
            output = StringIO.new
            reporter = Reporter.new(configuration: configuration(env),
                                    transport: recording_transport(outcome: :rejected).first,
                                    output: output)
            reporter.record(result(:passed))
            expect { reporter.report }.not_to raise_error

            # The run is lost: the queue the fall-back exists to fill was never
            # created. What the suite is no longer none the wiser about is the
            # sibling example below.
            expect(File.exist?(queue)).to be(false)
            expect(reporter.passed?).to be(true)
          end
        end

        # SPGD-1413, and the half SPGD-1400 fenced off as its own slice: the
        # arm above survives the double failure, this one is what it SAYS.
        #
        # The discriminating assertion is the negative one. Every natural
        # positive clause here — `include("SpecGuard:")`, `include("HTTP 400")`,
        # the one-line scan — passes identically on the old code, because the
        # old line carried the prefix and the status too; what it also carried
        # was a promise of a replay queue that was never written. So the pin is
        # on the bytes that differ: the "unaffected" claim must be gone and the
        # unwritten queue's path must be named. Reverting `#sink_clause`'s
        # report to the old unconditional promise fails exactly this example.
        #
        # The status clause is asserted alongside it, because the whole reason
        # the order was not reversed is that the status is the more actionable
        # fact — a slice that made the loss speak by dropping HTTP 400 would
        # have traded one silence for another.
        #
        # @intent: { entity: "Minitest Reporter", action: "name a lost run", behavior: "a rejected delivery whose replay queue cannot be written prints one line that names the refusal status and the unwritten queue rather than claiming the test run is unaffected", layer: "unit" }
        it "names the loss instead of claiming the run was saved" do
          Dir.mktmpdir do |dir|
            queue = unwritable_sink_path(dir)
            env = base_env.merge("SPECGUARD_OUTPUT_PATH" => queue)
            output = StringIO.new
            reporter = Reporter.new(configuration: configuration(env),
                                    transport: recording_transport(outcome: :rejected).first,
                                    output: output)
            reporter.record(result(:passed))
            reporter.report

            # The load-bearing clause: the run was NOT saved, so the line must
            # not say it was.
            expect(output.string).not_to include("unaffected")
            expect(output.string).to include("lost")
            # And the two facts an operator needs: which refusal, which file.
            expect(output.string).to include("HTTP 400")
            expect(output.string).to include(queue)
            # Still one line, still green — the budget and the never-fail
            # contract are unchanged by making that line true.
            expect(output.string.scan("SpecGuard:").length).to eq(1)
            expect(reporter.passed?).to be(true)
          end
        end
      end
    end
  end
end
