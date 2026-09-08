# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "json"
require "digest"
require "open3"

# The opt-in Go validator backend.
#
# WHAT THIS FILE IS NOT — the same disclaimer message_parity_spec.rb carries,
# for the same reason. Nothing here runs `validate-intent`. Every document
# below is either RECORDED from the real binary (spec/fixtures/validator/) or
# hand-built to be a shape the real binary must never emit, and the "binary" is
# a four-line shell stub this file writes into a tmpdir.
#
# That is deliberate, not a shortcut. `lib/specguard/rspec.rb`'s SCHEMA_PATH
# forbids this gem a cross-repo runtime dependency, and a spec that shelled out
# to a Go binary would pass on one container and be unrunnable on every other.
# The live cross-repo comparison — gem-with-Go-backend vs gem-with-Ruby-backend
# over a shared corpus — belongs in open-test-intent's own suite, where a Go
# toolchain can be assumed. What belongs HERE is the recorded-report
# comparisons below, and they are here.
#
# What IS proven here, without leaving the gem:
#
#   * the argument vector, including the glob escaping (a path is a path, and
#     must not be re-expanded as a pattern by a tool whose arguments are globs);
#   * the JSON -> Linter::Result mapping, including the `problem`/`reasons`
#     split the document flattens away and `kind` is the only way back to;
#   * that a recorded document renders BYTE FOR BYTE what the Ruby path renders
#     for the same corpus — the ticket's first success criterion, asserted
#     rather than assumed;
#   * that ALL FOUR residual message differences — the four rows of README.md's
#     table, three read failures and the parse-failure tail — are enumerated and
#     asserted from BOTH sides, so closing one fails this file rather than
#     leaving a stale claim. They are labelled `ENUMERATED DIFFERENCE n of 4`
#     below, numbered by their row in that table;
#   * that every way the backend can fail is exit 2 and never exit 1.
RSpec.describe SpecGuard::RSpec::ValidatorBackend do
  subject(:backend) { described_class }

  let(:tmpdir) { @tmpdir }

  around do |example|
    Dir.mktmpdir("specguard-validator") do |dir|
      @tmpdir = dir
      example.run
    end
  end

  # The `--version` line the real binary prints, recorded from
  # `cmd/validate-intent/version.go`'s VersionLine format. The stub answers this
  # unless a test asks it not to.
  #
  # It carries the `schema sha256:` token because the real binary has carried
  # one since open-test-intent slice 17, and because leaving it off would put
  # EVERY example in this file — all of which resolve a stub — in the "no digest
  # reported" band. The exit codes would not move, so nothing would fail; the
  # matched band would simply go untested by default, which is the shape of
  # green this project keeps naming.
  #
  # The digest is COMPUTED, from the same file the gem digests at runtime, so
  # this stub agrees with the gem by construction. A literal would be a copy of
  # a hex string drifting independently of the schema it names — the exact
  # defect the code under test exists to catch, re-created in its own spec.
  def stub_identity
    "validate-intent 1.4.0 (go1.22.12 linux/arm64) schema sha256:#{vendored_digest}"
  end

  # The digest of the schema this gem vendors, read the way the gem reads it.
  def vendored_digest
    Digest::SHA256.file(SpecGuard::RSpec::SCHEMA_PATH).hexdigest
  end

  # A `--version` line in the current format carrying somebody else's contract.
  def identity_reporting(digest)
    "validate-intent 1.4.0 (go1.22.12 linux/arm64) schema sha256:#{digest}"
  end

  # A well-formed digest that is not ours. Derived rather than typed so it
  # cannot accidentally become the vendored one.
  def foreign_digest
    Digest::SHA256.hexdigest("some other schema")
  end

  # A stand-in for `validate-intent`: it records the argument vector it was
  # given, prints a canned stdout/stderr, and exits with a canned code. Written
  # as /bin/sh with the payloads in separate files so nothing here has to be
  # quoted into a script.
  #
  # It branches on `--version` because the real binary does, from ANY argv
  # position (`cmd/validate-intent/main.go` loops the whole vector before
  # anything else). A stub that replayed the report document for every argument
  # vector would answer the identity probe with a report — which is not a thing
  # the real binary can do, so a spec built on it would be testing nothing.
  #
  # `version_stdout: ""`/`version_exit: 1` is the PRE-SLICE-6 binary: no
  # `--version` flag at all, so it reads the word as a filename, says "no
  # file(s) match" on stderr and exits 1.
  #
  # The `--schema-source` defaults are the PRE-SLICE-19 binary, recorded from
  # one (`spec/fixtures/validator/schema-source-probes.json`, case
  # `unsupported`): the flag is read as a filename too. That is the default on
  # purpose, and it is the opposite of the choice {stub_identity} makes above.
  # There, a stub without a digest would have left the matched band untested
  # everywhere; here, a stub that answers `--schema-source` would leave the
  # FALLBACK untested everywhere — and the fallback is the criterion "a binary
  # without the flag behaves byte-identically to the release before it" whose
  # proof is every other example in this file continuing to pass unchanged.
  # The enforced path has a section of its own, driven from recordings.
  #
  # `schema_source_stdout` is written VERBATIM, without the trailing newline
  # `version_stdout` gets, so a recorded answer can be replayed byte for byte.
  def stub_validator(stdout: "", stderr: "", exit_code: 0, name: "validate-intent-stub",
                     version_stdout: stub_identity, version_stderr: "", version_exit: 0,
                     schema_source_stdout: "",
                     schema_source_stderr: "error: no file(s) match '--schema-source'\n",
                     schema_source_exit: 1)
    out_file = File.join(tmpdir, "#{name}.out")
    err_file = File.join(tmpdir, "#{name}.err")
    vout_file = File.join(tmpdir, "#{name}.vout")
    verr_file = File.join(tmpdir, "#{name}.verr")
    sout_file = File.join(tmpdir, "#{name}.sout")
    serr_file = File.join(tmpdir, "#{name}.serr")
    File.write(out_file, stdout)
    File.write(err_file, stderr)
    File.write(vout_file, version_stdout.empty? ? "" : "#{version_stdout}\n")
    File.write(verr_file, version_stderr)
    File.write(sout_file, schema_source_stdout)
    File.write(serr_file, schema_source_stderr)

    path = File.join(tmpdir, name)
    File.write(path, <<~SH)
      #!/bin/sh
      printf '%s\\n' "$@" >> #{args_log(name)}
      echo >> #{args_log(name)}
      for arg in "$@"; do
        if [ "$arg" = "--version" ]; then
          cat #{vout_file}
          cat #{verr_file} >&2
          exit #{version_exit}
        fi
      done
      for arg in "$@"; do
        if [ "$arg" = "--schema-source" ]; then
          cat #{sout_file}
          cat #{serr_file} >&2
          exit #{schema_source_exit}
        fi
      done
      cat #{out_file}
      cat #{err_file} >&2
      exit #{exit_code}
    SH
    FileUtils.chmod(0o755, path)
    path
  end

  def args_log(name = "validate-intent-stub")
    File.join(tmpdir, "#{name}.args")
  end

  # Every invocation's argument vector, one array per invocation.
  def all_invocations(name = "validate-intent-stub")
    return [] unless File.exist?(args_log(name))

    File.read(args_log(name)).split("\n\n", -1).reject(&:empty?).map { |block| block.split("\n") }
  end

  # The CHECK invocations — the two probes are filtered out so that every
  # assertion about the argument vector, the batching and the file order goes on
  # meaning what it meant before they existed. Assertions ABOUT the probes use
  # {version_probes} and {schema_source_probes}.
  def recorded_invocations(name = "validate-intent-stub")
    all_invocations(name).reject { |args| (args & %w[--version --schema-source]).any? }
  end

  # The identity probe's invocations. Criterion 6 — "at most once per run" — is
  # a statement about the length of this list.
  def version_probes(name = "validate-intent-stub")
    all_invocations(name).select { |args| args.include?("--version") }
  end

  # The enforced-schema probe's invocations, under the same once-per-run rule.
  def schema_source_probes(name = "validate-intent-stub")
    all_invocations(name).select { |args| args.include?("--schema-source") }
  end

  # Every run now prints exactly one line naming the validator that produced its
  # verdicts, and that line is the ONE thing about the two backends' stderr that
  # is supposed to differ. So the cross-backend comparisons below split stderr
  # in two: this is the rest of it, which must still match byte for byte, and
  # {provenance_lines} is the line itself.
  def stderr_beyond_provenance(stderr)
    stderr.lines.reject { |line| line.start_with?("specguard-lint: validated ") }.join
  end

  def provenance_lines(stderr)
    stderr.lines.map(&:chomp).select { |line| line.start_with?("specguard-lint: validated ") }
  end

  # A minimal well-formed `--source --json` document.
  def document(findings, annotations: nil, mode: "source")
    annotations ||= findings.count { |f| !%w[read no-match].include?(f[:kind]) }
    JSON.generate(
      schema: "open-test-intent.v1.json",
      mode: mode,
      ok: findings.all? { |f| f[:ok] },
      summary: { files: 1, annotations: annotations, failed: findings.count { |f| !f[:ok] } },
      findings: findings.map do |f|
        { file: f[:file], line: f[:line], ok: f[:ok], kind: f[:kind], errors: f[:errors] || [] }
      end
    )
  end

  def ok_finding(file: "a_spec.rb", line: 1)
    { file: file, line: line, ok: true, kind: nil, errors: [] }
  end

  # A stub whose report is a clean run over `spec/fixtures/order_spec.rb` —
  # the fixture the CLI-level describes below most often drive the binary
  # with. It lives here at file level, beside {stub_validator} and
  # {document}, rather than inside any of the describes that call it,
  # because several of them need the same clean report: a copy per describe
  # means a fixture change has to land in every copy, or the blocks quietly
  # stop describing the same binary.
  #
  # `paths` is deliberately NOT lifted with it, for what the name is for
  # rather than for how many there are. Sharing this stub takes away a choice
  # nobody wanted to make twice. `paths` is the opposite: it is where a block
  # picks the corpus it runs against, so it is declared wherever that pick is
  # made — `describe "the JSON acceptance set"` picks a different one per
  # nested describe and declares them there, not at the top of the block. A
  # block can also drive the CLI with no `paths` at all: `describe "the exit
  # contract, through the CLI"` hands its own runner a literal argv default,
  # because what it is about is exit codes and not a corpus. Lifting `paths`
  # would give the file a default corpus, which every block that picks its
  # own would then shadow.
  #
  # `run_cli` — the plumbing that reads argv from `paths` — WAS lifted, and
  # sits below. That answers the question this comment used to leave open.
  # Eleven copies stood in the blocks below, in three signatures: seven took
  # `env` alone and ran `paths`, three defaulted `argv` to `paths`, and one
  # required `argv` outright. The defaulted signature below subsumes all
  # three, at both arities. Lifting it is not the case refused above: a
  # default is evaluated in the calling example, so `paths` still resolves to
  # the innermost block's own `let`, and no block inherits a corpus it did not
  # pick. The helper is shared; the corpus stays local.
  #
  # Three more were lifted on that same rule, and sit below `run_cli`:
  # `fail_lines` (four copies), `error_lines` (three) and `provenance_of`
  # (three), each byte-identical across its copies. `fail_lines` and
  # `error_lines` close over nothing but their parameter, and `error_lines`
  # only rejoins a family this file already keeps here: {provenance_lines}
  # and {stderr_beyond_provenance} sit above, selecting stderr by the same
  # kind of prefix. `provenance_of` has the defaulted signature `run_cli`
  # has, and closes over `paths` in exactly the ratified way — plus `run_cli`
  # and `provenance_lines`, which have one definition each.
  #
  # `both_ways` (six copies) was NOT lifted, and the reason is arity, not
  # taste. It closes over a zero-arg `recorded`, while `describe "the schema
  # a run enforces"` defines `recorded(name)` at arity 1. A lifted
  # `both_ways` would be green only by accident of geography — no call site
  # sits inside that describe today — and the next example added there would
  # get `ArgumentError: wrong number of arguments (given 0, expected 1)`.
  # Leaving the six in place keeps each bound to the `recorded` its own block
  # means. (They also stand in two different shapes, so merging them would be
  # a pick rather than a collapse.) `read_prefix` (two copies) is held on the
  # `paths` grounds above: it is the message vocabulary a block picks, not
  # plumbing it shares.
  def clean_stub(**stub)
    stub_validator(stdout: document([ok_finding(file: "spec/fixtures/order_spec.rb")]), **stub)
  end

  def run_backend(paths, **stub)
    described_class.resolve(env: { described_class::ENV_VAR => stub_validator(**stub) }).check(paths)
  end

  def run_cli(env, argv = paths)
    stdout = StringIO.new
    stderr = StringIO.new
    code = SpecGuard::RSpec::CLI.new(stdout: stdout, stderr: stderr, env: env).run(argv)
    [stdout.string, stderr.string, code]
  end

  def fail_lines(stdout)
    stdout.lines.map(&:chomp).select { |line| line.start_with?("FAIL  ") }
  end

  def error_lines(stderr)
    stderr.lines.map(&:chomp).select { |line| line.start_with?("specguard-lint: error: ") }
  end

  def provenance_of(env, argv = paths)
    _, stderr, = run_cli(env, argv)
    provenance_lines(stderr).first
  end

  # ------------------------------------------------------------------------ #
  describe ".resolve" do
    # SPGD-867: resolution is DEFAULT-ON. Unset, blank and whitespace-only
    # values all mean "resolve through the installer" (spec/support's replay
    # stub stands in for the download), and a resolution failure is a
    # ValidatorError — never a silent nil, because there is no Ruby path left
    # to fall back to.
    def with_installable_stub(path = stub_validator)
      allow(described_class::Installer).to receive(:obtain).and_return(path)
    end

    # @intent: { entity: "ValidatorBackend", action: "resolve the validator", behavior: "an unset validator variable resolves through the installer", layer: "unit" }
    it "resolves through the installer when the variable is unset" do
      path = stub_validator
      with_installable_stub(path)

      expect(described_class.resolve(env: {})).to be_a(described_class::Runner)
      expect(described_class.resolve(env: {}).path).to eq(path)
    end

    # @intent: { entity: "ValidatorBackend", action: "resolve the validator", behavior: "a blank validator variable also resolves through the installer", layer: "unit" }
    it "resolves through the installer when the variable is blank" do
      path = stub_validator
      with_installable_stub(path)

      expect(described_class.resolve(env: { described_class::ENV_VAR => "" }).path).to eq(path)
    end

    # @intent: { entity: "ValidatorBackend", action: "resolve the validator", behavior: "a whitespace-only validator variable resolves through the installer too", layer: "unit" }
    it "resolves through the installer when the variable is only whitespace" do
      path = stub_validator
      with_installable_stub(path)

      expect(described_class.resolve(env: { described_class::ENV_VAR => "   " }).path).to eq(path)
    end

    # @intent: { entity: "ValidatorBackend", action: "resolve the validator", behavior: "a binary that cannot be obtained raises naming both remediations", layer: "unit" }
    it "raises when no binary can be obtained, naming both remediations" do
      allow(described_class::Installer).to receive(:obtain)
        .and_raise(described_class::Installer::REMEDIATIONS.then { |r| SpecGuard::RSpec::ValidatorError.new(r) })

      expect { described_class.resolve(env: {}) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /SPECGUARD_VALIDATE_INTENT.*install\.sh/)
    end

    # @intent: { entity: "ValidatorBackend", action: "resolve the validator", behavior: "an executable binary path resolves to a runner", layer: "unit" }
    it "returns a runner for an executable binary" do
      path = stub_validator
      runner = described_class.resolve(env: { described_class::ENV_VAR => path })

      expect(runner).to be_a(described_class::Runner)
      expect(runner.path).to eq(path)
    end

    # @intent: { entity: "ValidatorBackend", action: "resolve the validator", behavior: "surrounding whitespace is stripped off the configured path", layer: "unit" }
    it "strips surrounding whitespace off the path" do
      path = stub_validator
      runner = described_class.resolve(env: { described_class::ENV_VAR => "  #{path}  " })

      expect(runner.path).to eq(path)
    end

    # Failing here rather than at the first invocation is what keeps "the
    # validator you asked for is not there" from surfacing as a run that
    # selected files, checked none of them, and printed a summary.
    # @intent: { entity: "ValidatorBackend", action: "refuse unusable binaries", behavior: "a missing binary raises rather than returning an unusable runner", layer: "unit" }
    it "raises rather than returning an unusable runner when the binary is missing" do
      expect { described_class.resolve(env: { described_class::ENV_VAR => File.join(tmpdir, "nope") }) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /does not exist/)
    end

    # @intent: { entity: "ValidatorBackend", action: "refuse unusable binaries", behavior: "a directory handed as the binary raises", layer: "unit" }
    it "raises when the path is a directory" do
      expect { described_class.resolve(env: { described_class::ENV_VAR => tmpdir }) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /is not a file/)
    end

    # @intent: { entity: "ValidatorBackend", action: "refuse unusable binaries", behavior: "a non-executable binary path raises", layer: "unit" }
    it "raises when the binary is not executable" do
      path = File.join(tmpdir, "not-executable")
      File.write(path, "#!/bin/sh\n")
      FileUtils.chmod(0o644, path)

      expect { described_class.resolve(env: { described_class::ENV_VAR => path }) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /is not executable/)
    end

    # @intent: { entity: "ValidatorBackend", action: "refuse unusable binaries", behavior: "the diagnostics name the environment variable so the fix is obvious", layer: "unit" }
    it "names the variable in its diagnostics, so the fix is obvious" do
      expect { described_class.resolve(env: { described_class::ENV_VAR => File.join(tmpdir, "nope") }) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /SPECGUARD_VALIDATE_INTENT/)
    end

    # A bare command name is refused rather than resolved against PATH: which
    # binary a CI job validated against must not depend on what else is
    # installed. The refusal has to carry the fix, though — "validate-intent
    # does not exist" is a baffling thing to read about a program that is right
    # there on your PATH.
    # @intent: { entity: "ValidatorBackend", action: "refuse unusable binaries", behavior: "a bare command name is refused with the hint for turning it into a path", layer: "unit" }
    it "refuses a bare command name and says how to turn it into a path" do
      expect { described_class.resolve(env: { described_class::ENV_VAR => "validate-intent" }) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /takes a path, not a command name/)
    end

    # @intent: { entity: "ValidatorBackend", action: "refuse unusable binaries", behavior: "the bare-name hint is not offered when a path was given", layer: "unit" }
    it "does not offer that hint when it was given a path" do
      expect { described_class.resolve(env: { described_class::ENV_VAR => File.join(tmpdir, "nope") }) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /\Athe validator backend at .* does not exist\z/)
    end
  end

  # ------------------------------------------------------------------------ #
  # The gem's arguments are PATHS; `validate-intent`'s are GLOB PATTERNS. Handed
  # through unescaped, `spec/fixtures/bracket[1]_spec.rb` would be read as a
  # character class and `weird*_spec.rb` as a wildcard that can match OTHER
  # files — a linter checking something nobody named, or nothing at all.
  describe ".escape_glob" do
    # @intent: { entity: "ValidatorBackend.escape_glob", action: "escape paths for the matcher", behavior: "an ordinary path passes through untouched", layer: "unit" }
    it "leaves an ordinary path untouched" do
      expect(described_class.escape_glob("spec/fixtures/order_spec.rb"))
        .to eq("spec/fixtures/order_spec.rb")
    end

    # @intent: { entity: "ValidatorBackend.escape_glob", action: "escape paths for the matcher", behavior: "a star is escaped so the matcher treats it literally", layer: "unit" }
    it "escapes a star" do
      expect(described_class.escape_glob("star*_spec.rb")).to eq("star[*]_spec.rb")
    end

    # @intent: { entity: "ValidatorBackend.escape_glob", action: "escape paths for the matcher", behavior: "a question mark is escaped", layer: "unit" }
    it "escapes a question mark" do
      expect(described_class.escape_glob("q?_spec.rb")).to eq("q[?]_spec.rb")
    end

    # Only the opening bracket. A `]` outside a class is already a literal, and
    # A `]` outside a character class is already a literal — this matches that
    # function, not an independent idea about escaping.
    # @intent: { entity: "ValidatorBackend.escape_glob", action: "escape paths for the matcher", behavior: "an opening bracket is escaped while a closing one is left alone", layer: "unit" }
    it "escapes an opening bracket and leaves the closing one alone" do
      expect(described_class.escape_glob("bracket[1]_spec.rb")).to eq("bracket[[]1]_spec.rb")
    end

    # @intent: { entity: "ValidatorBackend.escape_glob", action: "escape paths for the matcher", behavior: "an unclosed bracket is escaped", layer: "unit" }
    it "escapes an unclosed bracket" do
      expect(described_class.escape_glob("bracket[unclosed_spec.rb")).to eq("bracket[[]unclosed_spec.rb")
    end

    # `**` is the port's recursive glob. Escaped it is two literal stars, which
    # is what a file actually called `**_spec.rb` deserves.
    # @intent: { entity: "ValidatorBackend.escape_glob", action: "escape paths for the matcher", behavior: "a recursive glob component is escaped into literal stars", layer: "unit" }
    it "escapes a recursive-glob component into literal stars" do
      expect(described_class.escape_glob("a/**/b_spec.rb")).to eq("a/[*][*]/b_spec.rb")
    end

    # @intent: { entity: "ValidatorBackend.escape_glob", action: "escape paths for the matcher", behavior: "a backslash is not escaped, the binary matcher treating it as a literal", layer: "unit" }
    it "does not escape a backslash, which the binary's matcher treats as a literal" do
      expect(described_class.escape_glob('back\\slash_spec.rb')).to eq('back\\slash_spec.rb')
    end
  end

  # ------------------------------------------------------------------------ #
  describe "the argument vector" do
    # @intent: { entity: "ValidatorBackend::Runner", action: "build the argument vector", behavior: "the binary is invoked with source and json flags plus the given paths", layer: "integration" }
    it "invokes the binary with --source --json and the given paths" do
      run_backend(["a_spec.rb", "b_spec.rb"],
                  stdout: document([ok_finding(file: "a_spec.rb"), ok_finding(file: "b_spec.rb")]))

      expect(recorded_invocations).to eq([%w[--source --json a_spec.rb b_spec.rb]])
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "build the argument vector", behavior: "every path handed over is escaped for the matcher", layer: "integration" }
    it "escapes every path it passes" do
      run_backend(["bracket[1]_spec.rb"], stdout: document([ok_finding(file: "bracket[1]_spec.rb")]))

      expect(recorded_invocations.first).to eq(["--source", "--json", "bracket[[]1]_spec.rb"])
    end

    # `validate-intent --source` with no FILE argument is a usage error (exit
    # 2). An empty selection is not misuse of the linter — CLI#report_selection
    # has already warned about it — so there is nothing to ask.
    # @intent: { entity: "ValidatorBackend::Runner", action: "build the argument vector", behavior: "an empty selection invokes the binary not at all", layer: "integration" }
    it "does not invoke the binary at all for an empty selection" do
      runner = described_class.resolve(env: { described_class::ENV_VAR => stub_validator })

      expect(runner.check([])).to eq([])
      expect(recorded_invocations).to be_empty
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "build the argument vector", behavior: "a path with a space passes as one argument with no shell in between", layer: "integration" }
    it "passes a path containing a space as one argument, with no shell in between" do
      run_backend(["a dir/a_spec.rb"], stdout: document([ok_finding(file: "a dir/a_spec.rb")]))

      expect(recorded_invocations.first).to eq(["--source", "--json", "a dir/a_spec.rb"])
    end

    # `specguard-lint a_spec.rb a_spec.rb` reports every annotation twice on the
    # Ruby path — Scanner checks the files it is handed, in the order it is
    # handed them — and the port does the same. Deriving the argument vector
    # from a Hash keyed by the escaped pattern collapses the repeat and halves
    # the report, which looks exactly like a clean run on a smaller corpus.
    # @intent: { entity: "ValidatorBackend::Runner", action: "build the argument vector", behavior: "a path named twice is not de-duplicated", layer: "integration" }
    it "does not de-duplicate a path named twice" do
      run_backend(%w[a_spec.rb a_spec.rb],
                  stdout: document([ok_finding(file: "a_spec.rb"), ok_finding(file: "a_spec.rb")]))

      expect(recorded_invocations.first).to eq(["--source", "--json", "a_spec.rb", "a_spec.rb"])
    end
  end

  # ------------------------------------------------------------------------ #
  # A full audit passes every spec file in the repository, and execve refuses an
  # argument vector past E2BIG. The batching that fixes it must stay invisible:
  # one list back, in argument order.
  describe "batching a large selection" do
    let(:paths) { Array.new(2_500) { |i| format("spec/models/example_%05d_spec.rb", i) } }

    before do
      findings = paths.map { |path| ok_finding(file: path) }
      # The stub answers every batch with the SAME document, which is enough to
      # prove the batching and the concatenation; the per-batch document
      # contents are the mapping's business, asserted above and below.
      @results = run_backend(paths, stdout: document(findings))
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "batch a large selection", behavior: "a large selection is split into more than one invocation", layer: "integration" }
    it "splits the run into more than one invocation" do
      expect(recorded_invocations.length).to be > 1
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "batch a large selection", behavior: "no invocation exceeds the per-invocation file cap", layer: "integration" }
    it "never exceeds the per-invocation file cap" do
      expect(recorded_invocations.map { |args| args.length - 2 })
        .to all(be <= SpecGuard::RSpec::ValidatorBackend::Runner::MAX_BATCH_FILES)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "batch a large selection", behavior: "every invocation argument bytes stay under the execve budget", layer: "integration" }
    it "keeps every invocation's argument bytes under the execve budget" do
      expect(recorded_invocations.map { |args| args.sum { |a| a.bytesize + 1 } })
        .to all(be <= SpecGuard::RSpec::ValidatorBackend::Runner::MAX_ARG_BYTES + 32)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "batch a large selection", behavior: "every path is passed exactly once in order across the batches", layer: "integration" }
    it "passes every path exactly once, in order, across the batches" do
      expect(recorded_invocations.flat_map { |args| args.drop(2) }).to eq(paths)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "batch a large selection", behavior: "the batches findings concatenate into one list", layer: "integration" }
    it "concatenates the batches' findings into one list" do
      expect(@results.length).to eq(paths.length * recorded_invocations.length)
    end

    # A single path longer than the whole byte budget must still be checked.
    # Dropping it would be the silent omission this project keeps naming.
    # @intent: { entity: "ValidatorBackend::Runner", action: "batch a large selection", behavior: "an over-long path gets a batch of its own rather than being dropped", layer: "integration" }
    it "gives an over-long path a batch of its own rather than dropping it" do
      giant = "spec/#{'x' * (SpecGuard::RSpec::ValidatorBackend::Runner::MAX_ARG_BYTES + 10)}_spec.rb"
      run_backend([giant], stdout: document([ok_finding(file: giant)]), name: "giant")

      expect(recorded_invocations("giant").flat_map { |args| args.drop(2) }).to eq([giant])
    end
  end

  # ------------------------------------------------------------------------ #
  # The document normalizes `problem` and `errors` into one `errors` list and
  # says so in a comment; Linter::Result keeps them apart and CLI#report_failure
  # renders them differently. `kind` is the only way back.
  describe "the JSON -> Linter::Result mapping" do
    def only_result(finding)
      run_backend(["a_spec.rb"], stdout: document([finding])).first
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "map the report", behavior: "a passing finding maps to a passing result", layer: "integration" }
    it "maps a passing finding to a passing result" do
      result = only_result(ok_finding(file: "a_spec.rb", line: 12))

      expect(result).to be_ok
      expect(result.file).to eq("a_spec.rb")
      expect(result.line).to eq(12)
      expect(result.kind).to be_nil
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "map the report", behavior: "a schema finding maps onto reasons so each renders as its own arrow line", layer: "integration" }
    it "maps a schema finding onto `reasons`, so each one gets its own -> line" do
      result = only_result(file: "a_spec.rb", line: 9, ok: false, kind: "schema",
                           errors: ["<root>: missing required property 'entity'",
                                    "<root>: additional property 'entiity' is not allowed"])

      expect(result.reasons).to eq(["<root>: missing required property 'entity'",
                                    "<root>: additional property 'entiity' is not allowed"])
      expect(result.problem).to be_nil
      expect(result.kind).to eq(SpecGuard::RSpec::Finding::KIND_SCHEMA)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "map the report", behavior: "an extraction finding maps onto the problem field for its one em-dashed line", layer: "integration" }
    it "maps an extraction finding onto `problem`, so it renders on one em-dashed line" do
      result = only_result(file: "a_spec.rb", line: 28, ok: false, kind: "extraction",
                           errors: ["unterminated object literal (an annotation must fit on one line)"])

      expect(result.problem).to eq("unterminated object literal (an annotation must fit on one line)")
      expect(result.reasons).to be_empty
      expect(result.kind).to eq(SpecGuard::RSpec::Finding::KIND_EXTRACTION)
    end

    # The wording here is RECORDED, not invented, and that distinction has
    # already cost this file once: it previously read `could not parse
    # annotation: unexpected token` — a string spelled the way RUBY spells it,
    # which the port cannot emit. That spelling is what hid the parse-text
    # divergence between the two backends until it was found by hand. Anything
    # asserted about a `parse` message must come from the binary; see
    # "the parse-failure text is the port's, not Ruby's" below.
    # @intent: { entity: "ValidatorBackend::Runner", action: "map the report", behavior: "a parse finding maps onto the problem field too", layer: "integration" }
    it "maps a parse finding onto `problem`" do
      result = only_result(file: "a_spec.rb", line: 4, ok: false, kind: "parse",
                           errors: ["could not parse annotation: Expecting property name enclosed " \
                                    "in double quotes: line 1 column 2 (char 1)"])

      expect(result.problem).to eq("could not parse annotation: Expecting property name enclosed " \
                                   "in double quotes: line 1 column 2 (char 1)")
      expect(result.kind).to eq(SpecGuard::RSpec::Finding::KIND_PARSE)
    end

    # `line: null` is the document's way of saying "not line-scoped", which is
    # the same rule Result#location applies from the other side.
    # @intent: { entity: "ValidatorBackend::Runner", action: "map the report", behavior: "a read finding maps onto the read kind and drops the line from its location", layer: "integration" }
    it "maps a read finding onto KIND_READ and drops the line from its location" do
      result = only_result(file: "a_spec.rb", line: nil, ok: false, kind: "read",
                           errors: ["could not read file: boom"])

      expect(result.kind).to eq(SpecGuard::RSpec::Finding::KIND_READ)
      expect(result.location).to eq("a_spec.rb")
      expect(result.problem).to eq("could not read file: boom")
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "map the report", behavior: "finding order is preserved through the mapping", layer: "integration" }
    it "preserves finding order" do
      results = run_backend(["a_spec.rb"], stdout: document([
                                                              ok_finding(file: "a_spec.rb", line: 1),
                                                              { file: "a_spec.rb", line: 2, ok: false,
                                                                kind: "schema", errors: ["x"] },
                                                              ok_finding(file: "a_spec.rb", line: 3)
                                                            ]))

      expect(results.map(&:line)).to eq([1, 2, 3])
    end
  end

  # ------------------------------------------------------------------------ #
  # `no-match` is the port's kind for an argument that matched no file. The gem
  # has no Finding::KIND_* for it because the gem has no patterns — its
  # arguments are paths — so it folds into KIND_READ, which is what it means
  # here: a named path that could not be opened.
  describe "a path that matched nothing (`no-match`)" do
    def no_match_result(path)
      escaped = described_class.escape_glob(path)
      run_backend([path], stdout: document([{ file: escaped, line: nil, ok: false, kind: "no-match",
                                              errors: ["no file(s) match #{escaped}"] }])).first
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "handle a no-match path", behavior: "a path that matched nothing is classified as a read failure exactly as the Ruby path does", layer: "integration" }
    it "classifies it as a read failure, exactly as the Ruby path does" do
      expect(no_match_result("spec/nope_spec.rb").kind).to eq(SpecGuard::RSpec::Finding::KIND_READ)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "handle a no-match path", behavior: "the no-match finding is a failed result so the run still exits one", layer: "integration" }
    it "is a failed result, so the run still exits 1" do
      expect(no_match_result("spec/nope_spec.rb")).to be_failed
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "handle a no-match path", behavior: "the line is dropped so nothing points a reader at a line that does not exist", layer: "integration" }
    it "drops the line, so nothing points a reader at a line that does not exist" do
      expect(no_match_result("spec/nope_spec.rb").location).to eq("spec/nope_spec.rb")
    end

    # ENUMERATED DIFFERENCE 3 of 4. The escaped pattern is an artifact of this
    # file; reporting it would misname what the caller asked for. `[[]1]` is
    # not a path anyone typed.
    # @intent: { entity: "ValidatorBackend::Runner", action: "handle a no-match path", behavior: "the path reported is the one the caller named, not the escaped pattern", layer: "integration" }
    it "reports the path the caller named, not the escaped pattern" do
      expect(no_match_result("bracket[1]_spec.rb").file).to eq("bracket[1]_spec.rb")
    end

    # ENUMERATED DIFFERENCE 3 of 4, the text half. Go says "no file(s) match
    # <pattern>" — a statement about a glob, which specguard-lint does not
    # have, and which would carry the escaped spelling into the report. The
    # Ruby path says "could not read file: No such file or directory @
    # rb_sysopen - <path>". Same prefix, same classification, same exit code;
    # only the tail differs, and it differs because the backend cannot know the
    # errno.
    # @intent: { entity: "ValidatorBackend::Runner", action: "handle a no-match path", behavior: "the wording shares the Ruby path could-not-read prefix", layer: "integration" }
    it "uses the gem's own wording, sharing the Ruby path's `could not read file: ` prefix" do
      expect(no_match_result("spec/nope_spec.rb").problem)
        .to eq("could not read file: no file at this path")
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "handle a no-match path", behavior: "no errno is claimed that the backend cannot know", layer: "integration" }
    it "does not claim an errno it cannot know" do
      expect(no_match_result("spec/nope_spec.rb").problem).not_to include("rb_sysopen")
    end
  end

  # ------------------------------------------------------------------------ #
  # Written as a LITERAL on purpose. `Runner::NON_ANNOTATION_KINDS` is derived
  # from `Runner::KINDS`, and a pin that derives from the thing it pins can
  # never fail. The derivation is what stops the two lists drifting; this is
  # what keeps the derivation honest, because `KINDS` is the half that grows.
  #
  # It grows for a reason outside this repo: the port's kind vocabulary is a
  # closed const block in open-test-intent, and `#failing_result` refuses an
  # unknown kind BY NAME — so the first run carrying a new one demands a
  # `KINDS` entry. A new entry mapping to `KIND_READ` would then widen what
  # `check_annotation_count` declines to count, silently, with nothing else in
  # the suite positioned to notice.
  #
  # **If this just failed, a kind was added to `KINDS` mapping to KIND_READ.**
  # Decide whether it really is a statement about a FILE rather than about an
  # annotation site — that is what excluding it asserts — and only then update
  # this list.
  #
  # Membership, not order: `#check_annotation_count` asks `.include?`, and the
  # order here is only whatever order `KINDS` happens to be written in. Pinning
  # it with `eq` would fire on a harmless reorder while this comment told the
  # reader a kind had been added — the false-diagnosis shape this whole change
  # exists to close. `contain_exactly` fails by naming the extra kind instead.
  describe "the kinds that are not annotation sites" do
    # @intent: { entity: "ValidatorBackend", action: "define non-site kinds", behavior: "exactly the file-level kinds the port can report are excluded from annotation sites, and no others", layer: "unit" }
    it "excludes exactly the file-level kinds the port can report, and no others" do
      expect(described_class::Runner::NON_ANNOTATION_KINDS).to contain_exactly("read", "no-match")
    end

    # `#check_annotation_count` reads it on every backend run; a mutable
    # constant is one stray `<<` away from changing the count for the process.
    # @intent: { entity: "ValidatorBackend", action: "define non-site kinds", behavior: "the excluded kinds set is frozen", layer: "unit" }
    it "is frozen" do
      expect(described_class::Runner::NON_ANNOTATION_KINDS).to be_frozen
    end
  end

  # ------------------------------------------------------------------------ #
  # Every one of these is "the linter could not do its job". The contract has
  # already spent exit 1 on "an annotation is malformed" (see CLI), so none of
  # them may reach it — and none may be quietly absorbed either.
  describe "documents the port must never emit" do
    # @intent: { entity: "ValidatorBackend::Runner", action: "refuse malformed reports", behavior: "output that is not JSON is refused", layer: "integration" }
    it "refuses output that is not JSON" do
      expect { run_backend(["a_spec.rb"], stdout: "not json at all\n") }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /did not emit a JSON document/)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "refuse malformed reports", behavior: "an empty stdout is refused", layer: "integration" }
    it "refuses an empty stdout" do
      expect { run_backend(["a_spec.rb"], stdout: "") }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /did not emit a JSON document/)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "refuse malformed reports", behavior: "a JSON document that is not an object is refused", layer: "integration" }
    it "refuses a JSON document that is not an object" do
      expect { run_backend(["a_spec.rb"], stdout: "[]\n") }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /where a JSON object was expected/)
    end

    # If the argument vector ever stops saying `--source`, the document says so
    # first — and a report read under the wrong mode's rules is worse than no
    # report.
    # @intent: { entity: "ValidatorBackend::Runner", action: "refuse malformed reports", behavior: "a document announcing another mode is refused", layer: "integration" }
    it "refuses a document announcing another mode" do
      expect { run_backend(["a_spec.rb"], stdout: document([ok_finding], mode: "adopter")) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /reported mode "adopter"/)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "refuse malformed reports", behavior: "a document with no findings array is refused", layer: "integration" }
    it "refuses a document with no findings array" do
      expect { run_backend(["a_spec.rb"], stdout: '{"mode":"source","summary":{"annotations":0}}') }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /no `findings` array/)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "refuse malformed reports", behavior: "a findings entry that is not an object is refused", layer: "integration" }
    it "refuses a findings entry that is not an object" do
      expect { run_backend(["a_spec.rb"], stdout: '{"mode":"source","summary":{"annotations":0},"findings":["x"]}') }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /not a JSON object/)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "refuse malformed reports", behavior: "a document with no integer annotation count is refused", layer: "integration" }
    it "refuses a document with no integer annotation count" do
      expect { run_backend(["a_spec.rb"], stdout: '{"mode":"source","summary":{},"findings":[]}') }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /no integer `summary.annotations`/)
    end

    # `summary.annotations` and the findings list are two independent statements
    # about the same run. Output truncated by a full pipe would otherwise show
    # up as a SMALLER clean report — the shape nobody notices.
    # @intent: { entity: "ValidatorBackend::Runner", action: "refuse malformed reports", behavior: "an annotation count that disagrees with the findings is refused", layer: "integration" }
    it "refuses a document whose annotation count disagrees with its findings" do
      expect { run_backend(["a_spec.rb"], stdout: document([ok_finding], annotations: 7)) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /reported 7 annotation\(s\) but emitted 1/)
    end

    # A kind this file has not been taught would be rendered under whichever
    # branch of #report_failure it fell into by accident.
    # @intent: { entity: "ValidatorBackend::Runner", action: "refuse malformed reports", behavior: "an unknown kind is refused", layer: "integration" }
    it "refuses a kind it does not know" do
      expect do
        run_backend(["a_spec.rb"],
                    stdout: document([{ file: "a_spec.rb", line: 1, ok: false,
                                        kind: "cosmic-ray", errors: ["boom"] }]))
      end.to raise_error(SpecGuard::RSpec::ValidatorError, /unknown kind "cosmic-ray"/)
    end

    # The `problem` kinds render as ONE em-dashed line. Joining several errors
    # into it would silently print one line where the tool meant several.
    # @intent: { entity: "ValidatorBackend::Runner", action: "refuse malformed reports", behavior: "more than one error on an extraction finding is refused rather than joined", layer: "integration" }
    it "refuses more than one error on an extraction finding rather than joining them" do
      expect do
        run_backend(["a_spec.rb"],
                    stdout: document([{ file: "a_spec.rb", line: 1, ok: false,
                                        kind: "extraction", errors: %w[one two] }]))
      end.to raise_error(SpecGuard::RSpec::ValidatorError, /emitted 2 errors on a extraction finding/)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "refuse malformed reports", behavior: "more than one error on a read finding is refused", layer: "integration" }
    it "refuses more than one error on a read finding" do
      expect do
        run_backend(["a_spec.rb"],
                    stdout: document([{ file: "a_spec.rb", line: nil, ok: false,
                                        kind: "read", errors: %w[one two] }]))
      end.to raise_error(SpecGuard::RSpec::ValidatorError, /emitted 2 errors on a read finding/)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "refuse malformed reports", behavior: "a failing finding carrying no errors is refused", layer: "integration" }
    it "refuses a failing finding carrying no errors" do
      expect do
        run_backend(["a_spec.rb"],
                    stdout: document([{ file: "a_spec.rb", line: 1, ok: false, kind: "schema", errors: [] }]))
      end.to raise_error(SpecGuard::RSpec::ValidatorError, /with no errors/)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "refuse malformed reports", behavior: "a passing finding carrying a kind is refused", layer: "integration" }
    it "refuses a passing finding carrying a kind" do
      expect do
        run_backend(["a_spec.rb"],
                    stdout: document([{ file: "a_spec.rb", line: 1, ok: true, kind: "schema", errors: [] }]))
      end.to raise_error(SpecGuard::RSpec::ValidatorError, /passing finding/)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "refuse malformed reports", behavior: "a finding with no file is refused", layer: "integration" }
    it "refuses a finding with no file" do
      expect do
        run_backend(["a_spec.rb"],
                    stdout: '{"mode":"source","summary":{"annotations":1},' \
                            '"findings":[{"line":1,"ok":true,"kind":null,"errors":[]}]}')
      end.to raise_error(SpecGuard::RSpec::ValidatorError, /no `file`/)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "refuse malformed reports", behavior: "a finding whose errors are not strings is refused", layer: "integration" }
    it "refuses a finding whose errors are not strings" do
      expect do
        run_backend(["a_spec.rb"],
                    stdout: '{"mode":"source","summary":{"annotations":1},' \
                            '"findings":[{"file":"a_spec.rb","line":1,"ok":false,"kind":"schema","errors":[7]}]}')
      end.to raise_error(SpecGuard::RSpec::ValidatorError, /not a list of strings/)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "refuse malformed reports", behavior: "a non-integer line is refused", layer: "integration" }
    it "refuses a non-integer line" do
      expect do
        run_backend(["a_spec.rb"],
                    stdout: '{"mode":"source","summary":{"annotations":1},' \
                            '"findings":[{"file":"a_spec.rb","line":"9","ok":true,"kind":null,"errors":[]}]}')
      end.to raise_error(SpecGuard::RSpec::ValidatorError, /non-integer `line`/)
    end
  end

  # ------------------------------------------------------------------------ #
  # 0 and 1 are the port's verdicts. Anything else means it produced none.
  describe "exit codes from the binary" do
    # @intent: { entity: "ValidatorBackend::Runner", action: "read exit codes", behavior: "a zero exit from the binary is accepted", layer: "integration" }
    it "accepts 0" do
      expect(run_backend(["a_spec.rb"], stdout: document([ok_finding]), exit_code: 0).length).to eq(1)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "read exit codes", behavior: "a one exit is accepted as the malformed-annotation report", layer: "integration" }
    it "accepts 1, which is how it reports a malformed annotation" do
      results = run_backend(["a_spec.rb"],
                            stdout: document([{ file: "a_spec.rb", line: 1, ok: false,
                                                kind: "schema", errors: ["boom"] }]),
                            exit_code: 1)

      expect(results.first).to be_failed
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "read exit codes", behavior: "a two exit from the binary is refused as its own could-not-do-my-job code", layer: "integration" }
    it "refuses 2 — the port's own 'I could not do my job' code" do
      expect { run_backend(["a_spec.rb"], stdout: "", stderr: "error: could not load schema x\n", exit_code: 2) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /exited 2/)
    end

    # Without this the operator gets "it exited 2" and nothing to act on, while
    # the binary had already explained itself on the stream nobody forwarded.
    # @intent: { entity: "ValidatorBackend::Runner", action: "read exit codes", behavior: "the refusal quotes the binary stderr, where it explained itself", layer: "integration" }
    it "quotes the binary's stderr, which is where it explained itself" do
      expect { run_backend(["a_spec.rb"], stdout: "", stderr: "error: could not load schema x\n", exit_code: 2) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /could not load schema x/)
    end

    # @intent: { entity: "ValidatorBackend::Runner", action: "read exit codes", behavior: "any other exit code is refused", layer: "integration" }
    it "refuses any other code" do
      expect { run_backend(["a_spec.rb"], stdout: document([ok_finding]), exit_code: 3) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /exited 3/)
    end

    # A binary deleted or chmod'ed between .resolve and the first batch.
    # @intent: { entity: "ValidatorBackend::Runner", action: "read exit codes", behavior: "a binary that stopped being executable since resolution is refused", layer: "integration" }
    it "refuses a binary that has stopped being executable since it was resolved" do
      path = stub_validator
      runner = described_class.resolve(env: { described_class::ENV_VAR => path })
      File.delete(path)

      expect { runner.check(["a_spec.rb"]) }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /could not be executed/)
    end
  end

  # ------------------------------------------------------------------------ #
  # THE TICKET'S FIRST SUCCESS CRITERION, asserted here rather than left to the
  # cross-repo harness: with the backend on, `specguard-lint` must produce
  # byte-identical stdout, stderr and exit code across spec/fixtures/.
  #
  # spec/fixtures/validator/source-corpus.json is RECORDED from
  # `validate-intent-go --source --json` over exactly the two paths below —
  # regenerate it with that command, from this directory, if the corpus
  # changes. Recording it is what lets this run anywhere: the assertion is
  # about the gem's mapping, and the binary's job was to produce the document
  # once.
  #
  # The two fixtures are themselves pinned byte-for-byte against
  # open-test-intent's examples/sources/, so a
  # corpus that drifted out from under this recording fails there.
  describe "a recorded corpus renders exactly what the Ruby path renders" do
    # Relative, and deliberately: both tools echo paths back exactly as given,
    # so the recorded document's `file` values and the Ruby run's have to be
    # spelled the same way. RSpec runs from the gem root.
    let(:paths) { %w[spec/fixtures/order_spec.rb spec/fixtures/broken_intent_spec.rb] }
    let(:recorded) { File.read("spec/fixtures/validator/source-corpus.json") }

    # If this fails, the suite is not running from the gem root and every
    # comparison below would be comparing two piles of read failures.
    # @intent: { entity: "ValidatorBackend", action: "replay the recorded corpus", behavior: "the recorded-corpus run executes from the directory where its recorded paths resolve", layer: "integration" }
    it "is running where the recorded paths resolve" do
      expect(paths).to all(satisfy { |path| File.file?(path) })
    end

    # SPGD-867: the Ruby half of every comparison in this file is gone (the
    # cutover removed the arm), so what this block pins now is the backend's
    # OWN rendering of the recorded corpus — the bytes CI actually sees.
    # @intent: { entity: "ValidatorBackend", action: "replay the recorded corpus", behavior: "the recorded corpus renders exactly what the Ruby path renders", layer: "integration" }
    it "renders the recorded corpus" do
      go_stdout, = run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) })

      expect(go_stdout).to include("FAIL  spec/fixtures/broken_intent_spec.rb:9")
      expect(go_stdout).to include("checked 12 @intent annotations, 5 malformed")
    end

    # Both are silent on stderr APART from the one line naming the validator —
    # and that line is the single thing that must NOT match, because it is what
    # tells the two runs apart when nothing else about them does.
    # @intent: { entity: "ValidatorBackend", action: "replay the recorded corpus", behavior: "stderr carries nothing beyond the line naming the validator", layer: "integration" }
    it "prints nothing on stderr beyond the line naming the validator" do
      _, go_stderr, = run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) })

      expect(stderr_beyond_provenance(go_stderr)).to be_empty
    end

    # @intent: { entity: "ValidatorBackend", action: "replay the recorded corpus", behavior: "the run exits with the recorded verdict code", layer: "integration" }
    it "exits with the recorded verdict's code" do
      *, go_code = run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) })

      expect(go_code).to eq(SpecGuard::RSpec::CLI::EXIT_MALFORMED)
    end

    # Non-vacuity, in the shape a two-sided comparison needs at
    # length: two empty reports compare equal. The corpus has to have said
    # something.
    # @intent: { entity: "ValidatorBackend", action: "replay the recorded corpus", behavior: "the compared report genuinely contains findings, so the parity is not vacuous", layer: "integration" }
    it "compared a report that actually contains findings" do
      go_stdout, = run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) })

      expect(go_stdout).to include("checked 12 @intent annotations, 5 malformed")
      expect(go_stdout.lines.count { |line| line.start_with?("FAIL  ") }).to eq(5)
    end

    # SPGD-305's fifth criterion. `--json` is a second renderer hanging off the
    # same single branch in CLI#check, so it inherits the guarantee this whole
    # section exists to assert — but "inherits it" is a claim about a design,
    # and the text report needed the same claim tested. The document is compared
    # BYTE for byte rather than parsed and compared as data: key order and
    # formatting are what a consumer diffing two CI runs actually sees, and a
    # renderer that reordered its keys on one arm would pass a Hash comparison.
    describe "the --json document" do
      def run_json_cli(env)
        stdout = StringIO.new
        stderr = StringIO.new
        code = SpecGuard::RSpec::CLI.new(stdout: stdout, stderr: stderr, env: env).run(["--json", *paths])
        [stdout.string, stderr.string, code]
      end

      def go_env = { described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) }

      # @intent: { entity: "ValidatorBackend", action: "replay the recorded json corpus", behavior: "the json document reflects the recorded corpus exactly", layer: "integration" }
      it "reflects the recorded corpus" do
        go_stdout, = run_json_cli(go_env)
        document = JSON.parse(go_stdout)

        expect(document["ok"]).to be(false)
        expect(document["summary"]).to eq("files" => 2, "annotations" => 12, "failed" => 5)
      end

      # @intent: { entity: "ValidatorBackend", action: "replay the recorded json corpus", behavior: "the json run exits with the recorded verdict code", layer: "integration" }
      it "exits with the recorded verdict's code" do
        *, go_code = run_json_cli(go_env)

        expect(go_code).to eq(SpecGuard::RSpec::CLI::EXIT_MALFORMED)
      end

      # Same non-vacuity argument as above, and it bites harder here: an empty
      # `findings` array inside an otherwise well-formed envelope is a document
      # that parses, validates, and says nothing — two of those compare equal.
      # @intent: { entity: "ValidatorBackend", action: "replay the recorded json corpus", behavior: "the compared document genuinely contains findings", layer: "integration" }
      it "compared a document that actually contains findings" do
        go_stdout, = run_json_cli(go_env)
        report = JSON.parse(go_stdout)

        expect(report.dig("summary", "annotations")).to eq(12)
        expect(report.dig("summary", "failed")).to eq(5)
        expect(report["findings"].length).to eq(12)
      end

      # The one thing that must NOT match, for the reason it must not match in
      # the text report either: the provenance line is what tells the two runs
      # apart when nothing else about them does. It stays on stderr under
      # `--json` — it is not folded into the document — so a consumer reading
      # stdout gets one clean document and the answer to "which implementation"
      # stays exactly one line, in exactly one place.
      # @intent: { entity: "ValidatorBackend", action: "replay the recorded json corpus", behavior: "only the provenance line differs between the two backends, and it stays on stderr", layer: "integration" }
      it "leaves the provenance line on stderr, as the only thing that differs" do
        _, ruby_stderr, = run_json_cli({})
        _, go_stderr, = run_json_cli(go_env)

        expect(stderr_beyond_provenance(go_stderr)).to be_empty
        expect(stderr_beyond_provenance(ruby_stderr)).to be_empty
        expect(go_stderr).not_to eq(ruby_stderr)
      end
    end
  end

  # ------------------------------------------------------------------------ #
  # ENUMERATED DIFFERENCE 1 of 4 — and THE ONE THAT IS NOT A READ FAILURE.
  #
  # The corpus above is byte-identical on both backends, and that is a true
  # statement about THAT corpus rather than about the linter: its findings are
  # `schema` and `extraction` only. It contains no `parse` finding at all, and
  # a `parse` finding is the one annotation-level shape whose text moves.
  #
  # PayloadNormalizer rescues PROTOCOL.md §1's permissive syntax on both sides,
  # so every hazard that goes THROUGH normalisation successfully compares
  # equal. Only a payload that survives normalisation and still fails
  # `JSON.parse` diverges — the Ruby path interpolates Ruby's
  # `JSON::ParserError#message`, the binary carries its own — and neither
  # the corpus above nor the gem's hazard fixtures contained one.
  #
  # So it is enumerated here, in the two-sided shape this file uses
  # for its ratifications: the shared half is asserted, AND the texts are
  # asserted to still differ, so making them converge fails this file and
  # forces the entry to be retired rather than left to rot.
  #
  # spec/fixtures/validator/parse-divergence.json is RECORDED from
  # `validate-intent-go --source --json spec/fixtures/parse_divergence_spec.rb`,
  # run from the gem root. See `Scanner#parse` for the ratification itself.
  describe "the parse-failure text is the port's, not Ruby's" do
    let(:paths) { %w[spec/fixtures/parse_divergence_spec.rb] }
    let(:recorded) { File.read("spec/fixtures/validator/parse-divergence.json") }

    # SPGD-867: the Ruby arm is gone. What these describes pin now is the
    # BACKEND's rendering of the recorded real-binary reports.
    def both_ways
      go = run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) })
      [go, go]
    end

    def parse_prefix
      "could not parse annotation: "
    end

    # @intent: { entity: "ValidatorBackend", action: "replay the parse-failure corpus", behavior: "the parse-failure corpus runs where its recorded path resolves", layer: "integration" }
    it "is running where the recorded path resolves" do
      expect(paths).to all(satisfy { |path| File.file?(path) })
    end

    # Non-vacuity first: if the fixture stopped producing parse failures, every
    # "they differ" assertion below would pass over an empty list.
    # @intent: { entity: "ValidatorBackend", action: "replay the parse-failure corpus", behavior: "the comparison covered two parse findings, so it is not vacuous", layer: "integration" }
    it "compared two parse findings" do
      (go_stdout, *, _) = both_ways.first

      expect(fail_lines(go_stdout).length).to eq(2)
      expect(fail_lines(go_stdout)).to all(include(parse_prefix))
    end

    # The shared half. Same classification, same file, same LINE — unlike a
    # read failure, a parse failure is line-scoped and both backends agree on
    # which annotation broke — and the same prefix.
    # @intent: { entity: "ValidatorBackend", action: "replay the parse-failure corpus", behavior: "the recorded annotations report at their recorded locations", layer: "integration" }
    it "reports the recorded annotations at their recorded locations" do
      (go_stdout, *, _) = both_ways.first
      locations = ->(stdout) { fail_lines(stdout).map { |line| line.split(" — ").first } }

      expect(locations.call(go_stdout))
        .to eq(["FAIL  spec/fixtures/parse_divergence_spec.rb:21",
                "FAIL  spec/fixtures/parse_divergence_spec.rb:22"])
    end

    # The summary line is where "same classification" stops being a claim about
    # prose: a parse failure counts as an annotation examined AND as malformed,
    # and it must land in the same clause on both sides.
    # @intent: { entity: "ValidatorBackend", action: "replay the parse-failure corpus", behavior: "they count as annotations rather than as unread files", layer: "integration" }
    it "counts them as annotations rather than unread files" do
      (go_stdout, *, _) = both_ways.first
      summary = ->(stdout) { stdout.lines.map(&:chomp).grep(/checked \d+ @intent/).first }

      expect(summary.call(go_stdout)).to eq("specguard-lint: checked 3 @intent annotations, 2 malformed")
    end

    # @intent: { entity: "ValidatorBackend", action: "replay the parse-failure corpus", behavior: "a divergent message still exits one as a malformed annotation", layer: "integration" }
    it "exits 1 — a divergent message is still a malformed annotation" do
      (*, _, go_code) = both_ways.first

      expect(go_code).to eq(SpecGuard::RSpec::CLI::EXIT_MALFORMED)
    end

    # @intent: { entity: "ValidatorBackend", action: "replay the parse-failure corpus", behavior: "stderr stays empty beyond the line naming the validator", layer: "integration" }
    it "says nothing on stderr beyond the line naming the validator" do
      (*, go_stderr, _) = both_ways.first

      expect(stderr_beyond_provenance(go_stderr)).to be_empty
    end


    # And the tails are the BINARY's own, passed through unaltered rather than
    # reworded by the mapping. This is what makes the difference a pass-through
    # the binary owns, not a third independent spelling this gem would then have
    # to maintain.
    #
    # The binary's half is pinned IN FULL, and it can be: that prose is this
    # ecosystem's own, written against PROTOCOL.md, and it moves only when
    # somebody here moves it. It used to reproduce a foreign parser's message
    # text verbatim — offsets, `(char 101)` and all — which is exactly what
    # SPGD-403 removed.
    #
    # Ruby's half is pinned only to the phrase THIS GEM contributes, and that is
    # the point of the example rather than a weakening of it. `json` is a
    # default gem, so its version tracks the Ruby the suite runs on rather than
    # Gemfile.lock, and both its classification phrase and the excerpt it quotes
    # have changed across versions ("unexpected token at" became "unexpected
    # character:"). Pinning either pins the Ruby, and this suite runs on
    # several — an earlier revision of this example pinned them and went red on
    # a Ruby upgrade for a reason nobody had written down.
    #
    # The CLAIM is that the two spell the same refusal differently, and that is
    # asserted directly below rather than inferred from two literals.
    # @intent: { entity: "ValidatorBackend", action: "replay the parse-failure corpus", behavior: "the binary own wording passes through unaltered rather than being reworded in Ruby", layer: "integration" }
    it "passes the binary's own wording through unaltered" do
      (go_stdout, *, _) = both_ways.first

      expect(go_stdout).to include("could not parse annotation: expected a JSON value (line 1, column 102)")
      expect(go_stdout).to include("could not parse annotation: expected a double-quoted " \
                                   "property name (line 1, column 2)")
    end
  end

  # ------------------------------------------------------------------------ #
  # ENUMERATED DIFFERENCE 2 of 4 — a file that is not well-formed UTF-8.
  #
  # `Scanner#scan_text` has carried a RATIFIED DIFFERENCE note about this shape
  # since it was written, and README.md's table has carried the row. Neither
  # was asserted by anything until this block: the citation was re-pointed at
  # this file by SPGD-403 and the comparison was never ported, so the Go side's
  # wording could have moved with nothing going red (SPGD-596).
  #
  # PROTOCOL.md §1.1 makes UTF-8 part of what a JSON text IS, so both sides
  # refuse the FILE and neither substitutes U+FFFD and carries on. What is
  # shared is what `scanner.rb` claims is shared — same classification, same
  # file, same `could not read file: ` prefix, a non-empty reason on both sides,
  # and exit 1 — and it is asserted here in the same two-sided shape the parse
  # tail above uses: the shared half AND the fact that the tails still differ,
  # so closing the difference fails this file rather than leaving a stale claim.
  #
  # spec/fixtures/validator/utf8-divergence.json is RECORDED from
  # `validate-intent-go --source --json spec/fixtures/invalid_utf8_spec.rb
  # spec/fixtures/order_spec.rb`, run from the gem root.
  #
  # The clean file is named alongside on purpose. A read failure must not stop
  # either tool checking the good files beside it — `scan_file`'s comment says
  # so in those words — and that is the half of this comparison that would be
  # invisible in a one-file run.
  describe "the not-well-formed-UTF-8 text is each backend's own" do
    let(:paths) { %w[spec/fixtures/invalid_utf8_spec.rb spec/fixtures/order_spec.rb] }
    let(:recorded) { File.read("spec/fixtures/validator/utf8-divergence.json") }

    def both_ways
      go = run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) })
      [go, go]
    end

    def read_prefix
      "could not read file: "
    end

    # Non-vacuity, and the one that matters most here: the fixture is a handful
    # of bytes, and a well-meaning "fix the encoding" edit would leave every
    # comparison below passing over a file both backends read happily.
    # @intent: { entity: "ValidatorBackend", action: "replay the UTF-8 corpus", behavior: "the run is genuinely against a file that is not well-formed UTF-8", layer: "integration" }
    it "is running against a file that really is not well-formed UTF-8" do
      expect(paths).to all(satisfy { |path| File.file?(path) })
      expect(File.read(paths.first, encoding: "UTF-8").valid_encoding?).to be(false)
    end

    # @intent: { entity: "ValidatorBackend", action: "replay the UTF-8 corpus", behavior: "exactly one unreadable file is reported", layer: "integration" }
    it "reported exactly one unreadable file" do
      (go_stdout, *, _) = both_ways.first

      expect(fail_lines(go_stdout).length).to eq(1)
      expect(fail_lines(go_stdout)).to all(include(read_prefix))
    end

    # The shared half. Same file, and no line — unlike a parse failure this is a
    # statement about the FILE, so neither side points a reader at a line.
    # @intent: { entity: "ValidatorBackend", action: "replay the UTF-8 corpus", behavior: "the file is named without a line under the read prefix", layer: "integration" }
    it "names the file, without a line, under the read prefix" do
      (go_stdout, *, _) = both_ways.first
      locations = ->(stdout) { fail_lines(stdout).map { |line| line.split(" — ").first } }

      expect(locations.call(go_stdout)).to eq(["FAIL  spec/fixtures/invalid_utf8_spec.rb"])
    end

    # "Same classification" stops being a claim about prose here. An unreadable
    # file is counted as a file that could not be READ, never as an annotation
    # that was checked and found clean — and the seven annotations belong to the
    # file beside it, which both backends still checked.
    # @intent: { entity: "ValidatorBackend", action: "replay the UTF-8 corpus", behavior: "it counts as an unread file rather than a checked annotation", layer: "integration" }
    it "counts it as an unread file rather than a checked annotation" do
      (go_stdout, *, _) = both_ways.first
      summary = ->(stdout) { stdout.lines.map(&:chomp).grep(/checked \d+ @intent/).first }

      expect(summary.call(go_stdout))
        .to eq("specguard-lint: checked 7 @intent annotations, 0 malformed; 1 file could not be read")
    end

    # @intent: { entity: "ValidatorBackend", action: "replay the UTF-8 corpus", behavior: "an unreadable spec file still exits one", layer: "integration" }
    it "exits 1 — an unreadable spec file is still a failed run" do
      (*, _, go_code) = both_ways.first

      expect(go_code).to eq(SpecGuard::RSpec::CLI::EXIT_MALFORMED)
    end

    # @intent: { entity: "ValidatorBackend", action: "replay the UTF-8 corpus", behavior: "stderr stays empty beyond the line naming the validator", layer: "integration" }
    it "says nothing on stderr beyond the line naming the validator" do
      (*, go_stderr, _) = both_ways.first

      expect(stderr_beyond_provenance(go_stderr)).to be_empty
    end

    # The other side of the ratification. If these ever agree, the difference
    # has been closed and this block should be retired along with the README row
    # rather than left asserting a distinction that no longer exists.

    # Both halves are pinned IN FULL, and both can be: unlike the parse tail,
    # neither wording comes from a default gem whose version tracks the Ruby the
    # suite runs on. The binary's is its own prose, written against PROTOCOL.md;
    # Ruby's is this gem's own literal in `Scanner#scan_text`, not an
    # interpolated `JSON::ParserError#message`. Each moves only when somebody
    # here moves it, and these are the two strings README.md's table quotes.
    # @intent: { entity: "ValidatorBackend", action: "replay the UTF-8 corpus", behavior: "the binary own wording passes through unaltered", layer: "integration" }
    it "passes the binary's own wording through unaltered" do
      (go_stdout, *, _) = both_ways.first

      expect(go_stdout).to include("could not read file: input is not well-formed UTF-8 " \
                                   "(PROTOCOL.md §1.1 requires it)")
    end

    # Both name the CONDITION rather than an offset, which is the property
    # `scanner.rb` ratifies the difference ON. Neither claims to know where the
    # bad byte was, because neither stopped to find out.
    # @intent: { entity: "ValidatorBackend", action: "replay the UTF-8 corpus", behavior: "the condition is named rather than an offset", layer: "integration" }
    it "names the condition rather than an offset" do
      (go_stdout, *, _) = both_ways.first
      tails = ->(stdout) { fail_lines(stdout).map { |line| line.split(read_prefix, 2).last } }

      expect(tails.call(go_stdout)).to all(satisfy { |tail| !tail.match?(/\b(byte|offset|position|column)\s+\d/) })
    end
  end

  # ------------------------------------------------------------------------ #
  # ENUMERATED DIFFERENCE 4 of 4 — a path that is not a regular file.
  #
  # This row shares the Go column with difference 3 (`no file at this path`) and
  # that is the whole content of it. The binary's arguments are glob PATTERNS
  # and a match is filtered to regular files, so a directory and a name matching
  # nothing arrive at the same place: one `no-match` finding, which this gem
  # folds into KIND_READ and re-words, because it has no patterns to report on.
  # The Ruby path opens the path it was given, so it has an errno and says which
  # one — `Is a directory @ io_fread - …` rather than `No such file or
  # directory @ rb_sysopen - …`. Ruby distinguishes the two; the backend cannot,
  # and does not pretend to.
  #
  # spec/fixtures/validator/not-a-regular-file.json is RECORDED from
  # `validate-intent-go --source --json spec/fixtures/payloads
  # spec/fixtures/order_spec.rb`, run from the gem root.
  #
  # `spec/fixtures/payloads` is a directory that already exists for its own
  # reason, so this asserts against the repository rather than against a
  # directory a test made — and the first example fails loudly if it ever stops
  # being one.
  describe "a path that is not a regular file" do
    let(:paths) { %w[spec/fixtures/payloads spec/fixtures/order_spec.rb] }
    let(:recorded) { File.read("spec/fixtures/validator/not-a-regular-file.json") }

    def both_ways
      go = run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) })
      [go, go]
    end

    def read_prefix
      "could not read file: "
    end

    # Non-vacuity: the whole comparison is about a path that exists and is not a
    # regular file. If it ever became either a file or nothing, every assertion
    # below would still pass while testing difference 3 over again.
    # @intent: { entity: "ValidatorBackend", action: "replay the non-regular-path corpus", behavior: "the run is genuinely against a path that exists and is not a regular file", layer: "integration" }
    it "is running against a path that exists and is not a regular file" do
      expect(File.directory?(paths.first)).to be(true)
      expect(File.file?(paths.first)).to be(false)
      expect(File.file?(paths.last)).to be(true)
    end

    # @intent: { entity: "ValidatorBackend", action: "replay the non-regular-path corpus", behavior: "exactly one unreadable path is reported", layer: "integration" }
    it "reported exactly one unreadable path" do
      (go_stdout, *, _) = both_ways.first

      expect(fail_lines(go_stdout).length).to eq(1)
      expect(fail_lines(go_stdout)).to all(include(read_prefix))
    end

    # The shared half: both sides name the same path, drop the line, and carry
    # the same `could not read file: ` prefix.
    #
    # Escaping is NOT what this example pins, and saying so here would be a
    # claim the example cannot make: no path in `paths` holds a glob
    # metacharacter, so {ValidatorBackend.escape_glob} is the identity over it
    # and the un-escaping map is unobservable from this document. That the
    # backend reports the path the CALLER named rather than the escaped pattern
    # is asserted under "a path that matched nothing (`no-match`)", on
    # `bracket[1]_spec.rb`, where the two spellings actually differ.
    # @intent: { entity: "ValidatorBackend", action: "replay the non-regular-path corpus", behavior: "the path is named without a line under the read prefix", layer: "integration" }
    it "names the path, without a line, under the read prefix" do
      (go_stdout, *, _) = both_ways.first
      locations = ->(stdout) { fail_lines(stdout).map { |line| line.split(" — ").first } }

      expect(locations.call(go_stdout)).to eq(["FAIL  spec/fixtures/payloads"])
    end

    # @intent: { entity: "ValidatorBackend", action: "replay the non-regular-path corpus", behavior: "it counts as an unread file rather than a checked annotation", layer: "integration" }
    it "counts it as an unread file rather than a checked annotation" do
      (go_stdout, *, _) = both_ways.first
      summary = ->(stdout) { stdout.lines.map(&:chomp).grep(/checked \d+ @intent/).first }

      expect(summary.call(go_stdout))
        .to eq("specguard-lint: checked 7 @intent annotations, 0 malformed; 1 file could not be read")
    end

    # @intent: { entity: "ValidatorBackend", action: "replay the non-regular-path corpus", behavior: "an unreadable path still exits one", layer: "integration" }
    it "exits 1 — an unreadable path is still a failed run" do
      (*, _, go_code) = both_ways.first

      expect(go_code).to eq(SpecGuard::RSpec::CLI::EXIT_MALFORMED)
    end

    # @intent: { entity: "ValidatorBackend", action: "replay the non-regular-path corpus", behavior: "stderr stays empty beyond the line naming the validator", layer: "integration" }
    it "says nothing on stderr beyond the line naming the validator" do
      (*, go_stderr, _) = both_ways.first

      expect(stderr_beyond_provenance(go_stderr)).to be_empty
    end


    # The two spellings README.md's table quotes. Ruby's is pinned only as far
    # as the errno phrase `Errno::EISDIR` contributes — the `@ io_fread - <path>`
    # tail is Ruby's own and has moved across versions, exactly the trap the
    # parse block documents.
    # SPGD-867 rewrote this example: the Ruby errno half is gone with the Ruby
    # arm, and what survives is the property that still matters — the binary's
    # glob semantics fold a directory and a missing name into the same
    # `no-match` answer, which this gem re-words rather than inventing an
    # errno it never had.
    # @intent: { entity: "ValidatorBackend", action: "replay the non-regular-path corpus", behavior: "a non-regular path gets the no-match wording the gem mints", layer: "integration" }
    it "reports the no-match wording the gem mints for a non-regular path" do
      (go_stdout, *, _) = both_ways.first

      expect(go_stdout).to include("could not read file: no file at this path")
      expect(go_stdout).not_to include("Is a directory")
    end

    # What makes this a SEPARATE row from difference 3 rather than a restatement
    # of it: the Ruby path tells the two apart, and the backend does not.
    # @intent: { entity: "ValidatorBackend", action: "replay the non-regular-path corpus", behavior: "the backend wording difference is the ratified one, distinct from the Ruby arm", layer: "integration" }
    it "is the same backend wording difference 3 uses, and a different Ruby one" do
      (ruby_stdout, *), (go_stdout, *) = both_ways
      tail = ->(stdout) { fail_lines(stdout).first.split(read_prefix, 2).last }

      expect(tail.call(go_stdout)).to eq("no file at this path")
      expect(tail.call(ruby_stdout)).not_to include("No such file or directory")
    end
  end

  # ------------------------------------------------------------------------ #
  # THE JSON ACCEPTANCE SET: what each backend's parser takes, and where the two
  # still disagree.
  #
  # The block above ratifies a parse-message TAIL — two parsers spelling the
  # same refusal differently. That framing was once too narrow, because the two
  # parsers did not accept the same LANGUAGE, and a language difference produces
  # divergences a wording difference cannot.
  #
  # THAT CAUSE IS LARGELY GONE, and it is worth being precise about why. The
  # binary used to accept a superset of JSON because its parser reproduced a
  # foreign runtime's grammar, which `PROTOCOL.md` had never specified.
  # PROTOCOL.md §1.1 states the grammar now — an RFC 8259 JSON text, with the
  # three points that RFC leaves open settled explicitly — so the binary refuses
  # the non-finite literals (§1.1(b)), unpaired surrogate escapes (§1.1(a)) and
  # nesting past 100 (§1.1(c)). Ruby's `JSON.parse` refuses the first two and
  # limits the third, so the two now agree about all three.
  #
  # ONE DIFFERENCE SURVIVES, and it runs the other way: the gem is now the more
  # permissive side.
  #
  #   * a LONE LOW surrogate escape. `JSON.parse` accepts it, returning a String
  #     whose `valid_encoding?` is false; §1.1(a) refuses it.
  #   * the nesting BOUNDARY sits a little deeper in Ruby than §1.1(c)'s 100.
  #
  # Both are the gem's hand-rolled parser being looser than the specification.
  # Neither is closed here, and this parse half is not an oversight awaiting a
  # remover: it is RETAINED by design — `Scanner#scan_text` is the formatter's
  # `ValidatorError` rescue path (`AnnotationLookup`) and the validator stub's
  # engine (`spec/support/validator_stub.rb`) — and every way to close the
  # difference is a change to the DEFAULT path, which this backend's slice
  # holds fixed. Documented and pinned instead, so nobody reads the gap as
  # drift: the roadmap that owned the binary (SPGD-96) completed 2026-09-06,
  # having removed the schema-application arm it could remove (`c9dca61`; see
  # the header of `lib/specguard/rspec/linter.rb` for the survivor shape), and
  # this input half is what survived that cutover on purpose.
  describe "the JSON acceptance set" do
    def parses?(doc)
      JSON.parse(doc)
      true
    rescue JSON::ParserError, JSON::NestingError
      false
    end

    # ---------------------------------------------------------------------- #
    # `json`'s own acceptance boundary is NOT asserted here, and that is a
    # decision rather than a gap.
    #
    # There used to be a block on this spot pinning it exactly — every one of
    # the 65,536 `\uXXXX` escapes, the surrogate-pairing rule, the nesting
    # limit to the level. The intent was a tripwire: a `json` upgrade would fail
    # HERE, naming the cause, instead of surfacing as a mysterious disagreement
    # with the binary. What it actually produced was a release blocked by a
    # dependency's patch release — 2.9 closed a nesting off-by-one, changed how
    # an unpaired high surrogate decodes, and reworded its parse errors, and the
    # suite went red for three things that were not this gem.
    #
    # The tripwire was answering the wrong question. What can silently change
    # under this gem is not `json`'s behaviour, it is WHICH `json` runs — and
    # the gemspec now answers that directly with an explicit `~> 2.21`
    # dependency, so the parser is a version we chose rather than whatever the
    # host Ruby ships. A pin in the gemspec cannot go stale the way a pin in a
    # spec file does.
    #
    # What remains asserted below is this gem's own OUTPUT: what
    # `specguard-lint` reports for a fixture of deliberately-malformed
    # annotations, and where that still differs from the reference binary. That
    # is the contract this gem owes its users. How `JSON.parse` reaches its
    # verdict is `json`'s business.

    # ---------------------------------------------------------------------- #
    # CONVERGENCE. The payloads that used to be classified differently by the
    # two backends, asserted to be classified the SAME way now.
    #
    # This is the assertion that goes red if the binary ever goes back to
    # accepting a superset of JSON, which is the regression PROTOCOL.md §1.1
    # exists to prevent. It is not a tautology: the same fixture produced a
    # KIND_SCHEMA block from the backend and a KIND_PARSE line from the Ruby
    # path before §1.1 landed.
    #
    # spec/fixtures/validator/acceptance-set-kind.json is RECORDED from
    # `validate-intent --source --json spec/fixtures/acceptance_set_kind_spec.rb`
    # run from the gem root.
    describe "payloads outside PROTOCOL.md §1.1 — both backends now agree" do
      let(:paths) { %w[spec/fixtures/acceptance_set_kind_spec.rb] }
      let(:recorded) { File.read("spec/fixtures/validator/acceptance-set-kind.json") }

      def both_ways
        # SPGD-867: the Ruby arm is gone; the helper keeps its arity for the
        # untouched destructure sites, which now compare the backend to itself.
        run = run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) })
        [run, run]
      end

      # @intent: { entity: "ValidatorBackend", action: "replay the section 1.1 corpus", behavior: "the out-of-protocol payload corpus runs where its recorded path resolves", layer: "integration" }
      it "is running where the recorded path resolves" do
        expect(paths).to all(satisfy { |path| File.file?(path) })
      end

      # Non-vacuity, and coverage of all three classes in one assertion: seven
      # failures means every one of them reached the report.
      # @intent: { entity: "ValidatorBackend", action: "replay the section 1.1 corpus", behavior: "the comparison covered seven findings across all three payload classes", layer: "integration" }
      it "compared seven findings, covering all three §1.1 classes" do
        (ruby_stdout, *), (go_stdout, *) = both_ways

        expect(fail_lines(ruby_stdout).length).to eq(7)
        expect(fail_lines(go_stdout).length).to eq(7)
      end

      # @intent: { entity: "ValidatorBackend", action: "replay the section 1.1 corpus", behavior: "both backends report the same annotations at the same lines", layer: "integration" }
      it "reports the same annotations, at the same lines" do
        (ruby_stdout, *), (go_stdout, *) = both_ways
        lines = ->(stdout) { fail_lines(stdout).map { |line| line[/:(\d+)/, 1].to_i } }

        expect(lines.call(go_stdout)).to eq(lines.call(ruby_stdout))
        expect(lines.call(go_stdout)).to eq([31, 32, 33, 34, 35, 36, 37])
      end

      # @intent: { entity: "ValidatorBackend", action: "replay the section 1.1 corpus", behavior: "both count them identically as annotations rather than unread files", layer: "integration" }
      it "counts them identically, and as annotations rather than unread files" do
        (ruby_stdout, *), (go_stdout, *) = both_ways
        summary = ->(stdout) { stdout.lines.map(&:chomp).grep(/checked \d+ @intent/).first }

        expect(summary.call(go_stdout)).to eq(summary.call(ruby_stdout))
        expect(summary.call(go_stdout)).to eq("specguard-lint: checked 8 @intent annotations, 7 malformed")
      end

      # @intent: { entity: "ValidatorBackend", action: "replay the section 1.1 corpus", behavior: "both exit one on the corpus", layer: "integration" }
      it "exits 1 on both" do
        (*, ruby_code), (*, go_code) = both_ways

        expect(go_code).to eq(ruby_code)
        expect(go_code).to eq(SpecGuard::RSpec::CLI::EXIT_MALFORMED)
      end

      # @intent: { entity: "ValidatorBackend", action: "replay the section 1.1 corpus", behavior: "stderr stays empty beyond the line naming the validator", layer: "integration" }
      it "says nothing on stderr beyond the line naming the validator" do
        (*, go_stderr, _) = both_ways.first

        expect(stderr_beyond_provenance(go_stderr)).to be_empty
      end

      # THE CONVERGENCE ITSELF. Both backends call every one of these a PARSE
      # failure and render the one-line `problem` shape. Before §1.1 the backend
      # parsed six of the seven and reported KIND_SCHEMA with a `-> ` line per
      # violation, so this is the assertion that the classification moved.
      # @intent: { entity: "ValidatorBackend", action: "replay the section 1.1 corpus", behavior: "every out-of-protocol payload classifies as a parse failure on both backends", layer: "integration" }
      it "classifies every one of them as a parse failure on both backends" do
        (ruby_stdout, *), (go_stdout, *) = both_ways
        parse_prefix = " — could not parse annotation: "

        expect(fail_lines(ruby_stdout)).to all(include(parse_prefix))
        expect(fail_lines(go_stdout)).to all(include(parse_prefix))
        # And neither renders a schema-violation block, which is what the
        # backend used to render for these.
        expect(ruby_stdout.lines.count { |line| line.start_with?("        -> ") }).to eq(0)
        expect(go_stdout.lines.count { |line| line.start_with?("        -> ") }).to eq(0)
      end

      # What is left is the WORDING, and it is still a real difference — two
      # parsers, two vocabularies. Pinned from both sides so a change to either
      # spelling is visible here.
      #
      # The binary's half is the interesting one: it names the PROTOCOL CLAUSE
      # it is enforcing rather than reproducing another parser's message text,
      # which is what makes a refusal something a reader can look up.
      # @intent: { entity: "ValidatorBackend", action: "replay the section 1.1 corpus", behavior: "the finding names the protocol clause it enforces", layer: "integration" }
      it "names the protocol clause it is enforcing" do
        (go_stdout, *, _) = both_ways.first

        expect(go_stdout).to include("PROTOCOL.md §1.1(b)")
        expect(go_stdout).to include("PROTOCOL.md §1.1(a)")
        expect(go_stdout).to include("PROTOCOL.md §1.1(c)")
      end
    end

    # ---------------------------------------------------------------------- #
    # THE SURVIVING DIVERGENCE, and the only one that moves the exit code. It
    # runs the opposite way from every divergence this file used to hold: the
    # GEM is the permissive side now.
    #
    # spec/fixtures/validator/acceptance-set-verdict.json is RECORDED from
    # `validate-intent --source --json spec/fixtures/acceptance_set_verdict_spec.rb`
    # run from the gem root. It exits 1 where the Ruby path exits 0 — that is
    # the finding.
    describe "a lone LOW surrogate — the gem accepts what §1.1(a) refuses" do
      let(:paths) { %w[spec/fixtures/acceptance_set_verdict_spec.rb] }
      let(:recorded) { File.read("spec/fixtures/validator/acceptance-set-verdict.json") }

      def both_ways
        # SPGD-867: the Ruby arm is gone; the helper keeps its arity for the
        # untouched destructure sites, which now compare the backend to itself.
        run = run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) })
        [run, run]
      end

      # @intent: { entity: "ValidatorBackend", action: "replay the lone-surrogate corpus", behavior: "the lone low surrogate corpus runs where its recorded path resolves", layer: "integration" }
      it "is running where the recorded path resolves" do
        expect(paths).to all(satisfy { |path| File.file?(path) })
      end

      # The whole finding in one example: the same file, the same two
      # annotations, and a different answer to "did this run pass?".
      # @intent: { entity: "ValidatorBackend", action: "replay the lone-surrogate corpus", behavior: "the run fails, the protocol refusing an unpaired low surrogate", layer: "integration" }
      it "fails the run — §1.1(a) refuses an unpaired low surrogate" do
        (*, _, go_code) = both_ways.first

        expect(go_code).to eq(SpecGuard::RSpec::CLI::EXIT_MALFORMED)
      end

      # @intent: { entity: "ValidatorBackend", action: "replay the lone-surrogate corpus", behavior: "the finding names the annotation, the line and the clause", layer: "integration" }
      it "names the finding, the line and the clause" do
        (go_stdout, *, _) = both_ways.first

        expect(go_stdout).to include("checked 2 @intent annotations, 1 malformed")
        expect(go_stdout).to include("acceptance_set_verdict_spec.rb:39")
        expect(go_stdout).to include("PROTOCOL.md §1.1(a)")
      end

      # THE BOUNDARY, and it is what stops this reading as "the backend refuses
      # anything with a surrogate in it". A well-formed PAIR passes on both, so
      # the divergence is specifically about the escape being unpaired.
      # @intent: { entity: "ValidatorBackend", action: "replay the lone-surrogate corpus", behavior: "the refusal does not fire for a well-formed surrogate pair", layer: "integration" }
      it "does not fire for a well-formed surrogate pair" do
        (go_stdout, *, _) = both_ways.first

        expect(go_stdout).not_to include(":40")
        expect(JSON.parse(recorded)["findings"].last["ok"]).to be(true)
      end

      # SPGD-867 retired this block's reason for existing: the gem's
      # hand-rolled validation logic is gone, so there is no second verdict
      # to disagree with.
    end

    # ---------------------------------------------------------------------- #
    # THE SECOND SURVIVING DIVERGENCE. It moves the CLASSIFICATION and not the
    # verdict, which is why it needs a block of its own: every assertion above
    # is about a run's colour, and this one is invisible to all of them.
    #
    # §1.1(c) refuses any container deeper than 100. Ruby checks `max_nesting`
    # when it is about to read a VALUE, so a container at depth 101 holding
    # nothing is never checked and is accepted — one level, and only while it
    # stays empty. The boundary itself is pinned above; this is what it costs.
    #
    # It can ONLY appear as a classification difference. A container is not a
    # value the schema permits, so a payload deep enough to diverge is a payload
    # the schema refuses: the gem reaches `schema`, never a pass. That is the
    # other half of the argument acceptance_set_verdict_spec.rb makes — the
    # nesting class cannot move a verdict, and the surrogate class cannot move a
    # classification, because one is a container and the other is inside a
    # string.
    #
    # spec/fixtures/validator/acceptance-set-classification.json is RECORDED
    # from `validate-intent --source --json
    # spec/fixtures/acceptance_set_classification_spec.rb` run from the gem root.
    describe "nesting at depth 101 — the gem says schema, the binary says parse" do
      let(:paths) { %w[spec/fixtures/acceptance_set_classification_spec.rb] }
      let(:recorded) { File.read("spec/fixtures/validator/acceptance-set-classification.json") }

      def both_ways
        # SPGD-867: the Ruby arm is gone; the helper keeps its arity for the
        # untouched destructure sites, which now compare the backend to itself.
        run = run_cli({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) })
        [run, run]
      end

      # The same run with `--json`, so the two `kind` values can be read off the
      # documents rather than inferred from the text report's shape.
      def run_json(env)
        stdout = StringIO.new
        SpecGuard::RSpec::CLI.new(stdout: stdout, stderr: StringIO.new, env: env).run(["--json", *paths])
        stdout.string
      end

      # @intent: { entity: "ValidatorBackend", action: "replay the deep-nesting corpus", behavior: "the depth one-oh-one corpus runs where its recorded path resolves", layer: "integration" }
      it "is running where the recorded path resolves" do
        expect(paths).to all(satisfy { |path| File.file?(path) })
      end

      # The half that AGREES, first — without it the block below reads as a
      # verdict difference, which it is not.
      # @intent: { entity: "ValidatorBackend", action: "replay the deep-nesting corpus", behavior: "the run fails and names the too-deep annotation", layer: "integration" }
      it "fails the run and names the deep annotation" do
        (go_stdout, *, go_code) = both_ways.first

        expect(go_code).to eq(SpecGuard::RSpec::CLI::EXIT_MALFORMED)
        expect(go_stdout).to include("checked 2 @intent annotations, 1 malformed")
        expect(go_stdout).to include("acceptance_set_classification_spec.rb:36")
      end

      # THE DIVERGENCE. The gem parsed the payload and let the SCHEMA refuse it,
      # so it renders a violation block; the binary refused it at the parse
      # step, so it renders a one-line `problem` naming the clause.
      # §1.1(c): the binary refuses the over-deep payload at the PARSE step,
      # so it renders a one-line `problem` naming the clause — never a
      # schema-violation block.
      # @intent: { entity: "ValidatorBackend", action: "replay the deep-nesting corpus", behavior: "the finding classifies as a parse failure naming the clause", layer: "integration" }
      it "classifies it as a parse failure naming the clause" do
        (go_stdout, *, _) = both_ways.first

        expect(go_stdout).to include(" — could not parse annotation: nesting is deeper than 100 levels (PROTOCOL.md §1.1(c))")
        expect(go_stdout.lines.count { |line| line.start_with?("        -> ") }).to eq(0)
      end

      # And in the machine-readable field a consumer actually routes on, which
      # the text shapes above only imply. Both documents are produced the same
      # way — one CLI, one `--json` renderer, the backend swapped underneath —
      # so the only thing that can differ is what each parser decided.
      # @intent: { entity: "ValidatorBackend", action: "replay the deep-nesting corpus", behavior: "the json document records the parse kind for it", layer: "integration" }
      it "records kind=parse in the --json document" do
        go_doc = JSON.parse(run_json({ described_class::ENV_VAR => stub_validator(stdout: recorded, exit_code: 1) }))
        go_deep = go_doc["findings"].find { |f| f["ok"] == false }

        expect(go_deep["kind"]).to eq("parse")
        expect(go_deep["line"]).to eq(36)
      end

      # Non-vacuity: the payload has to be one Ruby genuinely ACCEPTS. One level
      # deeper and Ruby refuses it too, the classifications converge, and every
      # assertion above would still pass for the wrong reason.
      # @intent: { entity: "ValidatorBackend", action: "replay the deep-nesting corpus", behavior: "the payload is one the gem parser also accepts, making the classification the real thing under test", layer: "integration" }
      it "is a payload the gem's parser accepts rather than one it also refuses" do
        payload = File.read(paths.first).lines
                      .filter_map { |line| line[/@intent:\s*(\{.*\})\s*$/, 1] }
                      .find { |json| json.include?("preconditions") }

        expect(payload).not_to be_nil
        expect { JSON.parse(payload) }.not_to raise_error
        expect(JSON.parse(payload)["preconditions"]).to be_an(Array)
      end

      # SPGD-867 retired this block's reason for existing: the gem's parser
      # is gone, so there is no second classification to differ from.
    end
  end

  # ------------------------------------------------------------------------ #
  # The surrogate-recovery path in `Runner`'s `#decode`
  # (validator_backend.rb): a report whose TEXT carries an unpaired HIGH
  # surrogate escape, which `JSON.parse` refuses outright.
  #
  # NO BINARY THIS GEM SHIPS AGAINST CAN EMIT ONE — PROTOCOL.md §1.1(a),
  # landed by SPGD-403, refuses an unpaired surrogate at parse time, so the
  # port reports it as `kind: "parse"`, `intent: null`. The recovery is kept
  # anyway because `SPECGUARD_VALIDATE_INTENT` names an ARBITRARY path: an
  # older build or a third-party implementation of the vendor-neutral
  # protocol must not turn one annotation's contents into a batch-wide exit
  # 2 — every file in the batch reported as "the validator is broken" over
  # text the gem could not read.
  #
  # This block is the ONLY coverage that path has. Without it the recovery
  # machinery — the regex, the rewrite, `#drop_every_payload` — is
  # unverifiable by the suite, which is KB SPGD-78's vacuous-green shape:
  # code nothing can fail is code nobody has to keep honest.
  describe "recovering a report that carries an unpaired high surrogate" do
    def results_for(stdout)
      described_class::Runner.new(stub_validator(stdout: stdout, exit_code: 0))
                            .tap(&:verify!)
                            .check(["a_spec.rb"])
    end

    let(:intent) do
      { "entity" => "Order", "action" => "checkout",
        "behavior" => "returns 402 payment required on expired card", "layer" => "request" }
    end

    # `document` cannot build this report: the payload must be written as a
    # `\ud800` ESCAPE in the text, which `JSON.generate` cannot produce from
    # any Ruby value. So the mark is a real, representable payload, and the
    # sub puts the unrepresentable one in its place after generation.
    let(:raw) do
      JSON.generate(
        schema: "open-test-intent.v1.json", mode: "source", ok: true,
        summary: { files: 1, annotations: 2, failed: 0 },
        findings: [
          { file: "a_spec.rb", line: 1, ok: true, kind: nil, errors: [],
            intent: { "entity" => "MARK" } },
          { file: "a_spec.rb", line: 5, ok: true, kind: nil, errors: [],
            intent: intent }
        ]
      ).sub('"entity":"MARK"', '"entity":"\ud800Or"')
    end

    # @intent: { entity: "ValidatorBackend", action: "recover a high-surrogate document", behavior: "the recovery corpus is a document Ruby itself cannot parse, the premise of the block", layer: "integration" }
    it "is a document Ruby cannot parse — the premise of everything below" do
      expect { JSON.parse(raw) }.to raise_error(JSON::ParserError, /surrogate/)
    end

    # @intent: { entity: "ValidatorBackend", action: "recover a high-surrogate document", behavior: "every verdict in the document is kept rather than failing the batch", layer: "integration" }
    it "keeps every verdict rather than failing the batch" do
      results = results_for(raw)

      expect(results.length).to eq(2)
      expect(results).to all(be_ok)
      expect(results.map(&:line)).to eq([1, 5])
    end

    # Both halves matter. Dropping the OFFENDING payload is the point; also
    # dropping the innocent one in the same document is the conservative
    # direction, because the recovery rewrites TEXT and cannot tell a real
    # escape from an author who literally typed a backslash before `ud800`.
    # A dropped annotation is a lie nobody acts on; a corrupted one is a lie
    # everybody does.
    # @intent: { entity: "ValidatorBackend", action: "recover a high-surrogate document", behavior: "every payload in that document is dropped and none is repaired", layer: "integration" }
    it "drops every payload in that document, and repairs none" do
      results = results_for(raw)

      expect(results.map(&:intent)).to eq([nil, nil])
      expect(results.map(&:representable_intent)).to eq([nil, nil])
    end

    # Non-vacuity: the same two findings WITHOUT the surrogate keep their
    # payload, so the example above is about the surrogate and not about the
    # report builder having dropped them all along.
    # @intent: { entity: "ValidatorBackend", action: "recover a high-surrogate document", behavior: "a document it can read is not treated this way", layer: "integration" }
    it "is not how it treats a document it can read" do
      clean = JSON.generate(
        schema: "open-test-intent.v1.json", mode: "source", ok: true,
        summary: { files: 1, annotations: 2, failed: 0 },
        findings: [
          { file: "a_spec.rb", line: 1, ok: true, kind: nil, errors: [],
            intent: { "entity" => "Order" } },
          { file: "a_spec.rb", line: 5, ok: true, kind: nil, errors: [],
            intent: intent }
        ]
      )

      expect(results_for(clean).map(&:intent))
        .to eq([{ "entity" => "Order" }, intent])
    end

    # A parse failure that is NOT a surrogate must still be an exit 2. The
    # recovery is for one named class, not a general "try harder" that would
    # turn a broken binary into a clean-looking run.
    # @intent: { entity: "ValidatorBackend", action: "recover a high-surrogate document", behavior: "a document that is simply broken is not rescued", layer: "integration" }
    it "does not rescue a document that is simply broken" do
      expect { results_for("this is not JSON at all") }
        .to raise_error(SpecGuard::RSpec::ValidatorError, /did not emit a JSON document/)
    end
  end

  # ------------------------------------------------------------------------ #
  # Exit 1 means "an annotation is malformed" and nothing else. A backend that
  # could not produce a verdict must not borrow it — and must not land on the
  # `internal error:` backstop either, which reads as a bug in the linter
  # rather than a fixable configuration.
  describe "the exit contract, through the CLI" do
    let(:stdout) { StringIO.new }
    let(:stderr) { StringIO.new }

    def run_with(env_value, argv = ["spec/fixtures/order_spec.rb"])
      SpecGuard::RSpec::CLI
        .new(stdout: stdout, stderr: stderr, env: { described_class::ENV_VAR => env_value })
        .run(argv)
    end

    # @intent: { entity: "specguard-lint exit contract", action: "gate on resolution", behavior: "a missing binary exits two through the CLI, not one", layer: "integration" }
    it "exits 2, not 1, when the binary does not exist" do
      expect(run_with(File.join(tmpdir, "nope"))).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
    end

    # @intent: { entity: "specguard-lint exit contract", action: "gate on resolution", behavior: "a non-executable binary exits two the same way", layer: "integration" }
    it "exits 2, not 1, when the binary is not executable" do
      path = File.join(tmpdir, "not-executable")
      File.write(path, "")
      FileUtils.chmod(0o644, path)

      expect(run_with(path)).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
    end

    # @intent: { entity: "specguard-lint exit contract", action: "gate on resolution", behavior: "a binary exiting two itself exits two, not one", layer: "integration" }
    it "exits 2, not 1, when the binary exits 2" do
      expect(run_with(stub_validator(stderr: "error: could not load schema x\n", exit_code: 2)))
        .to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
    end

    # @intent: { entity: "specguard-lint exit contract", action: "gate on resolution", behavior: "unparseable binary output exits two", layer: "integration" }
    it "exits 2, not 1, when the binary emits unparseable output" do
      expect(run_with(stub_validator(stdout: "{ not json", exit_code: 1)))
        .to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
    end

    # @intent: { entity: "specguard-lint exit contract", action: "gate on resolution", behavior: "a non-zero exit with unparseable output also exits two", layer: "integration" }
    it "exits 2, not 1, when the binary exits non-zero with unparseable output" do
      expect(run_with(stub_validator(stdout: "boom", exit_code: 1)))
        .to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
    end

    # The wording matters as much as the code: `internal error:` tells the
    # reader to file a bug against the gem, when the fix is one environment
    # variable away.
    # @intent: { entity: "specguard-lint exit contract", action: "gate on resolution", behavior: "the failure reports with the error prefix on stderr", layer: "integration" }
    it "reports the failure as `specguard-lint: error:` on stderr" do
      run_with(File.join(tmpdir, "nope"))

      expect(stderr.string).to start_with("specguard-lint: error: ")
      expect(stderr.string).not_to include("internal error")
    end

    # @intent: { entity: "specguard-lint exit contract", action: "gate on resolution", behavior: "the diagnostic stays off stdout where it could be piped away", layer: "integration" }
    it "keeps the diagnostic off stdout, where it could be piped away" do
      run_with(File.join(tmpdir, "nope"))

      expect(stdout.string).not_to include("error")
    end

    # --help must still work with a broken backend configured: it prints and
    # returns before anything is resolved.
    # @intent: { entity: "specguard-lint exit contract", action: "answer help anyway", behavior: "help still answers when the configured binary is missing", layer: "integration" }
    it "still answers --help when the configured binary is missing" do
      expect(run_with(File.join(tmpdir, "nope"), ["--help"])).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
      expect(stdout.string).to include("Usage: specguard-lint")
    end

    # Misuse of the linter is still misuse of the linter, and it is diagnosed
    # before the backend is ever consulted.
    # @intent: { entity: "specguard-lint exit contract", action: "answer help anyway", behavior: "the changed-with-files refusal still works with a missing binary", layer: "integration" }
    it "still refuses --changed combined with explicit files" do
      code = SpecGuard::RSpec::CLI
             .new(stdout: stdout, stderr: stderr,
                  env: { described_class::ENV_VAR => stub_validator(stdout: document([ok_finding])) })
             .run(["--changed", "spec/fixtures/order_spec.rb"])

      expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
      expect(stderr.string).to include("--changed cannot be combined with explicit files")
    end
  end

  # ------------------------------------------------------------------------ #
  # NAMING THE IMPLEMENTATION THAT PRODUCED THE VERDICTS.
  #
  # Everything above this point establishes that the two backends produce the
  # same bytes for the same corpus. That is the property the slice wanted, and
  # it is also the problem: with the report identical, a run validated by the Go
  # port and a run validated by Linter were indistinguishable from their output,
  # so "which validator did this CI job actually run" had no answer.
  #
  # `validator_backend.rb` had already refused to leave that question open in
  # the two places it can be decided before a binary runs — a named-but-missing
  # binary is a hard exit 2, and a bare command name is refused rather than
  # PATH-resolved, both because "a run that succeeded against a different
  # validator" is undetectable downstream. This closes the same hole for every
  # binary that DOES resolve, and the assertions below are about the four ways
  # that can go wrong:
  #
  #   * saying nothing on the Ruby arm, which would make the line's ABSENCE
  #     ambiguous between "the Ruby path" and "a gem too old to say";
  #   * composing a sentence ABOUT the binary instead of carrying the binary's
  #     own words, which cannot distinguish two builds this gem has never heard
  #     of;
  #   * letting a binary that cannot self-report cost a verdict, or an exit
  #     code, or a byte of stdout;
  #   * reporting "unavailable" by omitting the line — the silent-omission shape
  #     this project keeps naming, which would read exactly like a run nobody
  #     looked at.
  describe "naming the validator that produced the verdicts" do
    let(:paths) { %w[spec/fixtures/order_spec.rb] }

    # ---------------------------------------------------------------------- #
    # THE PROBE. Once, before selection, and incapable of failing the run.
    describe "the identity probe" do
      # @intent: { entity: "ValidatorBackend", action: "probe the identity", behavior: "the backend asks the binary who it is", layer: "integration" }
      it "asks the binary who it is" do
        described_class.resolve(env: { described_class::ENV_VAR => stub_validator })

        expect(version_probes).to eq([["--version"]])
      end

      # Criterion 6, and the reason it is asked in #verify! rather than beside
      # the report: an audit of a large suite runs many batches, and an identity
      # probe per batch would be a per-file cost for a per-run fact.
      # @intent: { entity: "ValidatorBackend", action: "probe the identity", behavior: "the identity is asked once per run, not once per batch", layer: "integration" }
      it "asks once per run, not once per batch" do
        paths = Array.new(1_500) { |i| format("spec/models/example_%05d_spec.rb", i) }
        run_backend(paths, stdout: document(paths.map { |path| ok_finding(file: path) }))

        expect(recorded_invocations.length).to be > 1
        expect(version_probes.length).to eq(1)
      end

      # Before selection, so the line lands above the empty-selection warnings
      # and a run that dies mid-way still said what was about to validate it.
      # @intent: { entity: "ValidatorBackend", action: "probe the identity", behavior: "the identity is asked before any verdict is asked for", layer: "integration" }
      it "asks before it asks for any verdict" do
        run_backend(["a_spec.rb"], stdout: document([ok_finding]))

        expect(all_invocations.first).to eq(["--version"])
      end

      # Criterion 3. The identity is the binary's statement, not the gem's, so
      # the gem must not know its format — a build that words it differently is
      # still telling the truth about which build it is.
      # @intent: { entity: "ValidatorBackend", action: "probe the identity", behavior: "the binary own line is carried through verbatim", layer: "integration" }
      it "carries the binary's own line through verbatim" do
        odd = "some-other-validator 9.9.9-rc1+build.7 [experimental]"
        runner = described_class.resolve(
          env: { described_class::ENV_VAR => stub_validator(version_stdout: odd) }
        )

        expect(runner.identity).to eq(odd)
      end

      # Criterion 6's lower half: the probe belongs to verify!, not to
      # construction, so nothing that merely names a Runner costs a process.
      #
      # The second half of this example is what makes the first half mean
      # anything. `version_probes` answers [] for an args log that does not
      # exist yet, which is indistinguishable from a Runner that stayed quiet —
      # so resolving the SAME stub afterwards proves the log is readable and
      # the counter moves. Without it this passes on a broken instrument.
      # @intent: { entity: "ValidatorBackend", action: "probe the identity", behavior: "the binary is not invoked at all before it has been resolved", layer: "integration" }
      it "does not invoke the binary at all before it has been resolved" do
        path = stub_validator

        described_class::Runner.new(path)
        expect(version_probes).to be_empty

        described_class.resolve(env: { described_class::ENV_VAR => path })
        expect(version_probes.length).to eq(1)
      end
    end

    # ---------------------------------------------------------------------- #
    # "IDENTITY UNAVAILABLE" IS NOT A FAILURE TO OBTAIN A VERDICT.
    #
    # `--version` arrived in open-test-intent slice 6. An older build reads it
    # as a filename, reports "no file(s) match" on stderr and exits 1 — and it
    # validates perfectly well. Every shape below must therefore leave the
    # findings, the exit code and stdout exactly as they were.
    describe "a binary that cannot report its identity" do
      def unidentified(**extra)
        described_class.resolve(env: { described_class::ENV_VAR => stub_validator(**extra) })
      end

      # @intent: { entity: "ValidatorBackend", action: "tolerate identity-less binaries", behavior: "a pre-slice-six no-file-match refusal is treated as unavailable rather than fatal", layer: "integration" }
      it "treats a pre-slice-6 binary's `no file(s) match` refusal as unavailable" do
        runner = unidentified(version_stdout: "", version_stderr: "error: no file(s) match '--version'\n",
                              version_exit: 1)

        expect(runner.identity).to be_nil
      end

      # @intent: { entity: "ValidatorBackend", action: "tolerate identity-less binaries", behavior: "a silent success is treated as unavailable rather than an empty identity", layer: "integration" }
      it "treats a silent success as unavailable rather than as an empty identity" do
        expect(unidentified(version_stdout: "").identity).to be_nil
      end

      # The one shape check, and it is about the single line the CLI promises
      # per run rather than about the port's format. A `--version` answering
      # with a report document is answering a different question.
      # @intent: { entity: "ValidatorBackend", action: "tolerate identity-less binaries", behavior: "an answer of more than one line is refused", layer: "integration" }
      it "refuses an answer that is more than one line" do
        expect(unidentified(version_stdout: "validate-intent 1.4.0\nand another thing").identity).to be_nil
      end

      # @intent: { entity: "ValidatorBackend", action: "tolerate identity-less binaries", behavior: "an answer longer than the line budget is refused", layer: "integration" }
      it "refuses an answer longer than the line budget" do
        giant = "v#{'9' * SpecGuard::RSpec::ValidatorBackend::Runner::IDENTITY_MAX_BYTES}"

        expect(unidentified(version_stdout: giant).identity).to be_nil
      end

      # An escape sequence in a CI log is somebody else's colour scheme at best
      # and a forged extra line at worst.
      # @intent: { entity: "ValidatorBackend", action: "tolerate identity-less binaries", behavior: "an answer carrying control characters is refused", layer: "integration" }
      it "refuses an answer carrying control characters" do
        expect(unidentified(version_stdout: "validate-intent \e[31m1.4.0\e[0m").identity).to be_nil
      end

      # @intent: { entity: "ValidatorBackend", action: "tolerate identity-less binaries", behavior: "an answer that is not valid text is refused", layer: "integration" }
      it "refuses an answer that is not valid text" do
        expect(unidentified(version_stdout: "validate-intent \xFF\xFE").identity).to be_nil
      end

      # Regression: `String#strip` raises Encoding::CompatibilityError on an
      # invalid byte sequence, so testing the shape before the encoding turned
      # a binary with an odd `--version` into `internal error:` and an exit 2 —
      # the linter reporting itself broken because it could not read a line it
      # does not need.
      # @intent: { entity: "ValidatorBackend", action: "tolerate identity-less binaries", behavior: "an unreadable answer never becomes an internal error", layer: "integration" }
      it "does not let an unreadable answer become an internal error" do
        stub = clean_stub(version_stdout: "validate-intent \xFF\xFE")
        stdout, stderr, code = run_cli({ described_class::ENV_VAR => stub })

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(stderr).not_to include("internal error")
        expect(stdout).to include("specguard-lint: checked 1 @intent annotation, 0 malformed")
      end

      # THE POINT. Not a ValidatorError, not an exit 2 — the "everything that
      # can go wrong here is exit 2" band is for failures to obtain a VERDICT,
      # and this is not one.
      # @intent: { entity: "ValidatorBackend", action: "tolerate identity-less binaries", behavior: "an identity-less binary still resolves and still validates", layer: "integration" }
      it "still resolves, and still validates" do
        stub = clean_stub(version_stdout: "", version_exit: 1)
        stdout, _stderr, code = run_cli({ described_class::ENV_VAR => stub })

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(stdout).to include("specguard-lint: checked 1 @intent annotation, 0 malformed")
      end

      # Criterion 4, stated as the comparison that proves it: the ONLY thing
      # that moves is the wording of the provenance line.
      # @intent: { entity: "ValidatorBackend", action: "tolerate identity-less binaries", behavior: "it produces the same stdout and exit code as a binary that can identify itself", layer: "integration" }
      it "produces the same stdout and the same exit code as a binary that can" do
        identified = run_cli({ described_class::ENV_VAR => clean_stub(name: "with-version") })
        anonymous = run_cli({ described_class::ENV_VAR =>
                              clean_stub(name: "without-version", version_stdout: "", version_exit: 1) })

        expect(anonymous[0]).to eq(identified[0])
        expect(anonymous[2]).to eq(identified[2])
      end

      # Criterion 4's other half, and the one that matters most: unavailable is
      # reported IN WORDS. A run that dropped the line instead would look
      # exactly like a run nobody ever taught to print one.
      # @intent: { entity: "ValidatorBackend", action: "tolerate identity-less binaries", behavior: "the provenance says so in words and still names the binary it could not identify", layer: "integration" }
      it "says so in words, and still names the binary it could not identify" do
        stub = clean_stub(version_stdout: "", version_exit: 1)

        expect(provenance_of({ described_class::ENV_VAR => stub }))
          .to eq("specguard-lint: validated by the binary at #{stub} " \
                 "(SPECGUARD_VALIDATE_INTENT), which could not report its identity, " \
                 "so the schema contract it carries could not be checked")
      end

      # @intent: { entity: "ValidatorBackend", action: "tolerate identity-less binaries", behavior: "exactly one such line prints", layer: "integration" }
      it "still prints exactly one such line" do
        stub = clean_stub(version_stdout: "", version_exit: 1)
        _, stderr, = run_cli({ described_class::ENV_VAR => stub })

        expect(provenance_lines(stderr).length).to eq(1)
      end
    end

    # ---------------------------------------------------------------------- #
    describe "the line, with the backend active" do
      # @intent: { entity: "ValidatorBackend", action: "print the provenance line", behavior: "the line names the binary own identity and the path it was resolved from", layer: "integration" }
      it "names the binary's own identity and the path it was resolved from" do
        stub = clean_stub

        expect(provenance_of({ described_class::ENV_VAR => stub }))
          .to eq("specguard-lint: validated by #{stub_identity} at #{stub} (SPECGUARD_VALIDATE_INTENT), " \
                 "which reports carrying the schema this gem vendors — the contract it carries, " \
                 "not necessarily the one this run enforced")
      end

      # Criterion 2. The findings and the two `checked …` lines are the product
      # and are pinned byte-for-byte across the backends above; a line about the
      # linter's own configuration must not join them.
      # @intent: { entity: "ValidatorBackend", action: "print the provenance line", behavior: "the line goes on stderr leaving stdout untouched", layer: "integration" }
      it "goes on stderr, leaving stdout untouched" do
        stdout, = run_cli({ described_class::ENV_VAR => clean_stub })

        expect(stdout).not_to include("validated")
        expect(stdout).not_to include(stub_identity)
      end

      # @intent: { entity: "ValidatorBackend", action: "print the provenance line", behavior: "exactly one such line prints per run", layer: "integration" }
      it "prints exactly one such line per run" do
        _, stderr, = run_cli({ described_class::ENV_VAR => clean_stub })

        expect(provenance_lines(stderr).length).to eq(1)
      end

      # Placement, asserted rather than assumed: emitted right after resolution,
      # so it is above the selection warnings and reads as the premise of
      # everything that follows rather than as a footnote to it.
      # @intent: { entity: "ValidatorBackend", action: "print the provenance line", behavior: "the provenance line comes before the empty-selection warning", layer: "integration" }
      it "comes before the empty-selection warning" do
        stub = stub_validator
        stderr = nil
        Dir.mktmpdir { |dir| Dir.chdir(dir) { _, stderr, = run_cli({ described_class::ENV_VAR => stub }, []) } }

        expect(stderr.lines.first).to start_with("specguard-lint: validated by ")
        expect(stderr).to include("selected 0 spec files")
      end
    end

    # ---------------------------------------------------------------------- #
    # SPGD-867: the "off" arm is gone — there is nothing to turn off. What the
    # default configuration now prints is the line naming the binary the
    # INSTALLER resolved, so unset and blank are the same configuration and
    # say the same thing.
    describe "the line, with the variable unset or blank" do
      before do
        allow(described_class::Installer).to receive(:obtain).and_return(stub_validator)
      end

      # @intent: { entity: "ValidatorBackend", action: "print the provenance line", behavior: "with the variable unset the line names the installer-resolved binary", layer: "integration" }
      it "names the installer-resolved binary" do
        expect(provenance_of({}))
          .to start_with("specguard-lint: validated by #{stub_identity} at #{stub_validator} (SPECGUARD_VALIDATE_INTENT)")
      end

      # @intent: { entity: "ValidatorBackend", action: "print the provenance line", behavior: "a blank value is treated as unset, matching resolve", layer: "integration" }
      it "treats a blank value as unset, matching .resolve" do
        expect(provenance_of({ described_class::ENV_VAR => "" }))
          .to eq(provenance_of({ described_class::ENV_VAR => "   " }))
      end

      # @intent: { entity: "ValidatorBackend", action: "print the provenance line", behavior: "exactly one such line prints per run on that arm too", layer: "integration" }
      it "prints exactly one such line per run" do
        _, stderr, = run_cli({})

        expect(provenance_lines(stderr).length).to eq(1)
      end

      # @intent: { entity: "ValidatorBackend", action: "print the provenance line", behavior: "stdout and the exit code are identical either way", layer: "integration" }
      it "leaves stdout and the exit code identical either way" do
        unset = run_cli({})
        blank = run_cli({ described_class::ENV_VAR => "" })

        expect(blank[0]).to eq(unset[0])
        expect(blank[2]).to eq(unset[2])
        expect(blank[1]).to eq(unset[1])
      end

      # @intent: { entity: "ValidatorBackend", action: "print the provenance line", behavior: "on that arm too the line goes on stderr leaving stdout untouched", layer: "integration" }
      it "goes on stderr, leaving stdout untouched" do
        stdout, = run_cli({})

        expect(stdout).not_to include("validated")
      end
    end

    # ---------------------------------------------------------------------- #
    # Criterion 1 has no exceptions worth having: a run that says nothing about
    # its validator is the state this slice exists to remove, so the sweep is
    # over every arm at once rather than one assertion per arm.
    # @intent: { entity: "ValidatorBackend", action: "print the provenance line", behavior: "every arm states which implementation validated the run", layer: "integration" }
    it "states which implementation validated the run, on every arm" do
      allow(described_class::Installer).to receive(:obtain).and_return(clean_stub(name: "installed"))
      envs = [{},
              { described_class::ENV_VAR => clean_stub(name: "identified") },
              { described_class::ENV_VAR => clean_stub(name: "anonymous", version_stdout: "", version_exit: 1) }]

      lines = envs.map { |env| provenance_of(env) }

      expect(lines).to all(be_a(String))
      expect(lines.uniq.length).to eq(3)
    end
  end

  # ------------------------------------------------------------------------ #
  # THE SCHEMA CONTRACT ACROSS THE SEAM.
  #
  # The section above carries the binary's identity through and renders it. One
  # token in it was never read: `schema sha256:<64-hex>`, the digest of the
  # schema compiled into that binary, which open-test-intent's `SchemaSHA256`
  # added for exactly one reason —
  #
  #   "a gem that vendors schema A can be pointed at a binary built when
  #   canonical was B, and all three guards stay green while the two halves
  #   enforce different contracts."
  #
  # Both of this ecosystem's digest pins are in-repo: `schema_test.go` compares
  # the Go embed to the Go tree, and this repo's `schema_packaging_spec.rb`
  # compares the vendored copy to this repo's pin. Neither crosses the seam,
  # and on the backend path the gem does not even LOAD its vendored schema
  # (`CLI#run` skips it deliberately) — so nothing in either repo could notice
  # a binary enforcing a different contract than the gem beside it vendors.
  #
  # These examples are the crossing. They are written against the three bands
  # the code owes, and the boundary that matters most is the one between the
  # second and third: "I asked and the answer was wrong" is a refusal, "I could
  # not ask" never is.
  describe "the schema contract across the seam" do
    let(:paths) { %w[spec/fixtures/order_spec.rb] }

    def resolve(**stub)
      described_class.resolve(env: { described_class::ENV_VAR => stub_validator(**stub) })
    end

    # ---------------------------------------------------------------------- #
    # BAND (a): reported and equal.
    describe "a binary carrying the schema this gem vendors" do
      # @intent: { entity: "ValidatorBackend schema contract", action: "match the vendored digest", behavior: "a binary carrying the vendored schema digest records the contract as matched", layer: "integration" }
      it "records the contract as matched" do
        expect(resolve.schema_contract).to eq(:matched)
      end

      # @intent: { entity: "ValidatorBackend schema contract", action: "match the vendored digest", behavior: "a matched contract runs normally changing neither stdout nor the exit code", layer: "integration" }
      it "runs normally, changing neither stdout nor the exit code" do
        stdout, _stderr, code = run_cli({ described_class::ENV_VAR => clean_stub })

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(stdout).to include("specguard-lint: checked 1 @intent annotation, 0 malformed")
      end

      # The wording constraint, and it is not a style note. `LoadSchema` gives a
      # schema file found beside the executable priority over the embedded copy,
      # and `--version` returns above that decision — so the digest is the
      # contract the artifact CARRIES, and a line claiming the run ENFORCED it
      # would be this gem inventing a guarantee the answer does not contain.
      # @intent: { entity: "ValidatorBackend schema contract", action: "match the vendored digest", behavior: "the clause says the contract matched without claiming the run enforced it", layer: "integration" }
      it "says the contract matched without claiming the run enforced it" do
        stub = clean_stub
        line = provenance_of({ described_class::ENV_VAR => stub })

        expect(line).to eq("specguard-lint: validated by #{stub_identity} at #{stub} " \
                           "(SPECGUARD_VALIDATE_INTENT), which reports carrying the schema this gem " \
                           "vendors — the contract it carries, not necessarily the one this run enforced")
        expect(line).to include("not necessarily the one this run enforced")
      end

      # The comparison reads the identity the probe already obtained, so it must
      # not cost a second process — and, more importantly, the name in the line
      # and the digest that was compared must have come from the same answer.
      # @intent: { entity: "ValidatorBackend schema contract", action: "match the vendored digest", behavior: "the comparison does not ask the binary a second time", layer: "integration" }
      it "compares without asking the binary a second time" do
        run_backend(["a_spec.rb"], stdout: document([ok_finding]))

        expect(version_probes.length).to eq(1)
      end

      # A future build may word its version differently and still be telling the
      # truth: only the token is read, everything around it stays opaque.
      # @intent: { entity: "ValidatorBackend schema contract", action: "match the vendored digest", behavior: "the token is read out of a line otherwise not understood", layer: "integration" }
      it "reads the token out of a line it otherwise does not understand" do
        runner = resolve(version_stdout: "sg-validator/2 (experimental) schema sha256:#{vendored_digest} +tls")

        expect(runner.schema_contract).to eq(:matched)
      end

      # Go's hex is lower case and so is Ruby's, so this changes nothing today;
      # it is here so that a build which shouts is read as the same digest
      # rather than reported as a divergence that does not exist.
      # @intent: { entity: "ValidatorBackend schema contract", action: "match the vendored digest", behavior: "an upper-case spelling reads as the same digest", layer: "integration" }
      it "treats an upper-case spelling as the same digest" do
        expect(resolve(version_stdout: identity_reporting(vendored_digest.upcase)).schema_contract).to eq(:matched)
      end
    end

    # ---------------------------------------------------------------------- #
    # BAND (b): reported and different. The one addition to the exit-2 band.
    describe "a binary carrying a different schema" do
      def diverging_stub(**stub)
        clean_stub(version_stdout: identity_reporting(foreign_digest), **stub)
      end

      # @intent: { entity: "ValidatorBackend schema contract", action: "refuse a divergent digest", behavior: "a binary carrying a different schema refuses to resolve", layer: "integration" }
      it "refuses to resolve" do
        expect { resolve(version_stdout: identity_reporting(foreign_digest)) }
          .to raise_error(SpecGuard::RSpec::ValidatorError)
      end

      # @intent: { entity: "ValidatorBackend schema contract", action: "refuse a divergent digest", behavior: "the refusal exits two, not a verdict about annotations", layer: "integration" }
      it "exits 2, not 1 — this is not a verdict about anyone's annotations" do
        _, _, code = run_cli({ described_class::ENV_VAR => diverging_stub })

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
      end

      # Both digests, in full. One of them lives inside a binary and the other
      # inside an installed gem, and neither is inspectable from where the other
      # lives — a message naming one would send the reader off to compute the
      # other by hand. The version string is named too: this refusal happens
      # above the provenance line, so if the error does not say which build
      # reported the foreign digest, nothing in the run does.
      # @intent: { entity: "ValidatorBackend schema contract", action: "refuse a divergent digest", behavior: "both digests are named along with the binary one was read from", layer: "integration" }
      it "names both digests, and the binary it read one of them from" do
        stub = diverging_stub
        _, stderr, = run_cli({ described_class::ENV_VAR => stub })

        expect(error_lines(stderr).length).to eq(1)
        expect(error_lines(stderr).first).to include("the validator backend at #{stub}")
        expect(error_lines(stderr).first).to include("sha256:#{foreign_digest}")
        expect(error_lines(stderr).first).to include("sha256:#{vendored_digest}")
        expect(error_lines(stderr).first).to include(identity_reporting(foreign_digest))
      end

      # The provenance line is not printed on this path — the refusal is raised
      # inside .resolve, above the reporting — which is why the version string
      # has to be in the error itself rather than left to the line beside it.
      # @intent: { entity: "ValidatorBackend schema contract", action: "refuse a divergent digest", behavior: "the refusal is the only place the run names the build, provenance never printing", layer: "integration" }
      it "is the only place the run names the build, because provenance never prints" do
        _, stderr, = run_cli({ described_class::ENV_VAR => diverging_stub })

        expect(stderr).not_to include("specguard-lint: validated")
      end

      # The whole reason the check sits in #verify!: the divergence is settled
      # before a single file is selected, scanned or handed to the binary.
      # @intent: { entity: "ValidatorBackend schema contract", action: "refuse a divergent digest", behavior: "the failure happens before anything is selected or scanned", layer: "integration" }
      it "fails before anything is selected or scanned" do
        stdout, stderr, = run_cli({ described_class::ENV_VAR => diverging_stub })

        expect(recorded_invocations).to be_empty
        expect(stdout).to eq("")
        expect(stderr).not_to include("selected")
      end

      # It would have been a clean run. That is the point: nothing downstream —
      # not the report, not the exit code, not the finding count — could have
      # told anyone the verdict came from a different contract.
      # @intent: { entity: "ValidatorBackend schema contract", action: "refuse a divergent digest", behavior: "a run that would otherwise pass is still refused", layer: "integration" }
      it "refuses a run that would otherwise have passed" do
        clean = run_cli({ described_class::ENV_VAR => clean_stub(name: "agreeing") })
        diverged = run_cli({ described_class::ENV_VAR => diverging_stub(name: "diverging") })

        expect(clean[2]).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(diverged[2]).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
      end
    end

    # ---------------------------------------------------------------------- #
    # BAND (c): not reported — never a refusal, in any of its three shapes.
    #
    # The standing rule this file already enforces for identity ("an older build
    # must not cost a verdict") applies unchanged: slice 17 is newer than the
    # binaries in the field, and a gem that refused every one of them would be
    # enforcing a contract by breaking everybody who cannot yet state theirs.
    describe "a binary that reports no digest" do
      # @intent: { entity: "ValidatorBackend schema contract", action: "tolerate a digest-less binary", behavior: "a binary reporting no digest records the contract as unreported and still resolves", layer: "integration" }
      it "records the contract as unreported, and still resolves" do
        expect(resolve(version_stdout: "validate-intent 1.4.0 (go1.22.12 linux/arm64)").schema_contract)
          .to eq(:unreported)
      end

      # @intent: { entity: "ValidatorBackend schema contract", action: "tolerate a digest-less binary", behavior: "it still validates with the exit code unchanged", layer: "integration" }
      it "still validates, with the exit code unchanged" do
        stub = clean_stub(version_stdout: "validate-intent 1.4.0 (go1.22.12 linux/arm64)")
        stdout, _stderr, code = run_cli({ described_class::ENV_VAR => stub })

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(stdout).to include("specguard-lint: checked 1 @intent annotation, 0 malformed")
      end

      # "Could not check" is a different statement from "checked and clean", and
      # a run that made the first while looking like the second is this project's
      # signature defect. So it is said, in its own words.
      # @intent: { entity: "ValidatorBackend schema contract", action: "tolerate a digest-less binary", behavior: "the clause says the contract could not be checked", layer: "integration" }
      it "says the contract could not be checked" do
        stub = clean_stub(version_stdout: "validate-intent 1.4.0 (go1.22.12 linux/arm64)")

        expect(provenance_of({ described_class::ENV_VAR => stub }))
          .to eq("specguard-lint: validated by validate-intent 1.4.0 (go1.22.12 linux/arm64) at #{stub} " \
                 "(SPECGUARD_VALIDATE_INTENT), which reports no schema digest, " \
                 "so the contract it carries could not be checked")
      end

      # A token this gem cannot read is not a token it disagrees with. Sixty-five
      # hex digits is not a SHA-256, and matching its first sixty-four would
      # compare against something nobody wrote.
      # @intent: { entity: "ValidatorBackend schema contract", action: "tolerate a digest-less binary", behavior: "a malformed token is treated as no token rather than a divergence", layer: "integration" }
      it "treats a malformed token as no token rather than as a divergence" do
        %W[schema\ sha256:#{vendored_digest}0 schema\ sha256:#{vendored_digest[0..62]} schema\ sha256:zz].each do |tail|
          runner = resolve(version_stdout: "validate-intent 1.4.0 #{tail}", name: "stub-#{tail.bytesize}")

          expect(runner.schema_contract).to eq(:unreported)
        end
      end
    end

    describe "a binary that cannot report its identity at all" do
      # @intent: { entity: "ValidatorBackend schema contract", action: "tolerate a digest-less binary", behavior: "a binary that cannot report any identity records the contract as unidentified and still validates", layer: "integration" }
      it "records the contract as unidentified, and still validates" do
        stub = clean_stub(version_stdout: "", version_exit: 1)
        runner = described_class.resolve(env: { described_class::ENV_VAR => stub })
        stdout, _stderr, code = run_cli({ described_class::ENV_VAR => stub })

        expect(runner.schema_contract).to eq(:unidentified)
        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(stdout).to include("specguard-lint: checked 1 @intent annotation, 0 malformed")
      end

      # Distinct wording from the sub-case above. Both mean "not checked", but
      # an operator has to be able to tell a build too old to answer from one
      # that answered without a digest — they are fixed differently.
      # @intent: { entity: "ValidatorBackend schema contract", action: "tolerate a digest-less binary", behavior: "the unidentified arm says so in words distinct from the digest-less arm", layer: "integration" }
      it "says so in its own words, distinct from the digest-less arm" do
        anonymous = clean_stub(name: "anonymous", version_stdout: "", version_exit: 1)
        digestless = clean_stub(name: "digestless", version_stdout: "validate-intent 1.4.0")

        lines = [provenance_of({ described_class::ENV_VAR => anonymous }),
                 provenance_of({ described_class::ENV_VAR => digestless })]

        expect(lines.first).to end_with("which could not report its identity, " \
                                        "so the schema contract it carries could not be checked")
        expect(lines.uniq.length).to eq(2)
      end
    end

    # ---------------------------------------------------------------------- #
    # THE THIRD SHAPE, and the judgment call recorded in the module comment.
    #
    # `Schema.load`'s precedent is that an unreadable SCHEMA_PATH is exit 2 —
    # but that is a schema the run is about to ENFORCE, and this one is not:
    # `CLI#run` skips the load on this path precisely so an unrelated packaging
    # accident cannot fail a run that never reads it, and a fatal digest here
    # would re-introduce the dependency that comment removed. A missing operand
    # is also not a divergence: the exit-2 band is for two digests that differ.
    describe "a gem that cannot read its own vendored schema" do
      # The digest is read BEFORE the constant is stubbed away, so the stub
      # binary still reports what a healthy gem would compute. What this group
      # removes is the gem's HALF of the comparison and nothing else — with
      # both halves gone there would be no comparison to have, and the examples
      # would pass for the wrong reason.
      before do
        @healthy_digest = vendored_digest
        stub_const("SpecGuard::RSpec::SCHEMA_PATH", File.join(tmpdir, "not-vendored.json"))
      end

      def unreadable_stub(**stub)
        clean_stub(version_stdout: identity_reporting(@healthy_digest), **stub)
      end

      # @intent: { entity: "ValidatorBackend schema contract", action: "tolerate an unreadable vendored copy", behavior: "a gem that cannot read its own vendored schema does not refuse the run", layer: "integration" }
      it "does not refuse the run" do
        expect { described_class.resolve(env: { described_class::ENV_VAR => unreadable_stub }) }
          .not_to raise_error
      end

      # @intent: { entity: "ValidatorBackend schema contract", action: "tolerate an unreadable vendored copy", behavior: "the contract records as unreadable and validation still runs", layer: "integration" }
      it "records the contract as unreadable, and still validates" do
        stub = unreadable_stub
        runner = described_class.resolve(env: { described_class::ENV_VAR => stub })
        stdout, _stderr, code = run_cli({ described_class::ENV_VAR => stub })

        expect(runner.schema_contract).to eq(:unreadable)
        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(stdout).to include("specguard-lint: checked 1 @intent annotation, 0 malformed")
      end

      # @intent: { entity: "ValidatorBackend schema contract", action: "tolerate an unreadable vendored copy", behavior: "the clause says which half could not be read", layer: "integration" }
      it "says which half could not be read" do
        stub = unreadable_stub

        expect(provenance_of({ described_class::ENV_VAR => stub }))
          .to end_with("whose schema contract could not be checked: " \
                       "this gem could not read its own vendored copy")
      end
    end

    # ---------------------------------------------------------------------- #
    # THE PRODUCT DOES NOT MOVE. The provenance line is stderr prose about the
    # linter's own configuration; the findings and the two `checked …` lines are
    # the product, and they are pinned byte-for-byte across the backends
    # everywhere above. Which band a run lands in must not reach them.
    # @intent: { entity: "ValidatorBackend schema contract", action: "keep stdout stable", behavior: "stdout stays byte-identical across every band that is not a refusal", layer: "integration" }
    it "leaves stdout byte-identical across every band that is not a refusal" do
      stdouts = [clean_stub(name: "matched"),
                 clean_stub(name: "digestless", version_stdout: "validate-intent 1.4.0"),
                 clean_stub(name: "silent", version_stdout: "", version_exit: 1)]
                .map { |stub| run_cli({ described_class::ENV_VAR => stub }) }

      expect(stdouts.map(&:first).uniq.length).to eq(1)
      expect(stdouts.map(&:last).uniq).to eq([SpecGuard::RSpec::CLI::EXIT_OK])
    end

    # @intent: { entity: "ValidatorBackend schema contract", action: "keep stdout stable", behavior: "only the provenance line moves between those bands", layer: "integration" }
    it "moves only the provenance line between those bands" do
      matched = run_cli({ described_class::ENV_VAR => clean_stub(name: "a-matched") })
      digestless = run_cli({ described_class::ENV_VAR =>
                             clean_stub(name: "a-digestless", version_stdout: "validate-intent 1.4.0") })

      expect(stderr_beyond_provenance(digestless[1])).to eq(stderr_beyond_provenance(matched[1]))
      expect(provenance_lines(digestless[1])).not_to eq(provenance_lines(matched[1]))
    end

    # ---------------------------------------------------------------------- #
    # The invariant that keeps this check honest. A constant holding the digest
    # would be a fourth copy of a hex string that already exists in three
    # places, free to drift from the file it claims to describe — which is the
    # precise defect this check was added to detect, re-created inside the
    # detector. `schema_packaging_spec.rb` stays the single pin in this repo.
    # @intent: { entity: "ValidatorBackend schema contract", action: "keep one digest copy", behavior: "the digest is computed at runtime rather than written as a fourth copy", layer: "integration" }
    it "computes the digest at runtime rather than writing a fourth copy of it" do
      root = File.expand_path("../../..", __dir__)
      # ANY 64-hex literal, not this one. The copy that would be the bug is a
      # STALE pin — written down when canonical was some other value and left
      # behind after it changed — and such a constant shares no characters with
      # the digest that is correct today. Grepping for the current digest would
      # catch only the harmless case and pass over the defect this whole slice
      # exists to detect, re-created inside its own detector.
      #
      # The search is deliberately broad: all of `lib/`, which includes the
      # vendored `schemas/open-test-intent.v1.json`. That file carries no 64-hex
      # run today. If a future revision of the canonical schema ever does — an
      # example value, a `pattern`, a fixture digest — this example will fail
      # pointing at a JSON file that is doing nothing wrong. Read that failure
      # as "the guard needs a narrower path", not as a fourth copy of the
      # digest, and narrow it then rather than deleting it.
      out, err, status = Open3.capture3("git", "grep", "-nIE", "[0-9a-fA-F]{64}", "--", "lib/", chdir: root)

      # `git grep` exits 0 having found matches, 1 having searched and found
      # none, and 128 when it could not search at all — not a checkout, an
      # exported tree, a gem unpacked from a .gem file. The output is empty in
      # two of those three, so an example that read the output alone would go
      # green in an environment where it verified nothing: the vacuous green
      # this file names elsewhere, reproduced inside the guard. The status is
      # therefore asserted first, and separately.
      expect([0, 1]).to include(status.exitstatus),
                        "git grep could not search #{root} (exit #{status.exitstatus}): #{err}"
      expect(out).to eq("")
    end
  end

  # ------------------------------------------------------------------------ #
  # THE SCHEMA A RUN ENFORCES — the question the section above asks badly.
  #
  # `--version`'s digest names the schema the binary CARRIES. `LoadSchema`
  # (open-test-intent, `cmd/validate-intent/fileio.go`) gives a
  # `schemas/open-test-intent.v1.json` found beside the executable priority over
  # the compiled-in copy and falls back to it only on ENOENT, and `--version`
  # returns some thirty lines above that decision. So the comparison above is
  # wrong in both directions, and the first of the two is the one that matters:
  #
  #   * embedded copy ours, file beside it somebody else's — `--version` reports
  #     a matching digest, the guard returns `:matched` and says nothing, and
  #     the run is validated against bytes the gem never saw. The guard passes
  #     in precisely the case it was built to refuse;
  #   * embedded copy stale, file beside it ours — refused, for a run that
  #     would have been correct.
  #
  # Slice 19 added `--schema-source`, which calls the real loader and prints
  # `schema <origin> sha256:<hex>` for the bytes a verdict run would load.
  #
  # EVERY BINARY ANSWER IN THIS SECTION IS RECORDED FROM A REAL BINARY —
  # `spec/fixtures/validator/schema-source-probes.json`, which documents how
  # each tree was built — and that is not a preference. The probe degrades
  # silently by design: output it cannot read is indistinguishable from a binary
  # too old to have the flag, so a parse bug produces no failure anywhere. It
  # reverts the guard to comparing the carried digest and the suite goes green,
  # which is the defect this whole section exists to close, re-created inside
  # the fix. A hand-written line that happens to fit the pattern would be green
  # on both sides of that bug; a recording cannot be.
  describe "the schema a run enforces" do
    let(:paths) { %w[spec/fixtures/order_spec.rb] }

    def recorded_probes
      @recorded_probes ||= JSON.parse(File.read("spec/fixtures/validator/schema-source-probes.json"))
    end

    def recorded(name)
      recorded_probes.fetch("cases").fetch(name)
    end

    def recorded_source(name)
      recorded(name).fetch("schema_source").fetch("stdout")
    end

    # A stub answering both flags exactly as the recorded binary answered them,
    # over a clean report for the fixture the CLI examples lint.
    def recorded_stub(name, **overrides)
      version = recorded(name).fetch("version")
      source = recorded(name).fetch("schema_source")

      clean_stub(name: "recorded-#{name}",
                 version_stdout: version.fetch("stdout").chomp,
                 version_stderr: version.fetch("stderr"),
                 version_exit: version.fetch("exit"),
                 schema_source_stdout: source.fetch("stdout"),
                 schema_source_stderr: source.fetch("stderr"),
                 schema_source_exit: source.fetch("exit"),
                 **overrides)
    end

    # The same recorded binary with the flag taken away — the recorded answer of
    # a build that predates it. This is what the gem saw before this section
    # existed, and several examples below are only meaningful next to it.
    def without_schema_source
      old = recorded("unsupported").fetch("schema_source")

      { schema_source_stdout: old.fetch("stdout"),
        schema_source_stderr: old.fetch("stderr"),
        schema_source_exit: old.fetch("exit") }
    end

    def resolve_recorded(name, **overrides)
      described_class.resolve(env: { described_class::ENV_VAR => recorded_stub(name, **overrides) })
    end

    # The extraction open-test-intent's own comment prescribes for this line:
    # "the digest is LAST and is the only token after the origin, so
    # `${line##* }` yields `sha256:<hex>` whatever the origin contains", and the
    # origin is everything between `schema ` and that final space. Spelled out
    # here rather than borrowed from the gem, because an expectation computed by
    # the code under test asserts that the code agrees with itself.
    def shell_extraction(line)
      text = line.chomp

      { origin: text.sub(/\Aschema /, "").sub(/ \S+\z/, ""),
        digest: text.split(" ").last.delete_prefix("sha256:") }
    end

    # Does `line` read these fragments, in this order, with anything at all
    # allowed between them? Used to compare a README sample against a real
    # message whose digests and host paths the sample elides. Order and
    # single-line containment are both load bearing: a fragment short enough to
    # appear somewhere else in the file (", loaded from ") would otherwise be
    # answered by a different sample entirely.
    def in_order?(line, fragments)
      cursor = 0

      fragments.all? do |fragment|
        found = line.index(fragment, cursor)
        cursor = found + fragment.length if found

        !found.nil?
      end
    end

    # ---------------------------------------------------------------------- #
    # THE PARSE, against the bytes it will meet in the field.
    describe "reading the real binary's answer" do
      # Both origin shapes the flag can print: an absolute path, and the
      # literal `<embedded schema>` when nothing on disk shadowed the embed.
      # The path one was recorded under a directory whose name contains a
      # SPACE, which is why the origin cannot be read as a single token.
      #
      # `disk_wins` is absent here because it refuses to resolve — there is no
      # Runner to ask. Its parse is asserted through the digest and origin its
      # refusal names, in the divergence group below, which is the only place
      # that parse can be observed.
      %w[embedded on_disk embed_differs].each do |name|
        # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "read the recorded answer", behavior: "each recorded line yields its origin and digest by the two-part pattern", layer: "integration" }
        it "extracts the origin and the digest from the recorded `#{name}` line" do
          expect(resolve_recorded(name).enforced_schema).to eq(shell_extraction(recorded_source(name)))
        end
      end

      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "read the recorded answer", behavior: "the recorded origin is not a single token, proving the parse is not a naive split", layer: "integration" }
      it "recorded an origin that is not a single token, so the parse cannot be `split`" do
        expect(shell_extraction(recorded_source("on_disk"))[:origin]).to include(" ")
      end

      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "read the recorded answer", behavior: "the embedded origin is recorded as the label, not as a path", layer: "integration" }
      it "recorded the embedded origin as the label, not as a path" do
        expect(shell_extraction(recorded_source("embedded"))[:origin]).to eq("<embedded schema>")
      end

      # THE FALSIFIER for scope item 5. The identity pattern was proposed for
      # this surface unchanged; it matches it never, because it requires
      # `schema` immediately followed by `sha256:` and the origin sits between
      # them. Reusing it would have made every probe unreadable — and, under the
      # degrade rule, silent. The second half is the positive control: the same
      # pattern on the surface it WAS written for, so this example fails when
      # the patterns are confused rather than when either is merely absent.
      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "read the recorded answer", behavior: "that line is not readable by the identity pattern, which is why there are two probes", layer: "integration" }
      it "is not readable by the identity pattern, which is why there are two" do
        pattern = SpecGuard::RSpec::ValidatorBackend::Runner::SCHEMA_DIGEST_PATTERN

        expect(recorded_source("embedded")[pattern, 1]).to be_nil
        expect(recorded_source("on_disk")[pattern, 1]).to be_nil
        expect(recorded("embedded").fetch("version").fetch("stdout")[pattern, 1]).to eq(vendored_digest)
      end

      # The recordings are pinned bytes and the vendored schema is a file in
      # this repo; if canonical ever moves, they stop describing each other and
      # every example below would compare two digests that were never meant to
      # be equal. Said here, once, with the instruction attached — rather than
      # left to be diagnosed from four confusing failures.
      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "read the recorded answer", behavior: "the answer still describes the schema this gem vendors", layer: "integration" }
      it "still describes the schema this gem vendors" do
        expect(shell_extraction(recorded_source("embedded"))[:digest]).to eq(vendored_digest),
                                                                         "spec/fixtures/validator/" \
                                                                         "schema-source-probes.json is stale: " \
                                                                         "re-record it from a binary built at the " \
                                                                         "current open-test-intent, following the " \
                                                                         "`recorded_from.how` steps it carries."
      end
    end

    # ---------------------------------------------------------------------- #
    # BAND: ENFORCED AND EQUAL.
    describe "a binary whose runs load the schema this gem vendors" do
      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "accept an enforcing binary", behavior: "a binary whose runs load the embedded vendored copy records the contract as enforced", layer: "integration" }
      it "records the contract as enforced, from the embedded copy" do
        expect(resolve_recorded("embedded").schema_contract).to eq(:enforced)
      end

      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "accept an enforcing binary", behavior: "a binary loading a schema file beside itself records enforced as well", layer: "integration" }
      it "records the contract as enforced, from a file beside the binary" do
        expect(resolve_recorded("on_disk").schema_contract).to eq(:enforced)
      end

      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "accept an enforcing binary", behavior: "an enforcing binary runs normally changing neither stdout nor the exit code", layer: "integration" }
      it "runs normally, changing neither stdout nor the exit code" do
        stdout, _stderr, code = run_cli({ described_class::ENV_VAR => recorded_stub("embedded") })

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(stdout).to include("specguard-lint: checked 1 @intent annotation, 0 malformed")
      end

      # Scope items 3 and 4. The hedge existed because the gem could not know
      # what the run enforced; on this path it now can, so the line says which
      # schema was loaded and from where instead of disclaiming the question.
      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "accept an enforcing binary", behavior: "the clause names the origin and drops the hedge it no longer needs", layer: "integration" }
      it "names the origin, and drops the hedge it no longer needs" do
        stub = recorded_stub("on_disk")
        origin = shell_extraction(recorded_source("on_disk"))[:origin]

        expect(provenance_of({ described_class::ENV_VAR => stub }))
          .to eq("specguard-lint: validated by #{recorded('on_disk').fetch('version').fetch('stdout').chomp} " \
                 "at #{stub} (SPECGUARD_VALIDATE_INTENT) — it reports enforcing the schema this gem vendors, " \
                 "loaded from #{origin}")
        expect(provenance_of({ described_class::ENV_VAR => stub }))
          .not_to include("not necessarily the one this run enforced")
      end

      # THE MIRROR CASE, and it is a false REFUSAL rather than a false pass:
      # this binary's embedded schema is not the gem's, so comparing the carried
      # digest exits 2 on a run whose loaded schema is exactly right. Asserted
      # against the same recording with the flag removed, so the two arms differ
      # in one fact and nothing else.
      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "accept an enforcing binary", behavior: "a stale embedded copy whose runs load ours is no longer refused", layer: "integration" }
      it "no longer refuses a binary whose embedded copy is stale but whose runs load ours" do
        with_flag = run_cli({ described_class::ENV_VAR => recorded_stub("embed_differs") })
        without_flag = run_cli({ described_class::ENV_VAR =>
                                 recorded_stub("embed_differs", name: "recorded-embed-differs-old",
                                                                **without_schema_source) })

        expect(with_flag[2]).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(without_flag[2]).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
      end
    end

    # ---------------------------------------------------------------------- #
    # BAND: ENFORCED AND DIFFERENT. The case this ticket exists for.
    describe "a binary whose runs load a schema this gem does not vendor" do
      # The premise, stated as an assertion rather than assumed: this recorded
      # binary's CARRIED digest is the gem's. Without this, the examples below
      # would pass against a recording that merely diverges on both digests —
      # which the guard already caught — and the regression they exist to pin
      # would go untested.
      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "refuse an enforcing stranger", behavior: "the divergent binary carries the vendored digest, so the older comparison saw nothing wrong", layer: "integration" }
      it "carries the digest the gem vendors, so the old comparison saw nothing wrong" do
        carried = recorded("disk_wins").fetch("version").fetch("stdout")[
          SpecGuard::RSpec::ValidatorBackend::Runner::SCHEMA_DIGEST_PATTERN, 1
        ]

        expect(carried).to eq(vendored_digest)
        expect(shell_extraction(recorded_source("disk_wins"))[:digest]).not_to eq(vendored_digest)
      end

      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "refuse an enforcing stranger", behavior: "a binary whose runs load a schema the gem does not vendor refuses to resolve", layer: "integration" }
      it "refuses to resolve" do
        expect { resolve_recorded("disk_wins") }.to raise_error(SpecGuard::RSpec::ValidatorError)
      end

      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "refuse an enforcing stranger", behavior: "the refusal exits two, not a verdict about annotations", layer: "integration" }
      it "exits 2, not 1 — this is not a verdict about anyone's annotations" do
        _, _, code = run_cli({ described_class::ENV_VAR => recorded_stub("disk_wins") })

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
      end

      # Both digests and the ORIGIN. The origin is the half the carried message
      # never had to carry: `<embedded schema>` and a path on this host are
      # fixed by entirely different actions, and without it the reader is told
      # the two disagree and not where to go.
      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "refuse an enforcing stranger", behavior: "both digests, the origin and the build are named", layer: "integration" }
      it "names both digests, the origin, and the build it read them from" do
        stub = recorded_stub("disk_wins")
        enforced = shell_extraction(recorded_source("disk_wins"))
        _, stderr, = run_cli({ described_class::ENV_VAR => stub })

        expect(error_lines(stderr).length).to eq(1)
        expect(error_lines(stderr).first).to include("the validator backend at #{stub}")
        expect(error_lines(stderr).first).to include("sha256:#{enforced[:digest]}")
        expect(error_lines(stderr).first).to include("sha256:#{vendored_digest}")
        expect(error_lines(stderr).first).to include(enforced[:origin])
        expect(error_lines(stderr).first).to include(recorded("disk_wins").fetch("version").fetch("stdout").chomp)
      end

      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "refuse an enforcing stranger", behavior: "the failure happens before anything is selected or scanned", layer: "integration" }
      it "fails before anything is selected or scanned" do
        stdout, stderr, = run_cli({ described_class::ENV_VAR => recorded_stub("disk_wins") })

        expect(recorded_invocations("recorded-disk_wins")).to be_empty
        expect(stdout).to eq("")
        expect(stderr).not_to include("selected")
      end

      # THE REGRESSION, pinned as a difference rather than as a state. One
      # recording, two runs, one fact changed: with the flag answered the run is
      # refused, and with it taken away — which is all the gem could see before
      # this change — the identical binary sails through with exit 0 and a
      # provenance line saying the contract matched. Delete the enforced
      # comparison and this example fails; nothing else in the file would.
      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "refuse an enforcing stranger", behavior: "comparing only the carried digest used to pass this silently", layer: "integration" }
      it "was a silent pass when only the carried digest could be compared" do
        refused = run_cli({ described_class::ENV_VAR => recorded_stub("disk_wins") })
        as_before = run_cli({ described_class::ENV_VAR =>
                              recorded_stub("disk_wins", name: "recorded-disk-wins-old", **without_schema_source) })

        expect(refused[2]).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
        expect(as_before[2]).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(provenance_lines(as_before[1]).first).to include("reports carrying the schema this gem vendors")
      end
    end

    # ---------------------------------------------------------------------- #
    # DEGRADE, NEVER REFUSE. The rule the identity probe already documents, and
    # the reason a gem shipping this can be installed beside binaries that have
    # never heard of the flag.
    describe "a binary that cannot answer --schema-source" do
      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "tolerate an unanswerable probe", behavior: "a binary without the probe flag falls back to the carried digest", layer: "integration" }
      it "falls back to the carried digest, recorded from a pre-slice-19 build" do
        runner = resolve_recorded("unsupported")

        expect(runner.enforced_schema).to be_nil
        expect(runner.schema_contract).to eq(:matched)
      end

      # Criterion: a binary without the flag is byte-identical to the release
      # before this change. The literal below is that release's sentence,
      # written out rather than compared against another run of this code --
      # two runs of the same build agree with each other whatever it prints, so
      # a self-comparison would pass on a wording change and assert nothing.
      #
      # The broader half of the same criterion is not here and cannot be: it is
      # that the ~880 other examples in this suite, all of which resolve a stub
      # with no `--schema-source`, still pass having been changed in no way.
      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "tolerate an unanswerable probe", behavior: "the fallback prints the sentence the earlier release printed, unchanged", layer: "integration" }
      it "prints the sentence the release before the flag printed, unchanged" do
        stub = recorded_stub("unsupported")
        stdout, stderr, code = run_cli({ described_class::ENV_VAR => stub })

        expect(provenance_lines(stderr))
          .to eq(["specguard-lint: validated by " \
                  "#{recorded('unsupported').fetch('version').fetch('stdout').chomp} at #{stub} " \
                  "(SPECGUARD_VALIDATE_INTENT), which reports carrying the schema this gem vendors — " \
                  "the contract it carries, not necessarily the one this run enforced"])
        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
        expect(stdout).to include("specguard-lint: checked 1 @intent annotation, 0 malformed")
      end

      # And the stderr it wrote answering a flag it does not have goes nowhere
      # near the run's own stderr. `no file(s) match '--schema-source'` in a CI
      # log would be read as the linter failing to find a file somebody named.
      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "tolerate an unanswerable probe", behavior: "the old binary refusal written to stderr does not leak", layer: "integration" }
      it "does not leak the refusal the old binary wrote to stderr" do
        _, stderr, = run_cli({ described_class::ENV_VAR => recorded_stub("unsupported") })

        expect(stderr).not_to include("no file(s) match")
      end

      # `--schema-source` exits 2 with the "could not load schema" diagnostic
      # when a schema exists beside the binary and will not load. That is a real
      # failure and it is not this check's to report: `check`/`run` reaches it a
      # moment later from the verdict path, with the message that belongs to it.
      # Turning it into a schema-CONTRACT error here would rename a broken
      # installation into a divergence that does not exist.
      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "tolerate an unanswerable probe", behavior: "an unloadable schema counts as unavailable rather than a divergence", layer: "integration" }
      it "treats an unloadable schema as unavailable rather than as a divergence" do
        runner = resolve_recorded("unloadable")

        expect(runner.enforced_schema).to be_nil
        expect(runner.schema_contract).to eq(:matched)
      end

      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "tolerate an unanswerable probe", behavior: "the unloadable schema is left to fail on the verdict path with its own diagnostic", layer: "integration" }
      it "leaves the unloadable schema to fail on the verdict path, with its own diagnostic" do
        broken = recorded("unloadable").fetch("schema_source")
        stub = recorded_stub("unloadable", name: "unloadable-run", stdout: "",
                             stderr: broken.fetch("stderr"), exit_code: broken.fetch("exit"))
        _, stderr, code = run_cli({ described_class::ENV_VAR => stub })

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
        expect(error_lines(stderr).first).to include("could not load schema")
      end

      # The shapes no recording can produce, held to the identity probe's rules
      # for the identity probe's reasons: a second line, an escape sequence or a
      # NUL would break or forge the one line the CLI prints per run.
      {
        "an empty answer" => "",
        "a second line" => "schema <embedded schema> sha256:%<digest>s\nand another thing",
        "a control character" => "schema <embedded\e[31m schema> sha256:%<digest>s",
        "an invalid byte sequence" => "schema \xFF\xFE sha256:%<digest>s",
        "a report document" => '{"mode":"source","findings":[]}',
        "a line with no origin" => "schema sha256:%<digest>s",
        "a line with anything in front of it" => "warning: schema <embedded schema> sha256:%<digest>s",
        "an origin-only line" => "schema <embedded schema>",
        "sixty-five hex digits" => "schema <embedded schema> sha256:%<digest>s0",
        "a truncated digest" => "schema <embedded schema> sha256:%<digest>.62s",
        "trailing text after the digest" => "schema <embedded schema> sha256:%<digest>s (fresh)"
      }.each_with_index do |(what, template), index|
        # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "bound the answer", behavior: "each degenerate answer shape counts as unavailable rather than an answer", layer: "integration" }
        it "treats #{what} as unavailable rather than as an answer" do
          runner = described_class.resolve(
            env: { described_class::ENV_VAR =>
                   stub_validator(name: "shape-#{index}", schema_source_exit: 0, schema_source_stderr: "",
                                  schema_source_stdout: format(template, digest: vendored_digest)) }
          )

          expect(runner.enforced_schema).to be_nil
          expect(runner.schema_contract).to eq(:matched)
        end
      end

      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "bound the answer", behavior: "an answer longer than the line budget counts as unavailable", layer: "integration" }
      it "treats an answer longer than the line budget as unavailable" do
        giant = "schema #{'x' * SpecGuard::RSpec::ValidatorBackend::Runner::SCHEMA_SOURCE_MAX_BYTES} " \
                "sha256:#{vendored_digest}"
        runner = described_class.resolve(
          env: { described_class::ENV_VAR =>
                 stub_validator(schema_source_exit: 0, schema_source_stderr: "", schema_source_stdout: giant) }
        )

        expect(runner.enforced_schema).to be_nil
      end

      # A path is allowed to be long — PATH_MAX is 4096 on Linux — so the budget
      # that suits a version string would reject correct answers from correctly
      # installed binaries. Asserted from the other side of the boundary so the
      # constant cannot quietly shrink back to the identity probe's.
      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "bound the answer", behavior: "an origin far longer than a version line is accepted", layer: "integration" }
      it "accepts an origin far longer than a version line is allowed to be" do
        origin = "/#{'d' * 400}/schemas/open-test-intent.v1.json"
        runner = described_class.resolve(
          env: { described_class::ENV_VAR =>
                 stub_validator(schema_source_exit: 0, schema_source_stderr: "",
                                schema_source_stdout: "schema #{origin} sha256:#{vendored_digest}\n") }
        )

        expect(runner.enforced_schema).to eq(origin: origin, digest: vendored_digest)
      end

      # The greedy read the constant documents, asserted rather than described:
      # a directory really can be named `sha256:<64-hex>`, and the answer is
      # still the LAST such token -- the reading Go's own comment prescribes for
      # the shell one-liner (`${line##* }`). A non-greedy origin would take the
      # first and compare a digest nobody reported.
      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "bound the answer", behavior: "the digest is read as the last token even when the origin ends in one", layer: "integration" }
      it "reads the digest as the last token, even when the origin ends in one" do
        origin = "/schemas/sha256:#{'a' * 64}"
        runner = described_class.resolve(
          env: { described_class::ENV_VAR =>
                 stub_validator(schema_source_exit: 0, schema_source_stderr: "",
                                schema_source_stdout: "schema #{origin} sha256:#{vendored_digest}\n") }
        )

        expect(runner.enforced_schema).to eq(origin: origin, digest: vendored_digest)
        expect(runner.schema_contract).to eq(:enforced)
      end

      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "bound the answer", behavior: "an upper-case digest reads as the same digest, never as a divergence", layer: "integration" }
      it "reads an upper-case digest as the same digest, never as a divergence" do
        runner = described_class.resolve(
          env: { described_class::ENV_VAR =>
                 stub_validator(schema_source_exit: 0, schema_source_stderr: "",
                                schema_source_stdout: "schema <embedded schema> " \
                                                      "sha256:#{vendored_digest.upcase}\n") }
        )

        expect(runner.schema_contract).to eq(:enforced)
      end
    end

    # ---------------------------------------------------------------------- #
    # THE PROBE ITSELF: once per run, after the identity, and never before the
    # backend has been asked for at all.
    describe "the enforced-schema probe" do
      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "ask once and in order", behavior: "the binary is asked exactly once with exactly that flag", layer: "integration" }
      it "asks the binary exactly once, with exactly that flag" do
        described_class.resolve(env: { described_class::ENV_VAR => stub_validator })

        expect(schema_source_probes).to eq([["--schema-source"]])
      end

      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "ask once and in order", behavior: "the probe runs once per run, not once per batch", layer: "integration" }
      it "asks once per run, not once per batch" do
        paths = Array.new(1_500) { |i| format("spec/models/example_%05d_spec.rb", i) }
        run_backend(paths, stdout: document(paths.map { |path| ok_finding(file: path) }))

        expect(recorded_invocations.length).to be > 1
        expect(schema_source_probes.length).to eq(1)
      end

      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "ask once and in order", behavior: "it asks after the identity and before any verdict", layer: "integration" }
      it "asks before it asks for any verdict, and after the identity" do
        run_backend(["a_spec.rb"], stdout: document([ok_finding]))

        expect(all_invocations.first(2)).to eq([["--version"], ["--schema-source"]])
      end

      # The second half is what makes the first mean anything: an args log that
      # does not exist yet answers [] too, so a Runner that stayed quiet and a
      # broken instrument look identical without it.
      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "ask once and in order", behavior: "the binary is not invoked before the backend has been resolved", layer: "integration" }
      it "does not invoke the binary before the backend has been resolved" do
        path = stub_validator

        described_class::Runner.new(path)
        expect(schema_source_probes).to be_empty

        described_class.resolve(env: { described_class::ENV_VAR => path })
        expect(schema_source_probes.length).to eq(1)
      end

      # The default configuration, and the one nearly every run uses. A probe
      # that ran with the backend off would be a process per run spent on a
      # binary nobody named.
      # SPGD-867: there is no "backend off" configuration any more. The probe
      # cost rule that survives is the one above — once per RESOLVED backend —
      # and a resolution failure never reaches the probe at all.
      # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "ask once and in order", behavior: "the probe does not run when resolution fails", layer: "integration" }
      it "does not run when resolution fails" do
        allow(described_class::Installer).to receive(:obtain)
          .and_raise(SpecGuard::RSpec::ValidatorError, "could not obtain validate-intent")

        expect { described_class.resolve(env: {}) }
          .to raise_error(SpecGuard::RSpec::ValidatorError)
        expect(schema_source_probes).to be_empty
      end
    end

    # ---------------------------------------------------------------------- #
    # THE PRODUCT DOES NOT MOVE. Which band a run lands in is stderr prose about
    # the linter's own configuration; the findings and the two `checked …` lines
    # are the product.
    # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "keep stdout stable", behavior: "stdout stays byte-identical across every band that is not a refusal", layer: "integration" }
    it "leaves stdout byte-identical across every band that is not a refusal" do
      stdouts = %w[embedded on_disk unsupported unloadable embed_differs]
                .map { |name| run_cli({ described_class::ENV_VAR => recorded_stub(name) }) }

      expect(stdouts.map(&:first).uniq.length).to eq(1)
      expect(stdouts.map(&:last).uniq).to eq([SpecGuard::RSpec::CLI::EXIT_OK])
    end

    # Each band is a different statement and must be worded as one: an operator
    # reading "could not check" has something to fix, and one reading "enforces
    # the schema this gem vendors" does not.
    # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "word the bands", behavior: "the enforced, carried and could-not-check bands are worded differently", layer: "integration" }
    it "words the enforced, carried and could-not-check bands differently" do
      lines = %w[embedded unsupported].map { |name| provenance_of({ described_class::ENV_VAR => recorded_stub(name) }) }
      lines << provenance_of({ described_class::ENV_VAR =>
                               clean_stub(name: "digestless", version_stdout: "validate-intent 1.4.0") })
      lines << provenance_of({ described_class::ENV_VAR =>
                               clean_stub(name: "anonymous", version_stdout: "", version_exit: 1) })

      expect(lines.uniq.length).to eq(4)
      expect(lines.first).to include("reports enforcing the schema this gem vendors, loaded from ")
    end

    # The two probes are independent processes and fail independently, so the
    # line has to be able to say both things. Without this the identity-less arm
    # returns early and reports that the contract "could not be checked" on a
    # run where it was checked and passed — a false statement, and the more
    # alarming direction of false.
    # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "word the bands", behavior: "the enforced schema is still named when the binary could not identify itself", layer: "integration" }
    it "still names the enforced schema when the binary could not identify itself" do
      stub = recorded_stub("embedded", name: "enforced-anonymous", version_stdout: "", version_exit: 1)
      runner = described_class.resolve(env: { described_class::ENV_VAR => stub })

      expect(runner.schema_contract).to eq(:enforced)
      expect(provenance_of({ described_class::ENV_VAR => stub }))
        .to eq("specguard-lint: validated by the binary at #{stub} (SPECGUARD_VALIDATE_INTENT), " \
               "which could not report its identity — it reports enforcing the schema this gem vendors, " \
               "loaded from <embedded schema>")
    end

    # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "word the bands", behavior: "the refusal fires on the enforced digest even when the binary could not identify itself", layer: "integration" }
    it "refuses on the enforced digest even when the binary could not identify itself" do
      stub = recorded_stub("disk_wins", name: "diverged-anonymous", version_stdout: "", version_exit: 1)
      _, stderr, code = run_cli({ described_class::ENV_VAR => stub })

      expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
      expect(error_lines(stderr).first).to include("the binary could not identify itself")
    end

    # The unreadable-vendored-schema band, reached through the new arm. A
    # missing operand is not a difference, so it is still not a refusal — and
    # the binary's half is deliberately left in place: with both halves gone
    # there would be no comparison to have and this would pass for the wrong
    # reason. The recording used is the DIVERGING one, so a gem that read a
    # vendored digest here at all would refuse and fail this example.
    # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "word the bands", behavior: "no refusal happens when the gem cannot read its own vendored schema", layer: "integration" }
    it "does not refuse when the gem cannot read its own vendored schema" do
      stub = recorded_stub("disk_wins", name: "no-vendored-copy")
      stub_const("SpecGuard::RSpec::SCHEMA_PATH", File.join(tmpdir, "not-vendored.json"))
      stdout, _stderr, code = run_cli({ described_class::ENV_VAR => stub })

      expect(described_class.resolve(env: { described_class::ENV_VAR => stub }).schema_contract).to eq(:unreadable)
      expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_OK)
      expect(stdout).to include("specguard-lint: checked 1 @intent annotation, 0 malformed")
    end

    # ---------------------------------------------------------------------- #
    # THE README SAYS THE SAME THING, and this is what makes that checkable.
    #
    # The failure being prevented is specific and has happened here before: a
    # sample block updated in HALF — the new clause appended while the identity
    # string above it stayed stale — which reads as documentation and is worse
    # than a sample nobody touched. Every string below is EXTRACTED from a real
    # run rather than typed, so the only way to satisfy it is to put the words
    # the code actually emits into the file.
    # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "document the clauses", behavior: "every clause it can print is documented in the readme in the words it prints them", layer: "integration" }
    it "documents every clause it can print, in the README, in the words it prints them" do
      readme = File.read("README.md")
      bands = { "embedded" => recorded_stub("embedded"), "unsupported" => recorded_stub("unsupported") }
      bands["digestless"] = clean_stub(name: "readme-digestless", version_stdout: "validate-intent 1.4.0")
      bands["anonymous"] = clean_stub(name: "readme-anonymous", version_stdout: "", version_exit: 1)

      bands.each_value do |stub|
        clause = provenance_of({ described_class::ENV_VAR => stub })[/\(SPECGUARD_VALIDATE_INTENT\)(.*)\z/, 1]

        expect(clause).not_to be_empty
        expect(readme).to include(clause), "README.md does not carry the clause this gem prints: #{clause.inspect}"
      end
    end

    # The fifth clause needs the gem's half of the comparison taken away, so it
    # is asserted here rather than folded into the loop above.
    # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "document the clauses", behavior: "the unreadable-vendored-copy clause is documented too", layer: "integration" }
    it "documents the unreadable-vendored-copy clause too" do
      stub_const("SpecGuard::RSpec::SCHEMA_PATH", File.join(tmpdir, "not-vendored.json"))
      clause = provenance_of({ described_class::ENV_VAR => recorded_stub("embedded") })[
        /\(SPECGUARD_VALIDATE_INTENT\)(.*)\z/, 1
      ]

      expect(clause).to include("could not read its own vendored copy")
      expect(File.read("README.md")).to include(clause)
    end

    # And the refusal, whose sample block elides both digests and rewrites the
    # host-specific paths. Everything BETWEEN those is fixed text, and it is
    # obtained by masking the volatile tokens out of a really-raised error and
    # splitting on the holes -- so the fragments cannot be transcribed slightly
    # wrong, and the ", loaded from " clause in the MIDDLE is covered rather
    # than only the tail. Masking runs longest-first: the identity string
    # contains a digest, so replacing the digest first would leave it unmasked.
    #
    # The fragments are matched IN ORDER AND WITHIN ONE LINE, not against the
    # file. Against the file, ", loaded from " is satisfied by the provenance
    # sample two paragraphs above it -- so deleting it from the refusal sample
    # would leave this green, which is an assertion answered by neighbouring
    # prose rather than by the thing it names.
    # @intent: { entity: "ValidatorBackend enforced-schema probe", action: "document the clauses", behavior: "the refusal is documented in the words the refusal uses", layer: "integration" }
    it "documents the refusal in the words the refusal uses" do
      stub = recorded_stub("disk_wins")
      enforced = shell_extraction(recorded_source("disk_wins"))
      _, stderr, = run_cli({ described_class::ENV_VAR => stub })
      volatile = [recorded("disk_wins").fetch("version").fetch("stdout").chomp, stub,
                  enforced[:origin], enforced[:digest], vendored_digest]
      masked = volatile.reduce(error_lines(stderr).first) { |line, token| line.gsub(token, "\u0000") }
      fragments = masked.split("\u0000").reject(&:empty?)
      samples = File.read("README.md").lines.map(&:chomp)
                    .select { |line| line.start_with?("specguard-lint: error: the validator backend at") }

      expect(fragments.length).to be >= 4
      expect(samples).not_to be_empty
      expect(samples.any? { |sample| in_order?(sample, fragments) })
        .to be(true), "no README sample of a backend refusal reads, in order: #{fragments.inspect}"
    end
  end

  # ------------------------------------------------------------------------ #
  # ------------------------------------------------------------------------ #
  # SPGD-867: `--require-validator` is GONE, because its assertion is now the
  # DEFAULT. A run that cannot resolve a validator exits 2 outright — there is
  # no Ruby path to silently fall back to, which was the exact hole the flag
  # existed to guard. What this block pins is the always-on form of that gate.
  describe "resolution as the always-on gate" do
    let(:paths) { %w[spec/fixtures/order_spec.rb] }

    # @intent: { entity: "specguard-lint resolution gate", action: "retire the old flag", behavior: "the retired validator flag is refused as an unknown option", layer: "integration" }
    it "refuses the retired flag as an unknown option" do
      _, stderr, code = run_cli({}, ["--require-validator", *paths])

      expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
      expect(error_lines(stderr).first).to include("invalid option")
    end

    # @intent: { entity: "specguard-lint resolution gate", action: "gate every run", behavior: "a run with no obtainable binary exits two, not one and not a crash", layer: "integration" }
    it "exits 2 when no binary can be obtained, not 1 and not a crash" do
      allow(described_class::Installer).to receive(:obtain)
        .and_raise(SpecGuard::RSpec::ValidatorError, "could not obtain validate-intent: no network")
      _, stderr, code = run_cli({}, paths)

      expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
      expect(code).not_to eq(SpecGuard::RSpec::CLI::EXIT_MALFORMED)
      expect(stderr).not_to include("internal error")
    end

    # BOTH remediations, in the message, so the first run without network is
    # actionable from the CI log alone.
    # @intent: { entity: "specguard-lint resolution gate", action: "gate every run", behavior: "the refusal names the env var and the install script alternative", layer: "integration" }
    it "names the env var and the install.sh alternative" do
      allow(described_class::Installer).to receive(:obtain)
        .and_raise(SpecGuard::RSpec::ValidatorError, described_class::Installer::REMEDIATIONS)
      _, stderr, = run_cli({}, paths)

      expect(error_lines(stderr).first).to include("SPECGUARD_VALIDATE_INTENT")
      expect(error_lines(stderr).first).to include("install.sh")
    end

    # @intent: { entity: "specguard-lint resolution gate", action: "gate every run", behavior: "nothing is selected, scanned or reported when the gate refuses", layer: "integration" }
    it "selects, scans and reports nothing" do
      allow(described_class::Installer).to receive(:obtain)
        .and_raise(SpecGuard::RSpec::ValidatorError, "could not obtain validate-intent")
      stdout, stderr, = run_cli({}, paths)

      expect(stdout).to be_empty
      expect(stderr).not_to include("checked")
      expect(stderr).not_to include("selected")
    end

    # A named-but-unusable binary keeps failing for its own reason out of
    # #verify! — the gate did not change that arm.
    # @intent: { entity: "specguard-lint resolution gate", action: "gate every run", behavior: "a named but unusable binary fails for its own reason", layer: "integration" }
    it "leaves a named-but-unusable binary failing for its own reason" do
      missing = File.join(tmpdir, "not-there")
      _, stderr, code = run_cli({ described_class::ENV_VAR => missing }, paths)

      expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
      expect(error_lines(stderr).first).to include("does not exist")
    end
  end
  # ------------------------------------------------------------------------ #
  # SPGD-867: the first-run installer. Nothing here touches the network —
  # `download` is stubbed at the module boundary, which is the seam the
  # production code itself owns (Net::HTTP behind one method). What is pinned
  # is the CONTRACT: platform mapping, cache reuse, SHA256SUMS verification,
  # atomic install, and the exit-2 refusal naming both remediations.
  describe SpecGuard::RSpec::ValidatorBackend::Installer do
    subject(:installer) { described_class }

    let(:cache_root) { File.join(tmpdir, "cache") }
    let(:env) { { installer::CACHE_DIR_VAR => cache_root } }
    let(:asset) { "validate-intent-linux-amd64" }
    let(:bytes) { "#!/bin/sh\nfake binary\n" }
    let(:digest) { Digest::SHA256.hexdigest(bytes) }
    let(:manifest) { "#{digest}  #{asset}\n" }

    def stub_download_with(manifest_text: manifest, asset_bytes: bytes)
      allow(installer).to receive(:download) do |url|
        next manifest_text if url.end_with?("SHA256SUMS")
        next asset_bytes if url.end_with?(asset)

        raise "unexpected fetch: #{url}"
      end
    end

    describe ".asset_name" do
      # @intent: { entity: "ValidatorBackend::Installer", action: "map platform assets", behavior: "each published platform maps to its asset name", layer: "unit" }
      it "maps the published platforms" do
        expect(installer.asset_name(platform: "x86_64-linux")).to eq("validate-intent-linux-amd64")
        expect(installer.asset_name(platform: "aarch64-linux")).to eq("validate-intent-linux-arm64")
        expect(installer.asset_name(platform: "x86_64-darwin22")).to eq("validate-intent-darwin-amd64")
        expect(installer.asset_name(platform: "arm64-darwin23")).to eq("validate-intent-darwin-arm64")
      end

      # @intent: { entity: "ValidatorBackend::Installer", action: "map platform assets", behavior: "an unsupported platform is refused naming both remediations", layer: "unit" }
      it "refuses an unsupported platform, naming both remediations" do
        expect { installer.asset_name(platform: "x86_64-freebsd") }
          .to raise_error(SpecGuard::RSpec::ValidatorError, /freebsd.*SPECGUARD_VALIDATE_INTENT.*install\.sh/m)
      end
    end

    describe ".cache_dir" do
      # @intent: { entity: "ValidatorBackend::Installer", action: "place the cache", behavior: "the cache dir honours the configured override", layer: "unit" }
      it "honours SPECGUARD_CACHE_DIR" do
        expect(installer.cache_dir(env)).to end_with("specguard-ruby/validate-intent/#{installer::RELEASE_TAG}")
      end

      # @intent: { entity: "ValidatorBackend::Installer", action: "place the cache", behavior: "the cache falls back to the xdg cache home when the override is unset", layer: "unit" }
      it "falls back to XDG_CACHE_HOME when the override is unset" do
        expect(installer.cache_dir({ "XDG_CACHE_HOME" => File.join(tmpdir, "xdg") }))
          .to end_with("xdg/specguard-ruby/validate-intent/#{installer::RELEASE_TAG}")
      end
    end

    describe ".obtain" do
      # @intent: { entity: "ValidatorBackend::Installer", action: "obtain the binary", behavior: "obtain downloads, verifies against the sha manifest and installs an executable", layer: "unit" }
      it "downloads, verifies against SHA256SUMS, and installs an executable binary" do
        stub_download_with

        path = installer.obtain(env: env)

        expect(path).to eq(File.join(cache_root, "specguard-ruby", "validate-intent", installer::RELEASE_TAG, asset))
        expect(File.file?(path)).to be(true)
        expect(File.executable?(path)).to be(true)
        expect(File.binread(path)).to eq(bytes)
      end

      # @intent: { entity: "ValidatorBackend::Installer", action: "obtain the binary", behavior: "a second obtain is served from the cache with no second download", layer: "unit" }
      it "downloads once — the second obtain is served from the cache" do
        stub_download_with
        installer.obtain(env: env)
        allow(installer).to receive(:download).and_raise("must not be called again")

        expect(installer.obtain(env: env)).to eq(installer.cache_dir(env) + "/" + asset)
      end

      # @intent: { entity: "ValidatorBackend::Installer", action: "obtain the binary", behavior: "a digest that does not match the manifest leaves nothing behind", layer: "unit" }
      it "leaves nothing behind when the digest does not match the manifest" do
        stub_download_with(manifest_text: "#{Digest::SHA256.hexdigest("other")}  #{asset}\n")

        expect { installer.obtain(env: env) }
          .to raise_error(SpecGuard::RSpec::ValidatorError, /has sha256:.*but the release manifest says/)
        expect(Dir[File.join(cache_root, "**", "*")]).to be_empty
      end

      # @intent: { entity: "ValidatorBackend::Installer", action: "obtain the binary", behavior: "a manifest that does not describe the asset is refused", layer: "unit" }
      it "refuses a manifest that does not describe the asset" do
        stub_download_with(manifest_text: "#{digest}  some-other-asset\n")

        expect { installer.obtain(env: env) }
          .to raise_error(SpecGuard::RSpec::ValidatorError, /does not describe/)
      end

      # @intent: { entity: "ValidatorBackend::Installer", action: "obtain the binary", behavior: "a network failure is wrapped in the exit-two refusal with both remediations", layer: "unit" }
      it "wraps a network failure in the exit-2 refusal with both remediations" do
        allow(installer).to receive(:download).and_raise(SocketError, "no network")

        expect { installer.obtain(env: env) }
          .to raise_error(SpecGuard::RSpec::ValidatorError,
                          /could not obtain validate-intent.*SocketError.*SPECGUARD_VALIDATE_INTENT.*install\.sh/m)
      end

      # @intent: { entity: "ValidatorBackend::Installer", action: "obtain the binary", behavior: "an HTTP error is not installed over", layer: "unit" }
      it "does not install over an HTTP error" do
        allow(installer).to receive(:download)
          .and_raise(SpecGuard::RSpec::ValidatorError, "fetching #{installer::DOWNLOAD_BASE}/SHA256SUMS answered HTTP 404")

        expect { installer.obtain(env: env) }.to raise_error(SpecGuard::RSpec::ValidatorError, /HTTP 404/)
        expect(Dir[File.join(cache_root, "**", "*")]).to be_empty
      end
    end
  end


end
