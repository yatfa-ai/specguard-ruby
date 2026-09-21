# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"
require_relative "../../support/validator_stub"

RSpec.describe SpecGuard::RSpec::CLI do
  subject(:cli) { described_class.new(stdout: stdout, stderr: stderr) }

  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }

  # SPGD-867: with `SPECGUARD_VALIDATE_INTENT` unset the CLI resolves the
  # validator through the first-run installer. The suite must not download, so
  # resolution is stubbed to the offline replay stub — see
  # spec/support/validator_stub.rb.
  before do
    allow(SpecGuard::RSpec::ValidatorBackend::Installer)
      .to receive(:obtain).and_return(ValidatorStub.install_stubbable)
  end

  def out = stdout.string
  def err = stderr.string

  def git!(*args, chdir:)
    _out, e, status = Open3.capture3("git", *args, chdir: chdir)
    raise "git #{args.join(' ')} failed: #{e}" unless status.success?
  end

  # The exit contract itself lives in spec/specguard/rspec/exit_contract_spec.rb.
  # What is left here is the CLI's *reporting*: which stream each kind of
  # message goes to, and whether it tells the truth about what was checked.
  #
  # NOTE for anyone diffing against slice 1: findings moved from stderr to
  # stdout when validation landed. They are the tool's product, they are where
  # the reference validator puts them, and lint findings conventionally go
  # there. Diagnostics *about the linter* — the empty-selection warning, misuse,
  # a schema that would not load — stay on stderr, and the exit code rather
  # than the stream is now the machine-readable signal.
  describe "honest reporting of what was checked" do
    # "checked 12 files, found no annotations" must never be confusable with
    # "checked 0 files". Reporting the count is what makes them distinguishable.
    # @intent: { entity: "CLI report", action: "state what was checked", behavior: "the report states how many spec files the run checked", layer: "unit" }
    it "states how many files it checked" do
      cli.run([fixture_path("order_spec.rb")])

      expect(out).to include("checked 1 spec file")
    end

    # A recursive fallback (:all) and an explicitly named file (:explicit)
    # checked the same count must not read identically — before the scope
    # clause they were byte-identical, and a silently widened scan (an empty
    # glob expansion) was indistinguishable from "the files you named".
    # @intent: { entity: "CLI report", action: "state what was checked", behavior: "a recursive selection names the directory that was scanned", layer: "unit" }
    it "names the directory a recursive :all selection scanned" do
      Dir.mktmpdir do |dir|
        FileUtils.cp(fixture_path("order_spec.rb"), dir)
        Dir.chdir(dir) { cli.run([]) }
        expect(out).to include("checked 1 spec file under #{dir}")
      end
    end

    # The regression guard: same file count on both sides, different stdout.
    # @intent: { entity: "CLI report", action: "state what was checked", behavior: "an all-files run and an explicit run over the same file count are told apart in the report", layer: "unit" }
    it "distinguishes a :all run from a :explicit run over the same file count" do
      Dir.mktmpdir do |dir|
        FileUtils.cp(fixture_path("order_spec.rb"), dir)
        mk = -> { described_class.new(stdout: StringIO.new, stderr: StringIO.new) }
        run_in = lambda do |argv|
          c = mk.call
          out_line = nil
          Dir.chdir(dir) { c.run(argv); out_line = c.instance_variable_get(:@stdout).string[/^specguard-lint: checked 1 spec file.*$/] }
          out_line
        end
        all_line = run_in.call([])
        explicit_line = run_in.call([File.join(dir, "order_spec.rb")])

        expect(all_line).not_to eq(explicit_line)
        expect(all_line).to eq("specguard-lint: checked 1 spec file under #{dir}")
        expect(explicit_line).to eq("specguard-lint: checked 1 spec file")
      end
    end

    # SPGD-1255: the default walk is fenced out of dependency/build directories
    # (`FileSelector::SKIPPED_DIRECTORIES`), and a fence that actually removed
    # files must say so on the checked-count line — never a silent narrowing.
    # @intent: { entity: "CLI report", action: "state what was checked", behavior: "the all-files checked-count names how many files the directory fence removed", layer: "unit" }
    it "says how many files the default walk fenced out of dependency or build directories" do
      Dir.mktmpdir do |dir|
        FileUtils.cp(fixture_path("order_spec.rb"), dir)
        vendored = File.join(dir, "vendor/bundle/ruby/3.3.0/gems/rspec-core-3.13/spec")
        FileUtils.mkdir_p(vendored)
        File.write(File.join(vendored, "vendored_spec.rb"), "# vendored\n")

        Dir.chdir(dir) { cli.run([]) }

        expect(out).to include(
          "checked 1 spec file under #{dir} skipping 1 in dependency or build directories"
        )
      end
    end

    # The clause is count-gated exactly like `including N untracked`: a fence
    # that removed nothing must leave the line byte-identical to an unfenced
    # walk's, so the disclosure can never be read as an unconditional widening.
    # @intent: { entity: "CLI report", action: "state what was checked", behavior: "an all-files run whose directory fence removed nothing keeps the checked-count byte-identical", layer: "unit" }
    it "does not name the directory fence when it removed nothing" do
      Dir.mktmpdir do |dir|
        FileUtils.cp(fixture_path("order_spec.rb"), dir)
        Dir.chdir(dir) { cli.run([]) }

        expect(out).to include("checked 1 spec file under #{dir}")
        expect(out).not_to include("skipping")
      end
    end

    # An `:all` selection the fence EMPTIED must not blame the tree for
    # holding no spec files: the files existed and the fence removed them.
    # @intent: { entity: "CLI report", action: "warn on an empty selection", behavior: "an empty selection whose files were all fenced names the fence rather than claiming the tree held no specs", layer: "unit" }
    it "names the directory fence when it emptied an otherwise populated tree" do
      Dir.mktmpdir do |dir|
        vendored = File.join(dir, "vendor/bundle/spec")
        FileUtils.mkdir_p(vendored)
        File.write(File.join(vendored, "vendored_spec.rb"), "# vendored\n")

        Dir.chdir(dir) { cli.run([]) }

        expect(err).to include(
          "selected 0 spec files — 1 *_spec.rb or *_test.rb file found, " \
          "all in dependency or build directories"
        )
      end
    end

    # SPGD-1119: files can reach the selection through the untracked leg, and
    # "changed since <base>" alone over-claims provenance for a file the diff
    # never saw. The count names how many came from that leg — exactly the
    # files the run checked through it, nothing more.
    # @intent: { entity: "CLI report", action: "state what was checked", behavior: "the changed-mode checked-count names how many selected files were untracked", layer: "unit" }
    it "says how many selected files were untracked in the changed-mode count" do
      Dir.mktmpdir do |dir|
        git!("init", "-q", "--initial-branch=main", chdir: dir)
        git!("config", "user.email", "t@example.com", chdir: dir)
        git!("config", "user.name", "T", chdir: dir)
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "spec/base_spec.rb"), "# base\n")
        git!("add", "-A", chdir: dir)
        git!("commit", "-q", "-m", "base", chdir: dir)
        git!("checkout", "-q", "-b", "feature", chdir: dir)
        File.write(File.join(dir, "spec/base_spec.rb"), "# edited\n")
        File.write(File.join(dir, "spec/new_untracked_spec.rb"), "# new\n")

        Dir.chdir(dir) { cli.run(["--changed"]) }
      end

      expect(out).to match(/checked 2 spec files changed since \S+ including 1 untracked/)
    end

    # SPGD-1171: the `including N untracked` clause is count-gated
    # (`if untracked.positive?`), so its zero arm — a fully-tracked changed
    # selection, the common CI shape where the diff is entirely committed —
    # must render the clause-free sentence. Every landed changed-mode driver
    # selects exactly one untracked file, so the zero arm shipped undriven and
    # unasserted while the specguard-ts twin pins the same property explicitly
    # ("no clause at all — the line cannot over-claim"). The clause's presence
    # condition is machine-consumed: the bridge forwards this line verbatim as
    # linter_stderr.
    # @intent: { entity: "CLI report", action: "state what was checked", behavior: "a fully-tracked changed selection renders the sentence with no untracked clause at all", layer: "unit" }
    it "renders no untracked clause for a fully-tracked changed selection" do
      base = nil
      Dir.mktmpdir do |dir|
        git!("init", "-q", "--initial-branch=main", chdir: dir)
        git!("config", "user.email", "t@example.com", chdir: dir)
        git!("config", "user.name", "T", chdir: dir)
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "spec/base_spec.rb"), "# base\n")
        git!("add", "-A", chdir: dir)
        git!("commit", "-q", "-m", "base", chdir: dir)
        git!("checkout", "-q", "-b", "feature", chdir: dir)
        File.write(File.join(dir, "spec/base_spec.rb"), "# edited\n")

        base = Open3.capture3("git", "merge-base", "main", "HEAD", chdir: dir).first.strip
        Dir.chdir(dir) { cli.run(["--changed"]) }
      end

      # Byte-exact for the whole sentence: the clause is not merely wrong-but-
      # present, there is no clause at all — the line cannot over-claim.
      line = out.lines.grep(/\Aspecguard-lint: checked .* changed since/).first
      expect(line).to eq("specguard-lint: checked 1 spec file changed since #{base}\n")
      expect(line).not_to include("untracked")
    end

    # SPGD-1267: the fence applies in `--changed` too, and the count-gated
    # disclosure rides the changed-mode sentence exactly as it rides the
    # default walk's. The vendored spec here is COMMITTED — the
    # dependency-bump shape — so the diff leg produced it and `.gitignore`
    # played no part in its removal.
    # @intent: { entity: "CLI report", action: "state what was checked", behavior: "the changed-mode checked-count names how many files the directory fence removed", layer: "unit" }
    it "says how many files the changed selection fenced out of dependency or build directories" do
      base = nil
      Dir.mktmpdir do |dir|
        git!("init", "-q", "--initial-branch=main", chdir: dir)
        git!("config", "user.email", "t@example.com", chdir: dir)
        git!("config", "user.name", "T", chdir: dir)
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "spec/base_spec.rb"), "# base\n")
        git!("add", "-A", chdir: dir)
        git!("commit", "-q", "-m", "base", chdir: dir)
        git!("checkout", "-q", "-b", "feature", chdir: dir)
        File.write(File.join(dir, "spec/base_spec.rb"), "# edited\n")
        vendored = File.join(dir, "vendor/bundle/ruby/3.3.0/gems/rspec-core-3.13/spec")
        FileUtils.mkdir_p(vendored)
        File.write(File.join(vendored, "vendored_spec.rb"), "# vendored\n")
        git!("add", "-A", chdir: dir)
        git!("commit", "-q", "-m", "bundle update", chdir: dir)

        base = Open3.capture3("git", "merge-base", "main", "HEAD", chdir: dir).first.strip
        Dir.chdir(dir) { cli.run(["--changed"]) }
      end

      line = out.lines.grep(/\Aspecguard-lint: checked .* changed since/).first
      expect(line).to eq(
        "specguard-lint: checked 1 spec file changed since #{base} " \
        "skipping 1 in dependency or build directories\n"
      )
    end

    # The SPGD-1118 shape in this mode: a fence that EMPTIES a changed
    # selection must name the fence, not fall through to a confidently wrong
    # "nothing changed" — the files changed, and the fence removed them.
    # @intent: { entity: "CLI", action: "explain an empty changed selection", behavior: "an empty changed selection whose every match was fenced names the fence rather than claiming nothing changed", layer: "unit" }
    it "names the directory fence when it empties a changed selection" do
      base = nil
      Dir.mktmpdir do |dir|
        git!("init", "-q", "--initial-branch=main", chdir: dir)
        git!("config", "user.email", "t@example.com", chdir: dir)
        git!("config", "user.name", "T", chdir: dir)
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "spec/base_spec.rb"), "# base\n")
        git!("add", "-A", chdir: dir)
        git!("commit", "-q", "-m", "base", chdir: dir)
        git!("checkout", "-q", "-b", "feature", chdir: dir)
        vendored = File.join(dir, "vendor/bundle/ruby/3.3.0/gems/rspec-core-3.13/spec")
        FileUtils.mkdir_p(vendored)
        File.write(File.join(vendored, "vendored_spec.rb"), "# vendored\n")
        git!("add", "-A", chdir: dir)
        git!("commit", "-q", "-m", "bundle update", chdir: dir)

        base = Open3.capture3("git", "merge-base", "main", "HEAD", chdir: dir).first.strip
        Dir.chdir(dir) { cli.run(["--changed"]) }
      end

      expect(err).to include(
        "selected 0 spec files — 1 changed spec file against #{base}, " \
        "all in dependency or build directories"
      )
      expect(err).not_to include("nothing changed against")
    end

    # The reason ladder keeps its truth: "nothing changed against <base>" can
    # now only fire when nothing tracked changed AND no untracked spec exists.
    # A branch whose only spec is a brand-new untracked file gets checked, not
    # explained away with a confidently wrong reason.
    # @intent: { entity: "CLI", action: "explain an empty changed selection", behavior: "an untracked-only working tree is checked rather than reported as nothing having changed", layer: "unit" }
    it "never says nothing changed when the branch's only spec is untracked" do
      Dir.mktmpdir do |dir|
        git!("init", "-q", "--initial-branch=main", chdir: dir)
        git!("config", "user.email", "t@example.com", chdir: dir)
        git!("config", "user.name", "T", chdir: dir)
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "spec/base_spec.rb"), "# base\n")
        git!("add", "-A", chdir: dir)
        git!("commit", "-q", "-m", "base", chdir: dir)
        git!("checkout", "-q", "-b", "feature", chdir: dir)
        File.write(File.join(dir, "spec/brand_new_spec.rb"), "# new\n")

        Dir.chdir(dir) { cli.run(["--changed"]) }
      end

      expect(out).to include("checked 1 spec file changed since")
      expect(err).not_to include("nothing changed against")
    end

    # @intent: { entity: "CLI report", action: "warn on an empty selection", behavior: "an empty selection warns loudly on stderr instead of passing silently", layer: "unit" }
    it "warns loudly on stderr when the selection is empty" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { cli.run([]) }
      end

      expect(err).to include("warning", "selected 0 spec files")
    end

    # @intent: { entity: "CLI report", action: "warn on an empty selection", behavior: "the empty-selection warning stays off stdout so a pipe cannot swallow it", layer: "unit" }
    it "does not put the empty-selection warning on stdout, where it could be piped away" do
      Dir.mktmpdir { |dir| Dir.chdir(dir) { cli.run([]) } }

      expect(out).not_to include("warning")
    end

    # @intent: { entity: "CLI report", action: "warn on an empty selection", behavior: "a misuse is reported on stderr rather than crashing the process", layer: "unit" }
    it "reports a misuse on stderr rather than crashing" do
      Dir.mktmpdir do |dir|
        Dir.chdir(dir) { cli.run(["--changed"]) }
      end

      expect(err).to include("--changed requires a git repository")
    end

    # @intent: { entity: "CLI report", action: "summarise the run", behavior: "the summary states how many annotations were checked and how many were malformed", layer: "unit" }
    it "summarises how many annotations it checked and how many failed" do
      cli.run([fixture_path("broken_intent_spec.rb")])

      expect(out).to include("checked 5 @intent annotations, 5 malformed")
    end

    # An annotation-free run states its zero explicitly. Silence would be
    # indistinguishable from "the linter never ran".
    # @intent: { entity: "CLI report", action: "summarise the run", behavior: "a checked file carrying no annotations still states the zero rather than omitting the summary", layer: "unit" }
    it "states the zero when a checked file carries no annotations" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "bare_spec.rb")
        File.write(path, "RSpec.describe(Order) { it('works') {} }\n")
        cli.run([path])
      end

      expect(out).to include("checked 0 @intent annotations, 0 malformed")
    end

    # @intent: { entity: "CLI report", action: "print findings", behavior: "each malformed annotation is printed at its own file and line location", layer: "unit" }
    it "prints each malformed annotation at its own file:line" do
      cli.run([fixture_path("broken_intent_spec.rb")])

      expect(out).to include(":28 — unterminated object literal")
      expect(out).to include(":34 — no '{...}' object literal")
    end

    # @intent: { entity: "CLI report", action: "print findings", behavior: "a fully valid run prints nothing per-annotation, leaving the summary as the only stdout line", layer: "unit" }
    it "prints nothing per-annotation when every annotation is valid" do
      cli.run([fixture_path("order_spec.rb")])

      expect(out).not_to include("FAIL")
      expect(out).to include("checked 7 @intent annotations, 0 malformed")
    end

    # REMOVED at SPGD-867: the adopted-payload regression (SPGD-512) used to
    # be pinned here through a hand-written temp file on the Ruby path. The CLI
    # validates through the binary now, so the exit-code half of that pin is
    # owned by the binary's own suite; the scanner-bound half — the part this
    # gem still owns — stays pinned in annotation_scanner_spec.rb.
  end

  # The zero-annotation coverage note: `specguard-lint` already knows which of
  # the files it checked carry no `@intent` annotations — zero findings is
  # otherwise ambiguous between "every checked file annotated and valid" and
  # "half the checked files carry nothing", and the bridge (which serves
  # `--json` exclusively and forwards stderr verbatim) has no other view into
  # the repository's spec files. The note is stderr prose exactly because a
  # missing annotation is a coverage fact, not a lint failure (SPGD-12 §1):
  # exit codes, stdout and the document stay byte-identical.
  describe "the zero-annotation coverage note" do
    def write_annotated(path)
      File.write(path, <<~RUBY)
        # @intent: { entity: "Order", action: "total", behavior: "sums line totals into the order total", layer: "unit" }
        RSpec.describe(Order) { it('totals') { expect(1).to eq(1) } }
      RUBY
    end

    def write_bare(path)
      File.write(path, "RSpec.describe(Order) { it('works') { expect(1).to eq(1) } }\n")
    end

    # @intent: { entity: "CLI report", action: "name annotation-free files", behavior: "a mixed selection names the bare files on stderr in human mode and none that is annotated", layer: "unit" }
    it "names the read-but-unannotated files on stderr in human mode, and none that is annotated" do
      Dir.mktmpdir do |dir|
        annotated = File.join(dir, "annotated_spec.rb")
        bare = File.join(dir, "bare_spec.rb")
        write_annotated(annotated)
        write_bare(bare)

        code = cli.run([annotated, bare])

        expect(code).to eq(described_class::EXIT_OK)
        expect(err).to include(
          "specguard-lint: note: 1 of 2 checked spec files carries no @intent annotations: #{bare}"
        )
        expect(err).not_to include(annotated)
      end
    end

    # @intent: { entity: "CLI report", action: "name annotation-free files", behavior: "the note reaches stderr in json mode too while the document's shape and counts stay untouched", layer: "unit" }
    it "names them on stderr in json mode too, leaving the document untouched" do
      Dir.mktmpdir do |dir|
        annotated = File.join(dir, "annotated_spec.rb")
        bare = File.join(dir, "bare_spec.rb")
        write_annotated(annotated)
        write_bare(bare)

        code = cli.run(["--json", annotated, bare])

        expect(code).to eq(described_class::EXIT_OK)
        expect(err).to include(
          "specguard-lint: note: 1 of 2 checked spec files carries no @intent annotations: #{bare}"
        )
        document = JSON.parse(out)
        expect(document).to include(
          "ok" => true,
          "summary" => { "files" => 2, "annotations" => 1, "failed" => 0 }
        )
        expect(document["findings"].map { |f| f["file"] }).to eq([annotated])
      end
    end

    # SPGD-1163: the singular arm of the note is the one the landed pins never
    # reach — every assertion above selects two files, so the noun ternary's
    # `file#{'s' unless selected_files.length == 1}` singular form
    # ("1 of 1 checked spec file carries") had no assertion. The pre-SPGD-1159
    # "states the zero" example drives exactly this invocation (one bare file
    # through `cli.run([path])`) and asserts stdout only, so the singular
    # bytes were machine-observable contract — the specguard-mcp bridge
    # forwards stderr verbatim as `linter_stderr` — pinned nowhere. These two
    # examples pin the form byte-exactly, line end included, in both
    # renderers.
    # @intent: { entity: "CLI report", action: "name annotation-free files", behavior: "a single bare file renders the note singular — 1 of 1 checked spec file carries — byte-exactly in human mode", layer: "unit" }
    it "renders the note singular for a one-file selection in human mode" do
      Dir.mktmpdir do |dir|
        bare = File.join(dir, "bare_spec.rb")
        write_bare(bare)

        code = cli.run([bare])

        expect(code).to eq(described_class::EXIT_OK)
        expect(err).to include(
          "specguard-lint: note: 1 of 1 checked spec file carries no @intent annotations: #{bare}\n"
        )
      end
    end

    # @intent: { entity: "CLI report", action: "name annotation-free files", behavior: "the singular note reaches stderr in json mode too while the document keeps its one-file zero-annotation shape", layer: "unit" }
    it "renders the note singular in json mode too, leaving the document untouched" do
      Dir.mktmpdir do |dir|
        bare = File.join(dir, "bare_spec.rb")
        write_bare(bare)

        code = cli.run(["--json", bare])

        expect(code).to eq(described_class::EXIT_OK)
        expect(err).to include(
          "specguard-lint: note: 1 of 1 checked spec file carries no @intent annotations: #{bare}\n"
        )
        document = JSON.parse(out)
        expect(document).to include(
          "ok" => true,
          "summary" => { "files" => 1, "annotations" => 0, "failed" => 0 }
        )
        expect(document["findings"]).to eq([])
      end
    end

    # Byte-stability: a fully annotated run's stderr is exactly what it was —
    # the provenance line alone. Any extra line there would leak into every
    # byte-locked consumer (regression_targets_spec.rb, validator_backend
    # parity).
    # @intent: { entity: "CLI report", action: "name annotation-free files", behavior: "a fully annotated selection emits no note, leaving stderr exactly the provenance line", layer: "unit" }
    it "adds no note when every checked file carries an annotation" do
      Dir.mktmpdir do |dir|
        first = File.join(dir, "first_spec.rb")
        second = File.join(dir, "second_spec.rb")
        write_annotated(first)
        write_annotated(second)

        code = cli.run([first, second])

        expect(code).to eq(described_class::EXIT_OK)
        expect(err.lines.length).to eq(1)
        expect(err.lines.first).to start_with("specguard-lint: validated by ")
        expect(err).not_to include("note:")
      end
    end

    # An unread file is not a zero-annotation file: the run could not look
    # inside it, and the unread clause plus its line-less FAIL already report
    # it. Naming it annotation-free would overstate exactly the way the
    # summary count refuses to.
    # @intent: { entity: "CLI report", action: "name annotation-free files", behavior: "an unread file is never named by the note, which keeps naming the bare file it was checked alongside", layer: "unit" }
    it "never names an unread file — the unread clause stays its only reporter" do
      Dir.mktmpdir do |dir|
        bare = File.join(dir, "bare_spec.rb")
        gone = File.join(dir, "gone_spec.rb")
        write_bare(bare)

        code = cli.run([bare, gone])

        expect(code).to eq(described_class::EXIT_MALFORMED)
        expect(err).to include(
          "specguard-lint: note: 1 of 2 checked spec files carries no @intent annotations: #{bare}"
        )
        expect(err).not_to include(gone)
        expect(out).to include("FAIL  #{gone} — could not read file")
        expect(out).to include("checked 0 @intent annotations, 0 malformed; 1 file could not be read")
      end
    end
  end

  # SPGD-900: the stacked-annotation structural pass. Two consecutive
  # comment-form `@intent:` lines above one `it` leave the upper line
  # unreachable to the one-line lookback (SPGD-12 §2) — dead metadata the
  # linter previously counted as a valid annotation and exited 0 over.
  describe "unreachable stacked @intent: annotations" do
    def write_spec(dir, body, name: "order_spec.rb")
      path = File.join(dir, name)
      File.write(path, body)
      path
    end

    # @intent: { entity: "CLI report", action: "flag stacked annotations", behavior: "a stacked comment pair exits one and names the upper line as its own finding at its file and line", layer: "unit" }
    it "exits 1 and names the UPPER line's file:line for a stacked pair" do
      Dir.mktmpdir do |dir|
        path = write_spec(dir, <<~RUBY)
          # @intent: { entity: "Order", action: "checkout", behavior: "decrements the order stock", layer: "request" }
          # @intent: { entity: "Refund", action: "issue", behavior: "restocks the refunded items", layer: "request" }
          it "restores stock on refund" do
            expect(order.stock).to eq(3)
          end
        RUBY

        code = cli.run([path])
        expect(code).to eq(1)
        expect(out).to include("FAIL  #{path}:1")
        expect(out).not_to include("#{path}:2")
        expect(out).to include("unreachable annotation")
      end
    end

    # @intent: { entity: "CLI report", action: "flag stacked annotations", behavior: "the canonical one comment above one example form still exits zero", layer: "unit" }
    it "still exits 0 for the canonical one-comment-above-one-it form" do
      Dir.mktmpdir do |dir|
        path = write_spec(dir, <<~RUBY)
          # @intent: { entity: "Order", action: "checkout", behavior: "decrements the order stock", layer: "request" }
          it "decrements stock" do
            expect(order.stock).to eq(2)
          end
        RUBY

        expect(cli.run([path])).to eq(0)
        expect(out).not_to include("FAIL")
      end
    end

    # @intent: { entity: "CLI report", action: "flag stacked annotations", behavior: "adjacent one-liners carrying same-line annotations are not flagged as stacked", layer: "unit" }
    it "does not flag trailing same-line annotations on adjacent one-liners" do
      Dir.mktmpdir do |dir|
        path = write_spec(dir, <<~RUBY)
          it { is_expected.to eq(1) } # @intent: { entity: "Alpha", action: "act", behavior: "does the thing under test", layer: "request" }
          it { is_expected.to be_positive } # @intent: { entity: "Beta", action: "act", behavior: "does the thing under test", layer: "request" }
        RUBY

        expect(cli.run([path])).to eq(0)
        expect(out).not_to include("FAIL")
      end
    end

    # @intent: { entity: "CLI report", action: "flag stacked annotations", behavior: "the unreachable kind carries through the json renderer and the run still exits one", layer: "unit" }
    it "carries the unreachable kind through --json and still exits 1" do
      Dir.mktmpdir do |dir|
        path = write_spec(dir, <<~RUBY)
          # @intent: { entity: "Alpha", action: "act", behavior: "does the thing under test", layer: "request" }
          # @intent: { entity: "Beta", action: "act", behavior: "does the thing under test", layer: "request" }
          it "works" do end
        RUBY

        code = cli.run(["--json", path])
        expect(code).to eq(1)

        document = JSON.parse(out)
        expect(document["ok"]).to be(false)
        failed = document["findings"].select { |f| !f["ok"] }
        expect(failed.length).to eq(1)
        expect(failed.first["kind"]).to eq("unreachable")
        expect(failed.first["line"]).to eq(1)
        expect(failed.first["file"]).to eq(path)
      end
    end

    # @intent: { entity: "CLI report", action: "flag stacked annotations", behavior: "a run with no stacked pairs keeps the ordinary zero one two exit contract untouched", layer: "unit" }
    it "leaves the 0/1/2 exit contract untouched for a run with no stacked pairs" do
      # Canonical fixtures, recorded real-binary verdicts: exit 0 file stays 0,
      # broken file stays 1 with its own kinds, nothing gains a finding.
      expect(cli.run([fixture_path("order_spec.rb")])).to eq(0)
      expect(cli.run([fixture_path("broken_intent_spec.rb")])).to eq(1)
      expect(out).not_to include("unreachable")
    end
  end


  describe "options" do
    # @intent: { entity: "specguard-lint options", action: "print the version", behavior: "the version flag prints the gem version and exits without linting", layer: "unit" }
    it "prints the version" do
      expect(cli.run(["--version"])).to eq(0)
      expect(out).to include("specguard-ruby #{SpecGuard::VERSION}")
    end

    # @intent: { entity: "specguard-lint options", action: "print usage", behavior: "the help flag prints the usage text and exits cleanly", layer: "unit" }
    it "prints usage" do
      cli.run(["--help"])

      expect(out).to include("Usage: specguard-lint")
    end

    # @intent: { entity: "specguard-lint options", action: "print the version", behavior: "a version-only run scans nothing on its way to the exit", layer: "unit" }
    it "does not scan anything when only printing the version" do
      cli.run(["--version"])

      expect(out).not_to include("checked")
    end

    # SPGD-867: `--require-validator` is GONE — its assertion is now
    # always-on (a run that cannot resolve a validator exits 2 outright), so
    # the flag has no meaning left and passing it is a usage error rather
    # than a silently-unasserted no-op.
    # @intent: { entity: "specguard-lint options", action: "retire removed flags", behavior: "the removed validator flag is refused as the unknown flag it now is", layer: "unit" }
    it "refuses --require-validator as the unknown flag it now is" do
      expect(cli.run(["--require-validator", fixture_path("order_spec.rb")])).to eq(2)
      expect(err).to include("invalid option")
    end
  end

  # `--json` is the second renderer over the same Array<Linter::Result> the text
  # report is built from (SPGD-305). What is asserted here is what a CONSUMER
  # depends on: that stdout is one document and nothing else, that every field
  # the Result carries survives — `kind` above all, the field the prose renderer
  # destroys — and that `errors` is always a list so nobody has to branch on its
  # type. The exit-code half of the contract lives in exit_contract_spec.rb, and
  # the proof that the default path did not move lives in
  # regression_targets_spec.rb.
  describe "--json" do
    def run_json(*argv)
      cli.run(["--json", *argv])
      JSON.parse(out)
    end

    def findings_for(*argv) = run_json(*argv).fetch("findings")

    # @intent: { entity: "CLI json renderer", action: "emit one document", behavior: "the json flag produces exactly one JSON document on stdout", layer: "unit" }
    it "emits exactly one JSON document on stdout" do
      run_json(fixture_path("broken_intent_spec.rb"))

      expect { JSON.parse(out) }.not_to raise_error
      expect(out.scan(/^\{$/).length).to eq(1)
    end

    # The prose renderer's whole output has to LEAVE, not be joined by a
    # document. A consumer piping stdout into a parser gets a syntax error the
    # moment either survives.
    # @intent: { entity: "CLI json renderer", action: "emit one document", behavior: "none of the human report leaks onto stdout in json mode", layer: "unit" }
    it "puts none of the human report on stdout" do
      run_json(fixture_path("broken_intent_spec.rb"))

      expect(out).not_to include("FAIL")
      expect(out).not_to include("malformed")
    end

    # There are TWO `checked …` lines, not one — a leading spec-file count from
    # #report_selection and a trailing annotation count from #summary_line. The
    # open-test-intent's own linter warns that handling only
    # the trailing one is the trap here, so both are asserted gone.
    # @intent: { entity: "CLI json renderer", action: "emit one document", behavior: "both checked-count lines are removed in json mode, the leading one included", layer: "unit" }
    it "removes BOTH `checked ...` lines, the leading one as well as the trailing" do
      run_json(fixture_path("order_spec.rb"))

      expect(out).not_to include("checked")
    end

    # Neither line is LOST, though: the leading count becomes summary.files and
    # the trailing one summary.annotations, computed once by the CLI and handed
    # to whichever renderer runs. A document that quietly dropped them would let
    # "checked nothing" read as "all clean" — in structured form.
    # @intent: { entity: "CLI json renderer", action: "emit one document", behavior: "the file and annotation counts move into the document summary rather than being dropped", layer: "unit" }
    it "carries both counts into the document instead of dropping them" do
      report = run_json(fixture_path("order_spec.rb"), fixture_path("broken_intent_spec.rb"))

      expect(report["summary"]).to eq("files" => 2, "annotations" => 12, "failed" => 5)
    end

    # @intent: { entity: "CLI json renderer", action: "declare the protocol", behavior: "the document names the protocol it validated against and the mode the port calls this", layer: "unit" }
    it "names the protocol it validated against, and the mode the port calls this" do
      report = run_json(fixture_path("order_spec.rb"))

      expect(report["schema"]).to eq("open-test-intent.v1.json")
      expect(report["mode"]).to eq("source")
    end

    # The document must not be able to name a schema the gem does not carry.
    # @intent: { entity: "CLI json renderer", action: "declare the protocol", behavior: "the document declares the schema revision the gem actually vendors", layer: "unit" }
    it "declares the schema it actually vendors" do
      expect(SpecGuard::RSpec::JSONReporter::SCHEMA_ID)
        .to eq(File.basename(SpecGuard::RSpec::SCHEMA_PATH))
    end

    describe "every Linter::Result field survives the renderer" do
      # The four kinds, each reached the way a user reaches it. `kind` is
      # carried precisely because "a failed extraction and an unparseable
      # payload both land in `problem`, which makes the two indistinguishable
      # downstream once flattened to prose" (Finding) — so a renderer that
      # dropped it would leave the document no better than the prose.
      def kinds_in(dir)
        File.write(File.join(dir, "extraction_spec.rb"), "# @intent:\n")
        File.write(File.join(dir, "parse_spec.rb"), "# @intent: {layer: request}\n")
        File.write(File.join(dir, "schema_spec.rb"),
                   %(# @intent: { entity: "Order", action: "total", behavior: "sums", layer: "unit" }\n))
        %w[extraction_spec.rb parse_spec.rb schema_spec.rb].map { |name| File.join(dir, name) } +
          [File.join(dir, "gone_spec.rb")]
      end

      # @intent: { entity: "CLI json renderer", action: "preserve result fields", behavior: "a finding of each of the four kinds carries its kind through the document", layer: "unit" }
      it "sets `kind` on a finding of each of the four kinds" do
        findings = findings_for(fixture_path("broken_intent_spec.rb"), File.join(Dir.mktmpdir, "gone_spec.rb"))

        # Recorded kinds: schema (9/15/21), extraction (28/34), and the
        # `no-match`-mapped read of the missing file. A genuine `parse` kind
        # is pinned by the acceptance-set recordings in
        # validator_backend_spec.rb.
        expect(findings.map { |finding| finding["kind"] }.compact.uniq)
          .to contain_exactly("extraction", "schema", "read")
        expect(findings.last["kind"]).to eq("read")
      end

      # `:0` is not somewhere a reader can go. The text renderer already drops
      # it (Linter::Result#location); the document has to drop it too, or every
      # CI annotation and editor quickfix built on this points at a line that
      # does not exist.
      # @intent: { entity: "CLI json renderer", action: "preserve result fields", behavior: "a read failure is given a null line rather than the zero sentinel", layer: "unit" }
      it "gives a read failure a null line rather than the 0 sentinel" do
        Dir.mktmpdir do |dir|
          finding = findings_for(File.join(dir, "gone_spec.rb")).first

          expect(finding["line"]).to be_nil
          expect(finding).to include("ok" => false, "kind" => "read")
        end
      end

      # @intent: { entity: "CLI json renderer", action: "preserve result fields", behavior: "findings that have a line number keep it through the document", layer: "unit" }
      it "keeps the line number on findings that have one" do
        finding = findings_for(fixture_path("broken_intent_spec.rb")).first

        expect(finding["line"]).to eq(9)
      end

      # @intent: { entity: "CLI json renderer", action: "preserve result fields", behavior: "the file path is echoed back exactly as it was given on the command line", layer: "unit" }
      it "echoes the file path back exactly as it was given" do
        Dir.mktmpdir do |dir|
          path = File.join(dir, "gone_spec.rb")

          expect(findings_for(path).first["file"]).to eq(path)
        end
      end

      # @intent: { entity: "CLI json renderer", action: "preserve result fields", behavior: "a passing annotation is reported as a finding with no kind set", layer: "unit" }
      it "reports a passing annotation as a finding with no kind" do
        finding = findings_for(fixture_path("order_spec.rb")).first

        expect(finding).to include("ok" => true, "kind" => nil, "errors" => [])
      end
    end

    # `JSONFinding` (open-test-intent, `cmd/validate-intent/report.go`) is
    # explicit that a consumer must never have to branch on the type of
    # `errors`. The gem's Result keeps `problem` (one sentence) and `reasons`
    # (a list) mutually exclusive, so this is the one place the two collapse —
    # and the collapse must not leak either shape.
    describe "`errors` is always a list of strings" do
      # @intent: { entity: "CLI json renderer", action: "shape the errors list", behavior: "every schema reason for a finding is carried, not only the first", layer: "unit" }
      it "carries every schema reason, not the first" do
        errors = findings_for(fixture_path("broken_intent_spec.rb")).first["errors"]

        expect(errors).to eq([
                               "<root>: missing required property 'entity'",
                               "<root>: additional property 'entiity' is not allowed"
                             ])
      end

      # @intent: { entity: "CLI json renderer", action: "shape the errors list", behavior: "a single problem sentence is wrapped in a list instead of emitted as a bare string", layer: "unit" }
      it "wraps a single `problem` sentence in a list rather than emitting a bare string" do
        finding = findings_for(fixture_path("broken_intent_spec.rb")).find { |f| f["line"] == 34 }

        expect(finding["kind"]).to eq("extraction")
        expect(finding["errors"]).to eq(["no '{...}' object literal follows the @intent: token"])
      end

      # @intent: { entity: "CLI json renderer", action: "shape the errors list", behavior: "a passing finding reports an empty errors list, never null", layer: "unit" }
      it "is an empty list, never null, on a passing finding" do
        findings = findings_for(fixture_path("order_spec.rb"))

        expect(findings.map { |finding| finding["errors"] }).to all(eq([]))
      end
    end

    # README.md:65-67 claims this document is "key-, type- and value-identical"
    # to `validate-intent --source --json`. The port grew an `intent` key
    # (SPGD-340) carrying WHAT THE PAYLOAD PARSED TO, so this renderer has to
    # grow it too or that claim quietly stops being true — and it would stop
    # being true in the direction nobody notices, since a consumer reading the
    # port's document and then this one finds a key missing rather than wrong.
    describe "`intent` — what the payload parsed to" do
      # @intent: { entity: "CLI json renderer", action: "carry the intent", behavior: "a passing finding carries the parsed annotation in the document", layer: "unit" }
      it "carries the parsed annotation on a passing finding" do
        finding = findings_for(fixture_path("order_spec.rb")).first

        expect(finding["intent"]).to include(
          "entity" => "Order", "action" => "checkout", "layer" => "request"
        )
      end

      # Same rule as the port's: `ok` says whether it is good, `intent` says
      # what it is, and a schema-rejected annotation still says something.
      # @intent: { entity: "CLI json renderer", action: "carry the intent", behavior: "a schema-rejected finding carries its parsed payload too, alongside the reasons", layer: "unit" }
      it "carries it on a schema-rejected finding too" do
        finding = findings_for(fixture_path("broken_intent_spec.rb")).first

        expect(finding["ok"]).to be(false)
        expect(finding["kind"]).to eq("schema")
        expect(finding["intent"]).to be_a(Hash)
      end

      # @intent: { entity: "CLI json renderer", action: "carry the intent", behavior: "a finding with no payload reports null for the intent, the key still present", layer: "unit" }
      it "is null, and present, where there was no payload" do
        finding = findings_for(fixture_path("broken_intent_spec.rb"))[3]

        expect(finding).to have_key("intent")
        expect(finding["intent"]).to be_nil
      end

      # Key ORDER, not just presence: the claim is key-for-key with a document
      # whose order is positional, and Ruby preserves insertion order, so this
      # is assertable rather than merely hoped for.
      # @intent: { entity: "CLI json renderer", action: "carry the intent", behavior: "intent is the last key of its finding, matching the port field order", layer: "unit" }
      it "is the last key, matching the port's order" do
        finding = findings_for(fixture_path("order_spec.rb")).first

        expect(finding.keys).to eq(%w[file line ok kind errors intent])
      end
    end

    describe "the document's own consistency" do
      # `ok` is derived from the exit code the text path would also have
      # produced rather than recomputed from the findings, following `Emit`
      # (open-test-intent, `cmd/validate-intent/report.go`), so the two
      # renderers cannot disagree about the verdict.
      # @intent: { entity: "CLI json renderer", action: "stay self-consistent", behavior: "the document ok flag mirrors the exit code the same run returns", layer: "unit" }
      it "mirrors the exit code in `ok`" do
        expect(cli.run(["--json", fixture_path("order_spec.rb")])).to eq(0)
        expect(JSON.parse(out)["ok"]).to be(true)
      end

      # @intent: { entity: "CLI json renderer", action: "stay self-consistent", behavior: "a run that exits one reports ok false in the document", layer: "unit" }
      it "reports ok: false for the run that exits 1" do
        expect(cli.run(["--json", fixture_path("broken_intent_spec.rb")])).to eq(1)
        expect(JSON.parse(out)["ok"]).to be(false)
      end

      # summary.failed counts every failing FINDING — read failures included,
      # as the port's Emit does — so it always equals the number of entries a
      # consumer would find with "ok" => false. It is deliberately NOT the text
      # summary's "M malformed", which excludes unread files and reports them in
      # its own clause.
      # @intent: { entity: "CLI json renderer", action: "stay self-consistent", behavior: "the summary failed count equals the number of failing findings in the document", layer: "unit" }
      it "makes summary.failed equal the number of failing findings" do
        Dir.mktmpdir do |dir|
          report = run_json(fixture_path("broken_intent_spec.rb"), File.join(dir, "gone_spec.rb"))

          expect(report.dig("summary", "failed"))
            .to eq(report["findings"].count { |finding| finding["ok"] == false })
          expect(report.dig("summary", "failed")).to eq(6)
        end
      end

      # An unreadable file contributed no annotation site, in the document for
      # the same reason it gets its own clause in the text summary: counting it
      # would report annotations that were never read.
      # @intent: { entity: "CLI json renderer", action: "stay self-consistent", behavior: "an unread file is not counted as an annotation site in the summary", layer: "unit" }
      it "does not count an unread file as an annotation site" do
        Dir.mktmpdir do |dir|
          report = run_json(File.join(dir, "a_spec.rb"), File.join(dir, "b_spec.rb"))

          expect(report["summary"]).to eq("files" => 2, "annotations" => 0, "failed" => 2)
        end
      end
    end

    # Diagnostics about the linter itself do not move: the SPGD-247 provenance
    # line and every warning stay on stderr, byte for byte. SPGD-1134 joins
    # them on the same terms — the selection provenance sentence, which the
    # human report reads on stdout, rides stderr under `--json` too. `--json`
    # changes the STREAM of that line, never its content: a document on stdout
    # is a report about the CODE, not a reason to drop the one sentence that
    # says what was selected.
    describe "stderr is untouched" do

      # @intent: { entity: "CLI json renderer", action: "leave stderr intact", behavior: "json mode writes exactly one provenance line naming the implementation plus the selection line naming what was checked", layer: "unit" }
      it "still writes exactly one provenance line naming the implementation" do
        described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--json", fixture_path("order_spec.rb")])

        expect(err.lines.length).to eq(2)
        expect(err.lines.first).to start_with("specguard-lint: validated by validate-intent 0.1.4")
        expect(err).to include("(SPECGUARD_VALIDATE_INTENT)")
        expect(err.lines.last).to eq("specguard-lint: checked 1 spec file\n")
      end

      # SPGD-1134: a json-mode changed run must name its provenance — the base
      # actually diffed against and how many selected files arrived untracked —
      # or the machine channel cannot verify the diff ∪ untracked union at
      # all. The bridge forwards stderr verbatim, so its agent reads this
      # sentence instead of doing arithmetic on `summary.files`; stdout stays
      # one document and nothing else.
      # @intent: { entity: "CLI json renderer", action: "carry the selection provenance", behavior: "a json-mode changed run states the checked count, resolved base and untracked leg on stderr while stdout stays one clean document", layer: "unit" }
      it "carries the selection sentence, base and untracked count included, on stderr in json mode" do
        bare_files = nil
        Dir.mktmpdir do |dir|
          git!("init", "-q", "--initial-branch=main", chdir: dir)
          git!("config", "user.email", "t@example.com", chdir: dir)
          git!("config", "user.name", "T", chdir: dir)
          FileUtils.mkdir_p(File.join(dir, "spec"))
          File.write(File.join(dir, "spec/base_spec.rb"), "# base\n")
          git!("add", "-A", chdir: dir)
          git!("commit", "-q", "-m", "base", chdir: dir)
          git!("checkout", "-q", "-b", "feature", chdir: dir)
          File.write(File.join(dir, "spec/base_spec.rb"), "# edited\n")
          File.write(File.join(dir, "spec/new_untracked_spec.rb"), "# new\n")

          code = 0
          Dir.chdir(dir) { code = cli.run(["--json", "--changed"]) }

          expect(code).to eq(described_class::EXIT_OK)
          # Changed-mode selections name their files relative to the working
          # directory, and the note echoes paths exactly as they were checked.
          bare_files = ["spec/base_spec.rb", "spec/new_untracked_spec.rb"]
        end

        expect(err).to match(/checked 2 spec files changed since \S+ including 1 untracked/)
        # Exactly one checked-line reaches stderr — the selection sentence
        # itself; the provenance line names no count and no warning fires.
        expect(err.lines.grep(/specguard-lint: checked/).length).to eq(1)
        # SPGD-1159: the selection's fixture files are both annotation-free,
        # so the coverage note fires here too — naming both bare files and
        # neither of anything else. The grep above cannot match it (the note's
        # prefix is `specguard-lint: note:`), stdout stays one document, and
        # this turns the interaction into coverage rather than collateral.
        expect(err).to include(
          "specguard-lint: note: 2 of 2 checked spec files carry no @intent annotations: " \
          "#{bare_files.join(', ')}"
        )
        expect(out).not_to include("checked")
        expect { JSON.parse(out) }.not_to raise_error
        expect(out.scan(/^\{$/).length).to eq(1)
      end

      # SPGD-1171: the zero arm of the same clause, on the machine channel.
      # The bridge forwards stderr verbatim as linter_stderr, so a tracked-only
      # changed run — every selected file from the diff, none untracked — must
      # reach its agent as the clause-free sentence; a leaked clause would
      # have the machine reading an untracked leg that never fired. Byte-exact
      # against the resolved merge base, mirroring the twin's explicit absence
      # pin ("no clause at all — the line cannot over-claim").
      # @intent: { entity: "CLI json renderer", action: "carry the selection provenance", behavior: "a json-mode fully-tracked changed run states the sentence on stderr with no untracked clause", layer: "unit" }
      it "carries the tracked-only changed sentence clause-free on stderr in json mode" do
        base = nil
        Dir.mktmpdir do |dir|
          git!("init", "-q", "--initial-branch=main", chdir: dir)
          git!("config", "user.email", "t@example.com", chdir: dir)
          git!("config", "user.name", "T", chdir: dir)
          FileUtils.mkdir_p(File.join(dir, "spec"))
          File.write(File.join(dir, "spec/base_spec.rb"), "# base\n")
          git!("add", "-A", chdir: dir)
          git!("commit", "-q", "-m", "base", chdir: dir)
          git!("checkout", "-q", "-b", "feature", chdir: dir)
          File.write(File.join(dir, "spec/base_spec.rb"), "# edited\n")

          base = Open3.capture3("git", "merge-base", "main", "HEAD", chdir: dir).first.strip
          Dir.chdir(dir) { cli.run(["--json", "--changed"]) }
        end

        line = err.lines.grep(/\Aspecguard-lint: checked .* changed since/).first
        expect(line).to eq("specguard-lint: checked 1 spec file changed since #{base}\n")
        expect(line).not_to include("untracked")
        expect(out).not_to include("checked")
        expect { JSON.parse(out) }.not_to raise_error
      end

      # @intent: { entity: "CLI json renderer", action: "leave stderr intact", behavior: "the loud empty-selection warning still reaches stderr in json mode", layer: "unit" }
      it "still warns loudly about an empty selection" do
        Dir.mktmpdir { |dir| Dir.chdir(dir) { cli.run(["--json"]) } }

        expect(err).to include("warning", "selected 0 spec files")
      end

      # A run that selected nothing still owes stdout a document — a consumer
      # parsing stdout must not get an empty string, which is the one thing it
      # cannot tell apart from a crash.
      # @intent: { entity: "CLI json renderer", action: "leave stderr intact", behavior: "an empty selection still emits a document, so nothing selected stays distinguishable from nothing checked", layer: "unit" }
      it "still emits a document when nothing was selected" do
        Dir.mktmpdir { |dir| Dir.chdir(dir) { cli.run(["--json"]) } }

        expect(JSON.parse(out))
          .to include("ok" => true, "findings" => [],
                      "summary" => { "files" => 0, "annotations" => 0, "failed" => 0 })
      end
    end

    # DECISION (SPGD-305, recorded rather than defaulted into): no exit-2 path
    # emits a document. Those runs produced no verdicts, and a document is a
    # report about what was checked — `{"ok": false, "findings": []}` for a run
    # that checked nothing is this project's signature vacuous-green shape with
    # a schema wrapped round it. The prose goes to stderr, where diagnostics
    # about the linter already live, and the exit code says the rest.
    describe "a run that could not produce verdicts emits no document" do
      # @intent: { entity: "CLI json renderer", action: "fail without a document", behavior: "misused flags say nothing on stdout, since no run happened to report", layer: "unit" }
      it "says nothing on stdout when the flags are misused" do
        expect(cli.run(["--json", "--changed", fixture_path("order_spec.rb")])).to eq(2)

        expect(out).to be_empty
        expect(err).to include("specguard-lint: error: --changed cannot be combined with explicit files")
      end

      # SPGD-867: the run-level exit-2 path is now "no validator could be
      # resolved" — the always-on form `--require-validator` used to gate.
      # @intent: { entity: "CLI json renderer", action: "fail without a document", behavior: "an unresolvable validator is reported as prose on stderr, not as a json document", layer: "unit" }
      it "reports an unresolvable validator as prose on stderr, not as a document" do
        allow(SpecGuard::RSpec::ValidatorBackend::Installer)
          .to receive(:obtain).and_raise(SpecGuard::RSpec::ValidatorError, "could not obtain validate-intent")
        code = cli.run(["--json", fixture_path("order_spec.rb")])

        expect(code).to eq(SpecGuard::RSpec::CLI::EXIT_MISUSE)
        expect(out).to be_empty
        expect(err).to include("specguard-lint: error: could not obtain validate-intent")
      end
    end

    # @intent: { entity: "specguard-lint options", action: "document itself", behavior: "the usage text mentions the json flag so the renderer is discoverable", layer: "unit" }
    it "documents itself in the usage text" do
      cli.run(["--help"])

      expect(out).to include("--json")
    end
  end

  describe "reading files" do
    # @intent: { entity: "CLI", action: "read files", behavior: "an unreadable file is reported as its own failure without aborting the rest of the run", layer: "unit" }
    it "reports an unreadable file rather than aborting the whole run" do
      Dir.mktmpdir do |dir|
        missing = File.join(dir, "gone_spec.rb")

        expect { cli.run([missing]) }.not_to raise_error
        expect(out).to include("could not read file")
      end
    end

    # A read failure is not line-scoped — no line of the file was ever seen —
    # and slice 1 carries `line: 0` as the sentinel for that. Printing it as
    # `file:0` leaks the sentinel into the product: `:0` is not somewhere a
    # reader can go, and anything parsing `file:line` (CI annotations, editor
    # quickfix, review comments) would point at a line that does not exist.
    # The binary drops the line for exactly these findings (`JSONFinding`,
    # open-test-intent, cmd/validate-intent/report.go: "`line` is null where a
    # finding is not line-scoped"), and this is the one output shape the suite
    # did not pin to the byte, which is how `:0` shipped.
    # @intent: { entity: "CLI", action: "read files", behavior: "an unreadable file is named without a line number, since it has none", layer: "unit" }
    it "names the file WITHOUT a line number, which it does not have" do
      Dir.mktmpdir do |dir|
        missing = File.join(dir, "gone_spec.rb")
        cli.run([missing])

        expect(out).to include("FAIL  #{missing} — could not read file")
        expect(out).not_to include("#{missing}:0")
      end
    end

    # @intent: { entity: "CLI", action: "read files", behavior: "findings that do have a line keep it beside the file name", layer: "unit" }
    it "keeps the line number for findings that DO have one" do
      cli.run([fixture_path("broken_intent_spec.rb")])

      expect(out).to match(/^FAIL  \S+broken_intent_spec\.rb:9$/)
    end

    # Slice 1 classified an unreadable file as KIND_EXTRACTION, which under the
    # exit contract would read as a claim about an annotation. It is now
    # KIND_READ — the validator's own name for it — so the decision to
    # nonetheless fail the run (reference parity: `FAIL ... — could not read
    # file`, exit 1) is visible and reversible in one place.
    # @intent: { entity: "CLI", action: "read files", behavior: "an unreadable file is classified as a read failure, not as a malformed annotation", layer: "unit" }
    it "classifies it as a read failure, not as a malformed annotation" do
      Dir.mktmpdir do |dir|
        finding = SpecGuard::RSpec::Scanner.scan_file(File.join(dir, "gone_spec.rb")).first

        expect(finding.kind).to eq(SpecGuard::RSpec::Finding::KIND_READ)
      end
    end

    # The summary count exists to keep the totals honest, so it must not
    # overstate what was inspected. A file that could not be opened contributed
    # no annotation: counting its Result as one turns "12 files, none of them
    # read" into "checked 12 @intent annotations, 12 malformed".
    # @intent: { entity: "CLI", action: "read files", behavior: "an unread file is not counted among the annotations the run checked", layer: "unit" }
    it "does not count an unread file as an annotation it checked" do
      Dir.mktmpdir do |dir|
        cli.run([File.join(dir, "a_spec.rb"), File.join(dir, "b_spec.rb")])

        expect(out).to include("checked 0 @intent annotations, 0 malformed; 2 files could not be read")
      end
    end

    # @intent: { entity: "CLI", action: "read files", behavior: "annotations beside the unread file are still checked and counted in the same run", layer: "unit" }
    it "still counts the annotations it did check alongside the unread file" do
      Dir.mktmpdir do |dir|
        cli.run([fixture_path("broken_intent_spec.rb"), File.join(dir, "gone_spec.rb")])

        expect(out).to include("checked 5 @intent annotations, 5 malformed; 1 file could not be read")
      end
    end

    # Pinned against the RECORDED real-binary report (utf8-divergence.json):
    # the binary classifies a non-UTF-8 file as `read` and the CLI renders it
    # as a read failure rather than letting the bytes raise inside Ruby.
    # @intent: { entity: "CLI", action: "read files", behavior: "invalid UTF-8 in a file becomes a reported read failure rather than an exception reaching the shell", layer: "unit" }
    it "does not let invalid UTF-8 reach the shell as an exception" do
      path = fixture_path("invalid_utf8_spec.rb")

      expect { cli.run([path]) }.not_to raise_error
      expect(out).to include("FAIL  #{path} — could not read file")
    end
  end

  describe "--changed with explicit files" do
    # Honouring the files and dropping --changed without a word is the same
    # class of quiet no-op the slice exists to remove: --changed appears to have
    # been applied when it was not.
    # @intent: { entity: "CLI", action: "refuse conflicting modes", behavior: "combining changed mode with explicit files is refused rather than silently ignoring the flag", layer: "unit" }
    it "refuses the combination rather than silently ignoring --changed" do
      cli.run(["--changed", fixture_path("order_spec.rb")])

      expect(err).to include("--changed cannot be combined with explicit files")
    end

    # @intent: { entity: "CLI", action: "refuse conflicting modes", behavior: "the refused combination checks nothing at all", layer: "unit" }
    it "checks nothing when it refuses" do
      cli.run(["--changed", fixture_path("order_spec.rb")])

      expect(out).not_to include("checked")
    end

    # @intent: { entity: "CLI", action: "refuse conflicting modes", behavior: "the refusal uses the misuse exit code rather than accusing an annotation", layer: "unit" }
    it "exits 2, the misuse code, rather than accusing an annotation" do
      expect(cli.run(["--changed", fixture_path("order_spec.rb")])).to eq(2)
    end
  end

  # SPGD-1303. The shared `validate-intent` binary learned to expand a bare
  # directory argument as `DIR/**` (oti SPGD-1299), and the client was never
  # told: one argument stopped meaning one file, so `specguard-lint <dir>`
  # validated a whole subtree behind a header that said `checked 1 spec file`,
  # a summary that said `checked 3 @intent annotations`, and a zero-annotation
  # note that named the directory as carrying none — three sentences in one
  # document contradicting each other, and at its sharpest a directory holding
  # one VALID annotation exiting 0 beside that false note.
  #
  # Honest client-side accounting is impossible: the binary's document carries
  # only FINDINGS, so a CLEAN file in the expanded subtree appears in no
  # finding and "checked N" can never count what was actually validated.
  # Refusal is the only coherent client-side state, and it is the rule the ts
  # client's explicit arm already enforces with this exact sentence.
  describe "a directory named as an explicit path" do
    def dir_with_malformed_spec
      dir = Dir.mktmpdir("specguard-cli-dirarg")
      File.write(File.join(dir, "m_spec.rb"), <<~RUBY)
        # @intent: { entity: "Order" }
        RSpec.describe(Order) { it('totals') { expect(1).to eq(1) } }
      RUBY
      dir
    end

    # @intent: { entity: "CLI", action: "refuse a directory argument", behavior: "a directory named as an explicit path is refused with the misuse exit code rather than validated as a subtree", layer: "unit" }
    it "exits 2, the misuse code, rather than validating the subtree" do
      Dir.mktmpdir do |dir|
        expect(cli.run([dir])).to eq(described_class::EXIT_MISUSE)
      end
    end

    # @intent: { entity: "CLI", action: "refuse a directory argument", behavior: "the refusal names the directory and the remediation on stderr", layer: "unit" }
    it "names the directory and the remediation on stderr" do
      Dir.mktmpdir do |dir|
        cli.run([dir])

        expect(err).to include(
          "specguard-lint: error: #{dir} is a directory; name files or run without paths\n"
        )
      end
    end

    # The refusal happens before any validation, so the run produced no
    # verdicts and owes stdout nothing — the SPGD-305 exit-2 rule.
    # @intent: { entity: "CLI", action: "refuse a directory argument", behavior: "the refused run checks nothing and says nothing on stdout", layer: "unit" }
    it "checks nothing and says nothing on stdout" do
      dir = dir_with_malformed_spec
      cli.run([dir])

      expect(out).to be_empty
    ensure
      FileUtils.remove_entry(dir)
    end

    # The false-note arm of the defect, pinned directly: the directory itself
    # fell into `report_zero_annotation_files`' `bare` subtraction (its exact
    # string match cannot see the expanded file paths the findings carry), so
    # the run claimed the directory carried no annotations in the same breath
    # as counting three inside it. Refusing before selection is what retires
    # it — the note's predicate (SPGD-1158/1162) is untouched.
    # @intent: { entity: "CLI", action: "refuse a directory argument", behavior: "the zero-annotation note never fires for a directory holding annotated files", layer: "unit" }
    it "never fires the zero-annotation note for a directory holding annotated files" do
      dir = dir_with_malformed_spec
      cli.run([dir])

      expect(err).not_to include("no @intent annotations")
    ensure
      FileUtils.remove_entry(dir)
    end

    # `File.directory?` follows symlinks, so a symlink pointing at a directory
    # is the same class of argument and gets the same refusal — named by the
    # spelling the caller used, as every other path diagnostic here is.
    # @intent: { entity: "CLI", action: "refuse a directory argument", behavior: "a symlink pointing at a directory is refused like the directory it names", layer: "unit" }
    it "refuses a symlink pointing at a directory" do
      Dir.mktmpdir do |dir|
        target = File.join(dir, "specs")
        link = File.join(dir, "link")
        FileUtils.mkdir_p(target)
        File.symlink(target, link)

        expect(cli.run([link])).to eq(described_class::EXIT_MISUSE)
        expect(err).to include("#{link} is a directory; name files or run without paths")
      end
    end

    # The over-refusal guard. A directory is refused; a FILE is not, and
    # neither is a path that is not there. A nonexistent path is not a
    # directory, so it still reaches the binary and still comes back as the
    # no-match read finding at exit 1 — the typo case, which belongs to the
    # binary's diagnostic (oti SPGD-1301) and must not be swallowed here.
    # @intent: { entity: "CLI", action: "refuse a directory argument", behavior: "a nonexistent path is not refused as a directory and still reaches the validator as a read finding", layer: "unit" }
    it "does not refuse a nonexistent path as if it were a directory" do
      Dir.mktmpdir do |dir|
        missing = File.join(dir, "nope_spec.rb")

        expect(cli.run([missing])).to eq(described_class::EXIT_MALFORMED)
        expect(out).to include("could not read file")
        expect(err).not_to include("is a directory")
      end
    end

    # The file controls, pinned additively beside the refusal: the byte
    # behaviour of a FILE argument is exactly what it was before the stat.
    # @intent: { entity: "CLI", action: "refuse a directory argument", behavior: "a file carrying a valid annotation still exits 0 with no note", layer: "unit" }
    it "leaves a file with a valid annotation at exit 0 with no note" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "ok_spec.rb")
        File.write(path, <<~RUBY)
          # @intent: { entity: "Order", action: "total", behavior: "sums line totals into the order total", layer: "unit" }
          RSpec.describe(Order) { it('totals') { expect(1).to eq(1) } }
        RUBY

        expect(cli.run([path])).to eq(described_class::EXIT_OK)
        expect(err).not_to include("is a directory")
        expect(err).not_to include("no @intent annotations")
      end
    end

    # @intent: { entity: "CLI", action: "refuse a directory argument", behavior: "a file carrying a malformed annotation still exits 1 with its finding", layer: "unit" }
    it "leaves a file with a malformed annotation at exit 1 with its finding" do
      dir = dir_with_malformed_spec
      path = File.join(dir, "m_spec.rb")

      expect(cli.run([path])).to eq(described_class::EXIT_MALFORMED)
      expect(out).to include("checked 1 @intent annotation, 1 malformed")
      expect(err).not_to include("is a directory")
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  describe "the reason given for an empty --changed selection" do
    # The blocker's real sting: the warning did not just fire on an empty
    # selection, it stated something FALSE — "nothing in the diff matched
    # *_spec.rb" when a spec file demonstrably had changed. A confidently wrong
    # reason is worse than a quiet one, because a human reading it stops
    # looking.

    def repo_with_nested_spec
      dir = Dir.mktmpdir("specguard-cli")
      git!("init", "-q", "--initial-branch=main", chdir: dir)
      git!("config", "user.email", "t@example.com", chdir: dir)
      git!("config", "user.name", "T", chdir: dir)
      File.write(File.join(dir, "README.md"), "hello\n")
      git!("add", "-A", chdir: dir)
      git!("commit", "-q", "-m", "base", chdir: dir)
      git!("checkout", "-q", "-b", "feature", chdir: dir)
      FileUtils.mkdir_p(File.join(dir, "other/spec"))
      File.write(File.join(dir, "other/spec/sibling_spec.rb"), "# a spec\n")
      git!("add", "-A", chdir: dir)
      git!("commit", "-q", "-m", "add a spec", chdir: dir)
      FileUtils.mkdir_p(File.join(dir, "sub"))
      yield dir
    ensure
      FileUtils.remove_entry(dir) if dir
    end

    # @intent: { entity: "CLI", action: "explain an empty changed selection", behavior: "a spec changed elsewhere in the repo is not reported as nothing having matched", layer: "unit" }
    it "does not claim nothing matched when a spec changed elsewhere in the repo" do
      repo_with_nested_spec do |dir|
        Dir.chdir(File.join(dir, "sub")) { cli.run(["--changed"]) }
      end

      expect(err).to include("selected 0 spec files")
      expect(err).not_to include("none matching *_spec.rb")
      expect(err).to include("outside")
    end

    # @intent: { entity: "CLI", action: "explain an empty changed selection", behavior: "the warning says how many changed spec files were excluded as outside the directory", layer: "unit" }
    it "says how many changed spec files were excluded for being outside the directory" do
      repo_with_nested_spec do |dir|
        Dir.chdir(File.join(dir, "sub")) { cli.run(["--changed"]) }
      end

      expect(err).to include("1 changed spec file")
    end

    # Two filters emptied this selection, and naming only the first is the
    # exact failure this whole block exists to prevent. "2 changed spec files
    # … but 1 is outside" reads as complete arithmetic: 2 matched, 1 excluded,
    # so the reader concludes the remaining one was checked. It was not. The
    # unreadable file is the reason the run linted nothing, and it has to
    # appear alongside the other cause, not behind it.
    # @intent: { entity: "CLI", action: "explain an empty changed selection", behavior: "when both filters emptied the selection the unreadable files are named too, in one ordered shape", layer: "unit" }
    it "names the unreadable files too when both filters emptied the selection" do
      repo_with_nested_spec do |dir|
        # A symlink to a missing target: git tracks it (so it survives
        # `--diff-filter=d` and is counted as a changed spec) but `File.file?`
        # refuses it, which is the `unreadable` branch.
        File.symlink("missing_target.rb", File.join(dir, "sub/broken_spec.rb"))
        git!("add", "-A", chdir: dir)
        git!("commit", "-q", "-m", "add a broken symlink spec", chdir: dir)

        Dir.chdir(File.join(dir, "sub")) { cli.run(["--changed"]) }
      end

      expect(err).to include("selected 0 spec files")
      # Asserted as one shape rather than three independent `include`s: the
      # point of this example is that the two clauses appear TOGETHER and in
      # order. Separate matchers stay green if a refactor split them onto
      # their own lines, reversed them, or repeated a count — which is
      # precisely the regression this example exists to catch.
      expect(err).to match(
        /2 changed spec files against \S+, but 1 is outside \S+ \(--changed selects only files under the current directory\) and 1 could not be read/
      )
    end

    # SPGD-1267's third counter made a third pairwise combination possible,
    # and it pinned only the fence's solo arm. The fence clause has to
    # survive alongside BOTH of the older causes: deleting it leaves every
    # older pin green (neither of the two examples above ever exercises the
    # fence), and the reason drops back to naming two of three causes — the
    # reader does the arithmetic and concludes the fenced file was checked.
    # All three clauses must appear together, in the ladder's order, as one
    # shape.
    # @intent: { entity: "CLI", action: "explain an empty changed selection", behavior: "when outside-root, unreadable and fenced files all emptied the selection all three causes are named in one ordered shape", layer: "unit" }
    it "names all three exclusion causes in one ordered shape when outside-root, unreadable and fenced files coincide" do
      repo_with_nested_spec do |dir|
        # The dangling symlink is the `unreadable` branch; the vendored spec
        # under the cwd is the fence branch (the fence reads every path
        # component, so `vendor` catches it while it stays under the current
        # directory); the helper's committed sibling spec sits above the cwd
        # and is the `outside_root` branch.
        File.symlink("missing_target.rb", File.join(dir, "sub/broken_spec.rb"))
        vendored = File.join(dir, "sub/vendor/bundle/spec")
        FileUtils.mkdir_p(vendored)
        File.write(File.join(vendored, "vendored_spec.rb"), "# vendored\n")
        git!("add", "-A", chdir: dir)
        git!("commit", "-q", "-m", "add a broken symlink spec and a vendored spec", chdir: dir)

        Dir.chdir(File.join(dir, "sub")) { cli.run(["--changed"]) }
      end

      expect(err).to include("selected 0 spec files")
      # One shape, not three `include`s — the same reasoning as the two-cause
      # example above.
      expect(err).to match(
        /3 changed spec files against \S+, but 1 is outside \S+ \(--changed selects only files under the current directory\) and 1 could not be read and 1 in dependency or build directories/
      )
    end

    # The fence's solo arm is pinned above ("names the directory fence when
    # it empties a changed selection"); this is the arm that arm can
    # silently swallow. If the `unreadable + fence` clause is ever deleted,
    # control falls through to the solo arm, whose "all in dependency or
    # build directories" is a STRONGER claim than the truth: the unreadable
    # file vanishes from the explanation entirely. The negative matcher is
    # what turns that lie into a failure.
    # @intent: { entity: "CLI", action: "explain an empty changed selection", behavior: "when the unreadable files and the fence both emptied the selection both are named and the all-fenced claim is not made", layer: "unit" }
    it "names the unreadable file alongside the fence instead of claiming every match was fenced" do
      base = nil
      Dir.mktmpdir do |dir|
        git!("init", "-q", "--initial-branch=main", chdir: dir)
        git!("config", "user.email", "t@example.com", chdir: dir)
        git!("config", "user.name", "T", chdir: dir)
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "spec/base_spec.rb"), "# base\n")
        git!("add", "-A", chdir: dir)
        git!("commit", "-q", "-m", "base", chdir: dir)
        git!("checkout", "-q", "-b", "feature", chdir: dir)
        # One dangling symlink (the `unreadable` branch) and one vendored
        # spec (the fence branch), both under the repo root so
        # `outside_root` stays at zero — this is the two-cause arm the
        # ladder reaches without ever leaving the current directory.
        File.symlink("missing_target.rb", File.join(dir, "spec/broken_spec.rb"))
        vendored = File.join(dir, "vendor/bundle/ruby/3.3.0/gems/rspec-core-3.13/spec")
        FileUtils.mkdir_p(vendored)
        File.write(File.join(vendored, "vendored_spec.rb"), "# vendored\n")
        git!("add", "-A", chdir: dir)
        git!("commit", "-q", "-m", "add a broken symlink spec and a vendored spec", chdir: dir)

        base = Open3.capture3("git", "merge-base", "main", "HEAD", chdir: dir).first.strip
        Dir.chdir(dir) { cli.run(["--changed"]) }
      end

      expect(err).to include("selected 0 spec files")
      expect(err).to include(
        "2 changed spec files against #{base}, but 1 could not be read " \
        "and 1 in dependency or build directories"
      )
      # The fall-through lie: without this arm, the solo fence arm answers
      # and asserts `all`.
      expect(err).not_to include("all in dependency or build directories")
    end

    # SPGD-1293's arithmetic pin, on the shape the defect was measured
    # against: with both causes present the sentence names each with its
    # own count and the counts SUM to the matched total — the pre-fix
    # sentence prefixed the matched count onto the unreadable clause and
    # read "5 … could not be read and 3 in dependency" against 5 matched
    # files. The lopsided 2/3 counts also catch a swap of the two
    # counters, which the 1/1 fixture above cannot distinguish.
    # @intent: { entity: "CLI", action: "explain an empty changed selection", behavior: "when the unreadable files and the fence both emptied the selection each cause carries its own count and the two counts sum to the matched total", layer: "unit" }
    it "carries each cause's own count when the unreadable files and the fence emptied the selection" do
      base = nil
      Dir.mktmpdir do |dir|
        git!("init", "-q", "--initial-branch=main", chdir: dir)
        git!("config", "user.email", "t@example.com", chdir: dir)
        git!("config", "user.name", "T", chdir: dir)
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, "spec/base_spec.rb"), "# base\n")
        git!("add", "-A", chdir: dir)
        git!("commit", "-q", "-m", "base", chdir: dir)
        git!("checkout", "-q", "-b", "feature", chdir: dir)
        # Two dangling symlinks (the `unreadable` branch) and three vendored
        # specs (the fence branch), all under the repo root so
        # `outside_root` stays at zero — the two-cause arm, with counts too
        # lopsided to alias.
        File.symlink("missing_target.rb", File.join(dir, "spec/broken_one_spec.rb"))
        File.symlink("missing_target.rb", File.join(dir, "spec/broken_two_spec.rb"))
        vendored = File.join(dir, "vendor/bundle/spec")
        FileUtils.mkdir_p(vendored)
        3.times { |i| File.write(File.join(vendored, "vendored_#{i}_spec.rb"), "# vendored\n") }
        git!("add", "-A", chdir: dir)
        git!("commit", "-q", "-m", "add broken symlink specs and vendored specs", chdir: dir)

        base = Open3.capture3("git", "merge-base", "main", "HEAD", chdir: dir).first.strip
        Dir.chdir(dir) { cli.run(["--changed"]) }
      end

      expect(err).to include("selected 0 spec files")
      expect(err).to include(
        "5 changed spec files against #{base}, but 2 could not be read " \
        "and 3 in dependency or build directories"
      )
    end

    # AC honesty across frameworks: on a Minitest-only repository the silence
    # must not be explained in `*_spec.rb` vocabulary the tree does not use —
    # that message reads as a conclusion and stops the reader looking.
    # @intent: { entity: "CLI", action: "explain an empty default selection", behavior: "on a minitest only repository the empty selection names both naming conventions the walk recognizes", layer: "unit" }
    it "names the real filter when a Minitest-only repository selects nothing" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "test/models"))
        File.write(File.join(dir, "test/test_helper.rb"), "# helper\n")

        Dir.chdir(dir) { cli.run([]) }
      end

      expect(err).to include("selected 0 spec files")
      expect(err).to include("no *_spec.rb or *_test.rb file found under")
      expect(err).not_to include("no *_spec.rb found under")
    end

    # @intent: { entity: "CLI", action: "explain an empty changed selection", behavior: "a diff with no test files names both naming conventions rather than only the rspec one", layer: "unit" }
    it "names both conventions when nothing in the diff matched either" do
      dir = Dir.mktmpdir("specguard-cli")
      begin
        git!("init", "-q", "--initial-branch=main", chdir: dir)
        git!("config", "user.email", "t@example.com", chdir: dir)
        git!("config", "user.name", "T", chdir: dir)
        File.write(File.join(dir, "README.md"), "hello\n")
        git!("add", "-A", chdir: dir)
        git!("commit", "-q", "-m", "base", chdir: dir)
        git!("checkout", "-q", "-b", "feature", chdir: dir)
        File.write(File.join(dir, "README.md"), "edited\n")
        git!("add", "-A", chdir: dir)
        git!("commit", "-q", "-m", "docs only", chdir: dir)

        Dir.chdir(dir) { cli.run(["--changed"]) }
      ensure
        FileUtils.remove_entry(dir) if dir
      end

      expect(err).to include("selected 0 spec files")
      expect(err).to include("1 file changed against")
      expect(err).to include("none matching *_spec.rb or *_test.rb")
    end
  end
end
