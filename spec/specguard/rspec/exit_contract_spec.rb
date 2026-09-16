# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"
require_relative "../../support/validator_stub"

# The 0/1/2 exit contract (SPGD-12 §1), and the defence around it.
#
# Ruby maps *every* internal failure onto exit 1 — `ruby -e 'raise "boom"'`
# exits 1, and so does an uncaught `OptionParser::InvalidOption`. The contract
# has already spent 1 on "an annotation is malformed", so on the obvious
# implementation a typo'd FLAG makes CI accuse a developer of a bad annotation
# that does not exist. These examples are what keeps 1 meaning one thing.
RSpec.describe "the specguard-lint exit contract" do
  subject(:cli) { SpecGuard::RSpec::CLI.new(stdout: stdout, stderr: stderr) }

  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  def out = stdout.string
  def err = stderr.string

  # SPGD-867: with `SPECGUARD_VALIDATE_INTENT` unset the CLI resolves the
  # validator through the first-run installer. The suite must not download, so
  # resolution is stubbed to the offline replay stub — see
  # spec/support/validator_stub.rb.
  before { allow(SpecGuard::RSpec::ValidatorBackend::Installer).to receive(:obtain).and_return(ValidatorStub.install_stubbable) }

  describe "0 — clean" do
    # @intent: { entity: "specguard-lint exit contract", action: "exit clean", behavior: "a file whose annotations are all valid exits zero", layer: "unit" }
    it "exits 0 on a file whose annotations are all valid" do
      expect(cli.run([fixture_path("order_spec.rb")])).to eq(0)
    end

    # "Lint, don't require": a file with no @intent: at all is not an error.
    # This is the one thing the contract will NOT let the exit code express,
    # which is why the empty selection is loud on stderr instead.
    # @intent: { entity: "specguard-lint exit contract", action: "exit clean", behavior: "a spec file carrying no annotations at all also exits zero, since linting does not require annotating", layer: "unit" }
    it "exits 0 on a spec file carrying no annotations at all" do
      Dir.mktmpdir do |dir|
        File.write(File.join(dir, "bare_spec.rb"), "RSpec.describe(Order) { it('works') {} }\n")

        expect(cli.run([File.join(dir, "bare_spec.rb")])).to eq(0)
      end
    end

    # @intent: { entity: "specguard-lint exit contract", action: "exit clean", behavior: "an empty selection exits zero while stderr says zero spec files were selected, so vacuous green stays visible", layer: "unit" }
    it "exits 0 when nothing at all was selected, but says so on stderr" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { expect(cli.run([])).to eq(0) }
      end

      expect(err).to include("selected 0 spec files")
    end
  end

  describe "1 — malformed annotation" do
    # Criterion 1. Pinned against the RECORDED real-binary report for the
    # corpus fixture (spec/fixtures/validator/source-corpus.json) rather than
    # a temp file: since the SPGD-867 cutover the suite's validator is an
    # offline replay of recordings, and a temp file would be answered by no
    # recording at all. The fixture's line-15 annotation is the truncated
    # behavior this criterion is about.
    # @intent: { entity: "specguard-lint exit contract", action: "report a malformed annotation", behavior: "a truncated behavior exits one and names the file, line and the schema violation", layer: "unit" }
    it "exits 1 on a truncated behavior, naming file, line and the violation" do
      path = fixture_path("broken_intent_spec.rb")

      expect(cli.run([path])).to eq(1)
      expect(out).to include("FAIL  #{path}:15")
      expect(out).to include("-> behavior: string is 4 char(s), minLength is 15")
    end

    # Line 34 of the same recorded corpus is the extraction failure shape.
    # @intent: { entity: "specguard-lint exit contract", action: "report a malformed annotation", behavior: "an annotation that could not be extracted at all exits one and names the no-payload line", layer: "unit" }
    it "exits 1 on an annotation that could not be extracted at all" do
      expect(cli.run([fixture_path("broken_intent_spec.rb")])).to eq(1)
      expect(out).to include(":34 — no '{...}' object literal")
    end

    # Criterion 8. Stopping at the first would turn this one file into five CI
    # round-trips; the reference reports all five, and the report-all
    # divergence from SPGD-12 §1 step 4's "first" wording is ratified.
    # @intent: { entity: "specguard-lint exit contract", action: "report a malformed annotation", behavior: "all five failing annotations in the corpus are reported in one run, not one per CI round-trip", layer: "unit" }
    it "reports every failing annotation, not the first" do
      expect(cli.run([fixture_path("broken_intent_spec.rb")])).to eq(1)

      expect(out.scan(/^FAIL  /).length).to eq(5)
      expect(out.scan(/^FAIL  \S+:(\d+)/).flatten).to eq(%w[9 15 21 28 34])
    end

    # @intent: { entity: "specguard-lint exit contract", action: "report a malformed annotation", behavior: "every schema reason for a single annotation is listed, not just the first violation", layer: "unit" }
    it "reports every reason for a single annotation, not the first" do
      cli.run([fixture_path("broken_intent_spec.rb")])

      # Lines 9 and 21 each violate two rules.
      blocks = out.split(/^FAIL  /).drop(1)
      reasons_per_block = blocks.map { |block| block.scan(/^        -> /).length }

      expect(reasons_per_block).to eq([2, 1, 2, 0, 0])
    end

    # @intent: { entity: "specguard-lint exit contract", action: "report a malformed annotation", behavior: "the summary states checked and malformed totals so a run that checked nothing cannot read as clean", layer: "unit" }
    it "states the totals so a run that checked nothing cannot read as a clean one" do
      cli.run([fixture_path("broken_intent_spec.rb")])

      expect(out).to include("specguard-lint: checked 5 @intent annotations, 5 malformed")
    end
  end

  describe "2 — the linter could not do its job" do
    # Criterion 3. THE case: uncaught, OptionParser::InvalidOption is a 1.
    # @intent: { entity: "specguard-lint exit contract", action: "exit misuse", behavior: "an unknown flag exits two rather than accusing an annotation", layer: "unit" }
    it "exits 2 on an unknown flag rather than accusing an annotation" do
      expect(cli.run(["--bogus"])).to eq(2)
      expect(err).to include("invalid option: --bogus")
    end

    # @intent: { entity: "specguard-lint exit contract", action: "exit misuse", behavior: "a typo of a real flag exits two like any unknown flag", layer: "unit" }
    it "exits 2 on a typo of a real flag" do
      expect(cli.run(["--chnaged"])).to eq(2)
    end

    # The generic backstop would also turn an unrescued ParseError into a 2, so
    # the exit code alone does not prove the flag was recognised AS misuse.
    # A user who mistypes a flag must be told they mistyped a flag, not that
    # the linter has a bug.
    # @intent: { entity: "specguard-lint exit contract", action: "exit misuse", behavior: "a bad flag is reported as usage misuse on stderr, not as an internal error", layer: "unit" }
    it "reports a bad flag as misuse rather than as an internal error" do
      cli.run(["--bogus"])

      expect(err).to start_with("specguard-lint: error:")
      expect(err).not_to include("internal error")
    end

    # Criterion 4.
    # @intent: { entity: "specguard-lint exit contract", action: "exit misuse", behavior: "changed mode outside a git repository exits two with the reason on stderr", layer: "unit" }
    it "exits 2 when --changed is used outside a git repository" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { expect(cli.run(["--changed"])).to eq(2) }
      end

      expect(err).to include("--changed requires a git repository")
    end

    # @intent: { entity: "specguard-lint exit contract", action: "exit misuse", behavior: "combining changed mode with explicit files exits two", layer: "unit" }
    it "exits 2 when --changed is combined with explicit files" do
      expect(cli.run(["--changed", fixture_path("order_spec.rb")])).to eq(2)
      expect(out).not_to include("checked")
    end

    # Criterion 5, post-cutover. The Ruby schema-load path is gone, and the
    # way "the linter could not do its job" now arrives from the resolution
    # seam: no binary could be obtained (first run with no network, an
    # unsupported platform, a corrupted cache). That must be a 2, with a
    # message naming BOTH remediations, and it must happen before anything is
    # selected or scanned — the same fail-early rule the schema load used to
    # carry. See ValidatorBackend::Installer.
    describe "a validator that cannot be resolved" do
      before do
        allow(SpecGuard::RSpec::ValidatorBackend::Installer)
          .to receive(:obtain).and_raise(SpecGuard::RSpec::ValidatorError,
                                         "could not obtain validate-intent: no network")
      end

      # @intent: { entity: "specguard-lint exit contract", action: "exit misuse on a missing validator", behavior: "a validator binary that cannot be obtained exits two rather than one", layer: "unit" }
      it "exits 2 when no binary can be obtained" do
        expect(cli.run([fixture_path("order_spec.rb")])).to eq(2)
      end

      # @intent: { entity: "specguard-lint exit contract", action: "exit misuse on a missing validator", behavior: "the unobtainable validator is named on stderr with the error prefix", layer: "unit" }
      it "says so on stderr" do
        cli.run([fixture_path("order_spec.rb")])

        expect(err).to start_with("specguard-lint: error: could not obtain")
      end

      # The failure has to happen BEFORE anything is checked. A linter that
      # scans first and only then discovers it has no validator could report
      # "0 malformed" over a file full of violations — this project's signature
      # vacuous-green defect, arrived at from the other side.
      # @intent: { entity: "specguard-lint exit contract", action: "exit misuse on a missing validator", behavior: "the validator failure happens before any checking, so no vacuous clean run can be reported over a violating file", layer: "unit" }
      it "fails before it validates anything, rather than reporting a vacuous clean run" do
        cli.run([fixture_path("broken_intent_spec.rb")])

        expect(out).not_to include("malformed")
        expect(out).not_to include("FAIL")
      end
    end

    # Criterion 6. The backstop: whatever breaks, it is never a 1.
    describe "an unexpected internal exception" do
      # @intent: { entity: "specguard-lint exit contract", action: "contain internal errors", behavior: "an unexpected exception maps to exit two rather than letting the Ruby default one stand", layer: "unit" }
      it "exits 2 rather than letting Ruby's default 1 stand" do
        allow(SpecGuard::RSpec::ValidatorBackend).to receive(:resolve).and_raise("boom")

        expect(cli.run([fixture_path("order_spec.rb")])).to eq(2)
      end

      # SPGD-1183: the no-document decision is most load-bearing on THIS arm.
      # The misuse and validator arms crash at enumerated sites; the backstop's
      # crash sites are by definition unenumerated, so nothing structural keeps
      # stdout empty here except the decision itself. It is therefore pinned as
      # a true absence, not as a vocabulary grep: a hazard document such as
      # `{"ok": false, "findings": []}` printed from this rescue contains no
      # "FAIL" and passes `not_to include("FAIL")` while handing a
      # stdout-reading consumer a clean-looking report for a run that checked
      # nothing. The SPGD-305 block (cli_spec.rb) pins the same absence on the
      # misuse and validator arms, the sibling ingest CLI pins it on its own
      # backstop, and the specguard-ts twin on its boundary catch ("a crashed
      # run emits no document").
      # @intent: { entity: "specguard-lint exit contract", action: "contain internal errors", behavior: "an internal exception is labelled an internal error on stderr and stdout stays completely empty", layer: "unit" }
      it "reports it as an internal error, printing no document" do
        allow(SpecGuard::RSpec::ValidatorBackend).to receive(:resolve).and_raise("boom")
        cli.run([fixture_path("order_spec.rb")])

        expect(err).to include("specguard-lint: internal error: RuntimeError: boom")
        expect(out).to be_empty
      end

      # @intent: { entity: "specguard-lint exit contract", action: "contain internal errors", behavior: "a NoMethodError raised from deep inside the pipeline is caught and mapped to two", layer: "unit" }
      it "catches a NoMethodError from deep inside the pipeline too" do
        allow(SpecGuard::RSpec::ValidatorBackend).to receive(:resolve).and_raise(NoMethodError, "undefined method")

        expect(cli.run([fixture_path("order_spec.rb")])).to eq(2)
      end

      # ScriptError is not a StandardError, so a bare `rescue` misses it and
      # Ruby exits 1 again.
      # @intent: { entity: "specguard-lint exit contract", action: "contain internal errors", behavior: "a ScriptError, which a bare rescue misses, is still caught and mapped to two", layer: "unit" }
      it "catches a ScriptError, which a bare rescue would miss" do
        allow(SpecGuard::RSpec::ValidatorBackend).to receive(:resolve).and_raise(NotImplementedError, "nope")

        expect(cli.run([fixture_path("order_spec.rb")])).to eq(2)
      end

      # Ctrl-C must stay Ctrl-C. Mapping a signal onto "the linter is broken"
      # would be its own small lie, and would make the tool un-interruptible.
      # @intent: { entity: "specguard-lint exit contract", action: "contain internal errors", behavior: "an interrupt is re-raised rather than swallowed, keeping ctrl-c working", layer: "unit" }
      it "does NOT swallow an interrupt" do
        allow(SpecGuard::RSpec::ValidatorBackend).to receive(:resolve).and_raise(Interrupt)

        expect { cli.run([fixture_path("order_spec.rb")]) }.to raise_error(Interrupt)
      end
    end
  end

  # SPGD-305. `--json` is a second RENDERER over the same Linter::Result list,
  # so the contract above must be completely indifferent to it. That is easy to
  # believe and cheap to break — the flag touches #report_selection and
  # #report_results, both of which sit on the path to the return value — so it
  # is asserted at all three codes rather than argued for.
  #
  # The pairs run the SAME argv twice and compare the two codes to each other as
  # well as to the expected one. A regression that moved both (say, a renderer
  # that started swallowing an exception) would satisfy "they agree" alone.
  describe "--json changes the renderer and nothing about the exit code" do
    def code_for(argv, chdir: nil)
      run = lambda do
        SpecGuard::RSpec::CLI.new(stdout: StringIO.new, stderr: StringIO.new).run(argv)
      end

      chdir ? Dir.mktmpdir { |dir| Dir.chdir(dir) { run.call } } : run.call
    end

    ORDER = File.join(FixtureHelpers::FIXTURE_ROOT, "order_spec.rb")
    BROKEN = File.join(FixtureHelpers::FIXTURE_ROOT, "broken_intent_spec.rb")

    {
      "a clean file" => [0, [ORDER], false],
      "nothing selected at all" => [0, [], true],
      "malformed annotations" => [1, [BROKEN], false],
      "a file that could not be read" => [1, ["gone_spec.rb"], true],
      "an unknown flag" => [2, ["--bogus"], false],
      "--changed combined with explicit files" => [2, ["--changed", ORDER], false],
      "--changed outside a git repository" => [2, ["--changed"], true]
    }.each do |name, (expected, argv, in_tmpdir)|
      # @intent: { entity: "specguard-lint exit contract", action: "stay renderer-indifferent", behavior: "each exit-code class comes out identically with and without the json renderer flag", layer: "unit" }
      it "exits #{expected} either way on #{name}" do
        plain = code_for(argv, chdir: in_tmpdir)
        json = code_for(["--json", *argv], chdir: in_tmpdir)

        expect(json).to eq(plain)
        expect(json).to eq(expected)
      end
    end

    # `--require-validator` is the one exit-2 path that is about the run rather
    # than the arguments, and it is reached before any renderer is chosen.
    # @intent: { entity: "specguard-lint exit contract", action: "stay renderer-indifferent", behavior: "an unmet validator requirement exits two the same way with and without the json flag", layer: "unit" }
    it "exits 2 on an unmet --require-validator with and without the flag" do
      plain = SpecGuard::RSpec::CLI.new(stdout: StringIO.new, stderr: StringIO.new, env: {})
                                   .run(["--require-validator", fixture_path("order_spec.rb")])
      json = SpecGuard::RSpec::CLI.new(stdout: StringIO.new, stderr: StringIO.new, env: {})
                                  .run(["--json", "--require-validator", fixture_path("order_spec.rb")])

      expect(json).to eq(plain)
      expect(json).to eq(2)
    end
  end

  describe "#run never raises, whatever it is handed" do
    # The contract is only worth something if the process cannot exit any other
    # way. Every argv shape that has a plausible path to an exception.
    [
      [],
      ["--bogus"],
      ["--changed"],
      ["--changed", "--bogus"],
      ["/nonexistent/gone_spec.rb"],
      ["--"],
      ["-x"]
    ].each do |argv|
      # @intent: { entity: "specguard-lint exit contract", action: "never raise", behavior: "every argv shape with a plausible path to an exception returns a code between zero and two instead of raising", layer: "unit" }
      it "returns 0, 1 or 2 for #{argv.inspect}" do
        code = nil
        Dir.mktmpdir { |dir| Dir.chdir(dir) { expect { code = cli.run(argv) }.not_to raise_error } }

        expect(code).to be_between(0, 2)
      end
    end
  end

  # The library returning 2 is necessary but not sufficient: the exit code the
  # shell sees is the product. These run the real executable in a subprocess.
  describe "bin/specguard-lint, end to end in a real process" do
    def lint(*args, chdir: Dir.pwd)
      exe = File.expand_path("../../../bin/specguard-lint", __dir__)
      _out, _err, status = Open3.capture3(RbConfig.ruby, exe, *args, chdir: chdir)
      status.exitstatus
    end

    # @intent: { entity: "specguard-lint executable", action: "exit clean end to end", behavior: "running the real bin script on a clean file hands the shell exit zero", layer: "integration" }
    it "exits 0 on a clean file" do
      expect(lint(fixture_path("order_spec.rb"))).to eq(0)
    end

    # @intent: { entity: "specguard-lint executable", action: "report malformed end to end", behavior: "running the real bin script on malformed annotations hands the shell exit one", layer: "integration" }
    it "exits 1 on malformed annotations" do
      expect(lint(fixture_path("broken_intent_spec.rb"))).to eq(1)
    end

    # @intent: { entity: "specguard-lint executable", action: "exit misuse end to end", behavior: "running the real bin script with an unknown flag hands the shell exit two", layer: "integration" }
    it "exits 2 on an unknown flag" do
      expect(lint("--bogus")).to eq(2)
    end

    # @intent: { entity: "specguard-lint executable", action: "exit misuse end to end", behavior: "the real bin script under changed mode outside a repository hands the shell exit two", layer: "integration" }
    it "exits 2 on --changed outside a git repository" do
      Dir.mktmpdir { |dir| expect(lint("--changed", chdir: dir)).to eq(2) }
    end

    # The library returning the same code under --json is necessary but not
    # sufficient for the same reason the rest of this section exists: what CI
    # reads is the process's exit status.
    # @intent: { entity: "specguard-lint executable", action: "stay renderer-indifferent end to end", behavior: "the real bin script produces exit zero, one and two identically under the json flag, which is what CI reads", layer: "integration" }
    it "exits 0, 1 and 2 identically under --json" do
      expect(lint("--json", fixture_path("order_spec.rb"))).to eq(0)
      expect(lint("--json", fixture_path("broken_intent_spec.rb"))).to eq(1)
      expect(lint("--json", "--bogus")).to eq(2)
    end
  end
end
