# frozen_string_literal: true

require "optparse"

module SpecGuard
  module RSpec
    # `specguard-lint`'s command line, and the whole of the exit contract.
    #
    # == The contract, and the reason it needs defending
    #
    #   0  every annotation checked is valid (including "there were none")
    #   1  at least one annotation is malformed or unreachable
    #   2  the linter could not do its job — misuse, or the tool itself broken
    #
    # Ruby does not give you this for free; it actively works against it.
    # `ruby -e 'raise "boom"'` exits **1**, and so does an uncaught
    # `OptionParser::InvalidOption`. So on the obvious implementation, every
    # internal failure lands on the one code the contract has already spent on
    # "an annotation is malformed":
    #
    #   * `specguard-lint --chnaged` — a typo — would exit 1, and CI would
    #     report a malformed annotation that does not exist;
    #   * a vendored schema missing from the packaged gem would exit 1, the
    #     same false accusation, in the field, on someone else's machine.
    #
    # The project has shipped this defect shape repeatedly — SPGD-35, SPGD-52,
    # SPGD-56 — but always as **false green**: a gate reporting success having
    # checked nothing. This is its inverse, **false red**: a tool failure
    # wearing the costume of a content failure. Both are the same underlying
    # bug, a gate whose failure states are indistinguishable, and for a linter
    # the exit code *is* the product.
    #
    # {#run} therefore rescues in two bands and returns rather than exits:
    # {UsageError} and {ValidatorError} are named, and everything else that is
    # not a deliberate interruption is caught by a backstop. Exit 1 is produced
    # in exactly one place — a failed {Linter::Result} — so it means that and
    # nothing else.
    #
    # `Interrupt`, `SignalException` and `SystemExit` are deliberately *not*
    # caught. Ctrl-C must stay Ctrl-C; mapping it to "the linter is broken"
    # would be its own small lie.
    #
    # == All failures, not the first
    #
    # SPGD-12 §1 step 4 says the linter "exits 1 on the *first* malformed
    # annotation". Its own exit-code table, one paragraph later, says "1 | One
    # or more annotations are malformed", and the validator reports every one:
    # `validate-intent --source broken_intent_spec.rb` emits 5 FAIL blocks. Stopping at the first would turn one file into five CI
    # round-trips. Reporting all of them is the ratified behaviour (human
    # decision recorded on SPGD-82); the "first" wording is a known spec defect
    # with a correction filed against SPGD-12 §1 and the SPGD-73 roadmap text.
    #
    # == One validator, one report
    #
    # Since the SPGD-867 cutover there is exactly one validator: the
    # `validate-intent` binary {ValidatorBackend} resolves (an explicit
    # `SPECGUARD_VALIDATE_INTENT` path, or the first-run auto-install). The
    # Ruby hand-rolled validation arm is gone — when no binary can be resolved
    # the run exits 2 naming both remediations, and it NEVER silently
    # validates some other way. The verdicts arrive as {Linter::Result}s, and
    # the reporting and exit-code logic is shared with nothing because there
    # is nothing to share it with.
    #
    # Because both arms produce the same bytes, the run has to SAY which one it
    # was, or the answer is unrecoverable from the output — see
    # {#report_backend}, which states it in one line on stderr on both arms.
    # That line is the only thing the default configuration gained: stdout, the
    # exit code and every finding are what they were before this file learned
    # about a second validator.
    #
    # The backend's failure modes are exit 2 by construction: {ValidatorError}
    # is rescued beside {UsageError}, which is what makes "the binary you named
    # is missing" read as `specguard-lint: error: …` rather than reaching the
    # backstop and reading as an `internal error:`. Either way it is a 2, and
    # that is the property that matters — a broken tool must not borrow the
    # code that means "your annotations are malformed".
    #
    # == Two renderers, and what `--json` does NOT touch
    #
    # `--json` (SPGD-305) replaces the human report on stdout with one JSON
    # document over the very same {Linter::Result} list — see {JSONReporter}.
    # It is a renderer, so the three things that are the contract are untouched
    # by it: the exit code (the decision below is one expression, evaluated on
    # both paths), stderr (the provenance line and every warning are byte-for-
    # byte what they were), and the default path (without the flag, stdout is
    # what it was, pinned as a regression lock in
    # `spec/specguard/rspec/regression_targets_spec.rb`).
    #
    # No exit-2 path emits a document, and that is a decision rather than an
    # omission. Every `rescue` below means the linter produced NO VERDICTS —
    # bad flags, `--changed` outside a repository, a validator that could not
    # be resolved or produced no verdict. A document is a report about what was
    # checked; emitting `{"ok": false, "findings": []}` for a run that checked
    # nothing would hand a stdout-reading consumer the project's signature
    # defect — an empty clean-looking report standing in for "could not check" —
    # and dressing it as structure would make it *more* convincing, not less.
    # Those runs write prose to stderr, where diagnostics about the linter
    # already live, and say what happened with the exit code.
    class CLI
      BANNER = "Usage: specguard-lint [options] [files...]"

      # Every annotation checked was valid — or there were none to check.
      # "Lint, don't require": a missing annotation is never an error.
      EXIT_OK = 0
      # One or more annotations are malformed — or well-formed but
      # unreachable (SPGD-900: stacked above another comment-form `@intent:`
      # line, so the one-line lookback never claims it, a dead contract that
      # is still a failure). The only code produced by inspecting content,
      # and the only path that reaches it is a failed {Linter::Result}.
      EXIT_MALFORMED = 1
      # The linter could not do its job: bad flags, `--changed` outside a git
      # repository, a validator that could not be resolved, or an unexpected
      # internal error.
      EXIT_MISUSE = 2

      def initialize(stdout: $stdout, stderr: $stderr, env: ENV)
        @stdout = stdout
        @stderr = stderr
        @env = env
      end

      # @param argv [Array<String>]
      # @return [Integer] 0, 1 or 2 — never anything else, and never by
      #   letting an exception reach the shell
      def run(argv)
        options = parse_options(argv)
        return EXIT_OK if options.nil? # --help / --version already printed

        # Resolved — or the run has already exited 2 — before anything is
        # selected or scanned, for the same reason it always was: "the
        # validator could not be obtained" must never surface as a run that
        # checked nothing and called itself clean. There is no Ruby arm to
        # fall back to, so a resolution failure IS the run's failure.
        backend = ValidatorBackend.resolve(env: @env)

        # One line per run naming the implementation that produced the
        # verdicts. Since the cutover there is exactly one implementation.
        report_backend(backend)

        selection = select(options)
        report_selection(selection, json: options[:json])

        results = backend.check(selection.files)

        # The structural pass (SPGD-900): annotations that are valid in
        # isolation but can never be extracted — stacked consecutive
        # comment-form `@intent:` lines, where the one-line lookback
        # (SPGD-12 §2) claims only the line just above the example. These are
        # Linter::Results like any other, so both renderers and the exit code
        # pick them up with no second path to keep in step.
        results += unreachable_results(selection.files)

        # Computed once, here, and handed to whichever renderer runs. `--json`
        # is a second renderer over this list, not a second code path: the exit
        # code below is the same expression it always was, and the document's
        # `ok` is derived FROM it rather than recomputed from the findings, so
        # the two renderers cannot disagree about whether the run passed.
        code = results.any?(&:failed?) ? EXIT_MALFORMED : EXIT_OK
        # The selection's file LIST rides along (the `files:` count stays what
        # the document's summary consumes) because the coverage note is about
        # which files were checked, not how many.
        report_results(results, files: selection.count, selected_files: selection.files,
                       json: options[:json], ok: code == EXIT_OK)

        code
      rescue UsageError, ValidatorError => e
        @stderr.puts "specguard-lint: error: #{e.message}"
        EXIT_MISUSE
      rescue ScriptError, StandardError => e
        # The backstop that makes exit 1 mean one thing. Anything reaching here
        # is a bug in the linter, not a verdict about anyone's annotations, so
        # it is a 2 and it says so in those words.
        @stderr.puts "specguard-lint: internal error: #{e.class}: #{e.message}"
        EXIT_MISUSE
      end

      private

      # {Scanner}'s structural findings are annotations, not file problems:
      # each carries a real `file:line`, so they become failing line-scoped
      # {Linter::Result}s exactly like a malformed payload would. A file the
      # backend could not read contributes nothing here — the backend's own
      # KIND_READ result already reports it, and this pass cannot be positional
      # about a file it never saw.
      def unreachable_results(paths)
        Scanner.unreachable_findings(paths).map do |finding|
          Linter::Result.new(file: finding.file, line: finding.line,
                             kind: finding.kind, problem: finding.problem)
        end
      end

      # One line per run naming the implementation that produced the verdicts.
      # Since the SPGD-867 cutover there is exactly one implementation — the
      # resolved `validate-intent` binary — and the line says which one,
      # including its identity and schema contract, so "which validator did
      # this CI job actually run" stays answerable from the output.
      #
      # It is on STDERR: the findings and the two `checked …` lines are the
      # product and are pinned byte-for-byte; a line about the linter's own
      # configuration belongs where the warnings are.
      def report_backend(backend)
        @stderr.puts "specguard-lint: #{backend.provenance}"
      end

      # Naming files and asking for the diff are contradictory instructions,
      # and honouring the first while dropping the second silently is the same
      # class of quiet no-op this tool exists to remove: `--changed` would
      # appear to have been applied. That is misuse — exit 2.
      def select(options)
        if options[:files].any?
          if options[:changed]
            raise UsageError,
                  "--changed cannot be combined with explicit files; drop one " \
                  "(named files are checked as given, --changed derives them from the diff)"
          end

          return FileSelector::Selection.new(files: options[:files], mode: :explicit)
        end

        FileSelector.select(changed: options[:changed], base: options[:base], root: options[:root])
      end

      # The honest-reporting half of the `--changed` fix: the selected-file
      # count is always stated, and an empty selection is loud on stderr, so
      # "checked 12 files, found nothing" can never be mistaken for
      # "checked nothing". The exit code is not the lever here — the contract
      # fixes 0 for "no annotations" — which is exactly why the warning has to
      # carry the weight.
      #
      # Under `--json` the count is not dropped, it MOVES: stdout carries one
      # document and nothing else, and this line's number is that document's
      # `summary.files`. The sentence branches by STREAM, not by content: the
      # human renderer reads it on stdout, the json renderer on stderr, where
      # diagnostics about the linter already live — the empty-selection
      # warning is the precedent, SPGD-247 the doctrine. (SPGD-1134: this was
      # an `elsif !json` suppression, which left a json run's selection
      # unverifiable — the machine channel named neither its resolved base nor
      # its untracked leg, so the bridge, which passes `--json`
      # unconditionally, could only verify the diff ∪ untracked union by
      # arithmetic on `summary.files`.) The warnings below are diagnostics
      # about the linter rather than findings, so they stay on stderr exactly
      # as they are — a run that selected nothing is still loud, in both
      # renderers.
      #
      # The `--changed` count names its provenance: files can reach the
      # selection through the untracked leg (`file_selector.rb`), and "changed
      # since <base>" alone over-claims for a file the diff never saw. When
      # the untracked leg contributed, the line says how many — the same
      # `stats.untracked` the selection carries, so the clause can only ever
      # name files this run actually checked.
      def report_selection(selection, json:)
        if selection.empty?
          @stderr.puts "specguard-lint: warning: selected 0 spec files — #{empty_reason(selection)}"
          @stderr.puts "specguard-lint: warning: #{selection.note}" if selection.note
        else
          json ? @stderr.puts(selection_line(selection)) : @stdout.puts(selection_line(selection))
        end
      end

      # The selection sentence, built at exactly one site and written by both
      # renderers — only the stream differs. The human line is the contract
      # of record; the json renderer printing the SAME bytes is what makes
      # "the machine reads the provenance the human does" a property of the
      # code rather than a promise two copies could drift apart on.
      #
      # The `:all` count names its fence: `FileSelector.select_all` refuses
      # dependency/build directories (`file_selector.rb`
      # `SKIPPED_DIRECTORIES`), and a fence that actually removed files says
      # how many — the narrowing must never be silent. The clause is
      # count-gated exactly like the untracked one, so a run whose fence
      # removed nothing prints byte-identically to before the fence existed.
      def selection_line(selection)
        untracked = selection.mode == :changed ? selection.stats&.untracked.to_i : 0
        skipped = selection.mode == :all ? selection.skipped : 0
        "specguard-lint: checked #{selection.count} spec file#{'s' unless selection.count == 1}" \
          "#{" changed since #{selection.base}" if selection.mode == :changed}" \
          "#{" under #{Dir.pwd}" if selection.mode == :all}" \
          "#{" including #{untracked} untracked" if untracked.positive?}" \
          "#{" skipping #{skipped} in dependency or build directories" if skipped.positive?}"
      end

      # `:explicit` is absent by construction — an explicit Selection is only
      # built from a non-empty file list, so it can never be empty.
      def empty_reason(selection)
        return changed_empty_reason(selection) if selection.mode == :changed
        # An `:all` selection the fence emptied must not blame the tree for
        # holding no spec files — the files existed and the fence removed
        # them, and "no file found" is the confidently wrong reason this
        # ladder exists to prevent.
        return all_fenced_reason(selection) if selection.mode == :all && selection.skipped.positive?

        "no *_spec.rb or *_test.rb file found under #{Dir.pwd}"
      end

      # The fence arm of the `:all` empty reason: every matching file the walk
      # found was inside a {SpecGuard::RSpec::FileSelector::SKIPPED_DIRECTORIES}
      # directory, so the silence is the fence's, not the tree's.
      def all_fenced_reason(selection)
        n = selection.skipped
        "#{n} *_spec.rb or *_test.rb file#{'s' unless n == 1} found, " \
          "all in dependency or build directories"
      end

      # Names the filter that actually emptied the selection. Saying "nothing in
      # the diff matched" when a test file demonstrably changed —
      # just not under this directory — is worse than saying nothing: it reads
      # as a conclusion and stops the reader looking. Both naming conventions
      # are named because either would have been selected; a Minitest-only
      # repository must not be told the silence is about `*_spec.rb` files it
      # does not have.
      def changed_empty_reason(selection)
        stats = selection.stats
        base = selection.base

        return "nothing in the diff against #{base} matched a *_spec.rb or *_test.rb file" if stats.nil?

        if stats.changed.zero?
          "nothing changed against #{base}"
        elsif stats.spec_matches.zero?
          "#{stats.changed} file#{'s' unless stats.changed == 1} changed against #{base}, " \
            "none matching *_spec.rb or *_test.rb"
        else
          changed_excluded_reason(stats, base)
        end
      end

      # `outside_root` and `unreadable` are independent counters over disjoint
      # branches of the same partition (`file_selector.rb`), so both can be
      # positive at once. Naming only the first one found is the failure the
      # comment above forbids: the reader does the arithmetic, sees that
      # `spec_matches - outside_root` files are unaccounted for, and concludes
      # they were checked. They were not — the selection is empty. So the
      # clauses are additive, and a selection emptied by both causes says so.
      def changed_excluded_reason(stats, base)
        matched = "#{stats.spec_matches} changed spec file#{'s' unless stats.spec_matches == 1} against #{base}"

        # Nothing outside the root: `unreadable` is then the only filter left
        # that can have emptied the selection, so it needs no count of its own.
        return "#{matched} could not be read" unless stats.outside_root.positive?

        reason = "#{matched}, but #{stats.outside_root} #{stats.outside_root == 1 ? 'is' : 'are'} " \
                 "outside #{Dir.pwd} (--changed selects only files under the current directory)"
        reason += " and #{stats.unreadable} could not be read" if stats.unreadable.positive?
        reason
      end

      # The FAIL block, in the shape `bin/validate-intent --source` emits: two
      # spaces after `FAIL`, an em-dash before an extraction problem, eight
      # spaces and `-> ` before each schema reason.
      #
      #   FAIL  spec/order_spec.rb:9
      #           -> <root>: missing required property 'entity'
      #   FAIL  spec/order_spec.rb:28 — unterminated object literal (...)
      #
      # Two deliberate differences from the reference's `--source` mode, which
      # is a fixture self-test rather than a linter:
      #
      #   * no `PASS` line per valid annotation — a CI linter that prints a
      #     line per healthy annotation buries the failures in a large repo.
      #     The summary line carries the count instead, so "checked nothing"
      #     is still impossible to mistake for "all clean".
      #   * findings go to **stdout**, where the reference puts them and where
      #     lint findings conventionally go. Diagnostics about the linter
      #     itself (warnings, misuse, schema failure) stay on stderr.
      #
      # That second bullet used to end "…and the exit code — not the stream —
      # is the machine-readable signal." It justified the STREAM SPLIT, which
      # stands unchanged; but read as a claim about the tool it is now false,
      # and it was already dated when it was written. It comes from SPGD-82,
      # before the Go port grew `--json` (SPGD-102), and a 3-valued exit code
      # was then genuinely the only structured thing a consumer could read.
      # SPGD-305 gives this renderer a sibling: with `--json`, stdout carries
      # one JSON document — file, line, kind, errors — and the exit code is one
      # signal of two rather than the only one. Nothing moved off stderr to make
      # that true; see {JSONReporter}.
      #
      # == Two renderers, one result list
      #
      # The partition below is computed ONCE and handed to whichever renderer
      # runs. Both the text summary line and the document's `summary` are
      # statements about the same numbers, and a linter whose two renderers can
      # disagree about how much it checked is worse than one that only prints
      # prose: the disagreement is unfalsifiable from outside the process.
      def report_results(results, files:, selected_files:, json:, ok:)
        annotations, unread = results.partition(&:line_scoped?)

        report_zero_annotation_files(selected_files, annotations, unread)

        if json
          @stdout.puts JSONReporter.render(results, files: files, annotations: annotations.length, ok: ok)
          return
        end

        results.reject(&:ok?).each { |result| report_failure(result) }

        @stdout.puts summary_line(annotations, unread)
      end

      # The coverage note: which of the checked files were read and yielded no
      # `@intent` annotation at all. Zero findings on stdout (or an empty
      # `findings` list in the document) is otherwise ambiguous between
      # "every checked file was annotated and valid" and "half the checked
      # files carry nothing" — and the missing-annotation question is the most
      # actionable one this tool touches, because the bridge agent reading
      # `linter_stderr` has no other view into the repository's spec files.
      #
      # The boundary is the set-difference the partition above already
      # supports: a file counts as covered when it yielded any line-scoped
      # result (an annotation, valid or not — the SPGD-900 unreachable findings
      # are line-scoped too and require an annotation to exist, so they cover
      # their file) or when it could not be read at all (KIND_READ → `unread`).
      # An unread file is NOT a zero-annotation file: it already gets its own
      # summary clause and FAIL line, and calling it annotation-free would be
      # the same overstatement `summary_line` refuses to make. Unreachable
      # findings need a stacked annotation — impossible in a file with none —
      # so `annotations ∪ unread` already covers every non-bare file and no
      # third subtraction is needed.
      #
      # It is a NOTE on stderr, never a warning and never an exit code: "lint,
      # don't require" (SPGD-12 §1) keeps a missing annotation a non-error.
      # It is emitted before the json early-return so both renderers get it —
      # stderr is renderer-indifferent (SPGD-247; the SPGD-1134 selection
      # sentence is the landed precedent, and the bridge forwards stderr
      # verbatim as `linter_stderr`). The prefix is deliberately not
      # `specguard-lint: checked`, which the selection-sentence pin counts.
      def report_zero_annotation_files(selected_files, annotations, unread)
        bare = selected_files - annotations.map(&:file) - unread.map(&:file)
        return if bare.empty?

        verb = bare.length == 1 ? "carries" : "carry"
        @stderr.puts "specguard-lint: note: #{bare.length} of #{selected_files.length} checked " \
                     "spec file#{'s' unless selected_files.length == 1} #{verb} no @intent " \
                     "annotations: #{bare.join(', ')}"
      end

      # The summary line exists for one reason — so "checked nothing" can never
      # read as "all clean" — which makes overstating what was inspected its
      # own kind of lie. A file that could not be opened contributed no
      # annotation, so counting its Result as one would report "checked 12
      # @intent annotations, 12 malformed" having read none of them. Unread
      # files get their own clause: neither folded into the annotation count
      # nor dropped from the report.
      def summary_line(annotations, unread)
        line = "specguard-lint: checked #{annotations.length} @intent annotation" \
               "#{'s' unless annotations.length == 1}, #{annotations.count(&:failed?)} malformed"
        return line if unread.empty?

        "#{line}; #{unread.length} file#{'s' unless unread.length == 1} could not be read"
      end

      def report_failure(result)
        if result.problem
          @stdout.puts "FAIL  #{result.location} — #{result.problem}"
        else
          @stdout.puts "FAIL  #{result.location}"
          result.reasons.each { |reason| @stdout.puts "        -> #{reason}" }
        end
      end

      def parse_options(argv)
        options = { changed: false, base: nil, root: Dir.pwd, files: [], json: false }

        parser = OptionParser.new do |o|
          o.banner = BANNER
          o.on("--changed[=BASE]",
               "Only spec files changed against BASE (default: the merge base with the default branch)") do |base|
            options[:changed] = true
            options[:base] = base
          end
          o.on("--json", "Emit one JSON document on stdout instead of the human report") do
            options[:json] = true
          end
          o.on("-v", "--version", "Print the version and exit") do
            @stdout.puts "specguard-ruby #{VERSION}"
            return nil
          end
          o.on("-h", "--help", "Print this help and exit") do
            @stdout.puts o
            return nil
          end
        end

        options[:files] = parser.parse(argv)
        options
      rescue OptionParser::ParseError => e
        # Uncaught, this is the single likeliest way a user sees a false
        # "malformed annotation": OptionParser raises, Ruby exits 1. Retyping
        # it is what makes `--chnaged` a 2.
        raise UsageError, e.message
      end
    end
  end
end
