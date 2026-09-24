# frozen_string_literal: true

# Answers one question, for one example at a time: *is this test annotated, and
# with what?*
#
# It is the formatter's half of the annotation story. The linter's half already
# exists and is not duplicated here — {SpecGuard::RSpec::Scanner} finds every
# `@intent:` in a file, captures its payload string-aware and parses it, and
# the `validate-intent` binary decides whether the result is valid. This class
# consumes both. Writing a second extractor would guarantee that the tool
# telling an author their annotation is wrong and the tool reporting it to the
# platform eventually disagree about what an annotation *is*.
#
# Requiring the linter's chain from here is safe in the direction that matters:
# `lib/specguard/rspec.rb` does not require `rspec/core`, so pulling it in from
# the formatter's side keeps `bin/specguard-lint` loadable on a machine with no
# RSpec installed. spec/specguard/rspec/formatter_loading_spec.rb pins that in
# both directions.
require_relative "../rspec"

module SpecGuard
  module RSpec
    # == The lookback rule (SPGD-12 §2)
    #
    # `example.metadata[:line_number]` is the line the `it` is on. An annotation
    # counts as this example's when it sits on that line (the trailing form) or
    # on the line immediately above it (the preceding-comment form):
    #
    #   # @intent: { entity: "Order", ... }    <- line above
    #   it "restores stock on refund" do       <- metadata[:line_number]
    #
    #   it "surfaces the decline reason" do # @intent: { ... }   <- same line
    #
    # One line of lookback, no more. Multi-line annotations are unsupported in
    # v1 (PROTOCOL.md §1 requires an annotation to fit on one line), so a wider
    # window could only ever attach an annotation to the wrong example.
    #
    # == Only the comment form is inherited by the line below
    #
    # The two forms are not symmetric, and the difference is not cosmetic. A
    # comment-only line hosts no example, so an annotation written there has
    # exactly one possible claimant — the line under it. An annotation written
    # in the trailing form is on a line that *is* an example's, so it has two,
    # and one-liner specs make the second one ordinary rather than exotic:
    #
    #   it { is_expected.to eq(1) } # @intent: { entity: "Order", ... }
    #   it { is_expected.to be_positive }
    #
    # Lookback that did not distinguish the forms would report **both** of those
    # as annotated, carrying the same intent — so the platform would store the
    # second example's declared purpose as something nobody declared, and count
    # it in `annotated_specs_count`. That is worse than reporting it
    # unannotated: a missing annotation is a visible gap, an invented one is
    # confident false telemetry, and it inflates the very ratio `status` exists
    # to keep honest.
    #
    # So a Finding is claimable by the line below it only when its own line is
    # comment-only ({COMMENT_LINE}). Deciding that needs the source line, which
    # is why {#build_index} reads the file itself and calls {Scanner.scan_text}
    # rather than {Scanner.scan_file} — the read is the same single read either
    # way, and the alternative was a second one per file purely to re-derive
    # what the first one already had in hand.
    #
    # == Why a malformed annotation is reported as *unannotated*
    #
    # {AnnotationScanner} states, correctly, that a typo'd annotation "must fail
    # loudly rather than silently counting as unannotated". That is the
    # **linter's** stance, and the linter already acts on it: it prints the
    # file:line and exits 1. It cannot bind the formatter, which is under the
    # never-block-CI contract and has no way to be loud that is not also a way
    # to be in someone's build output.
    #
    # The alternative is worse than it looks. `Ingest::Payload` is
    # all-or-nothing — it collects errors globally and `valid?` requires the
    # list to be empty — so shipping one schema-invalid intent does not lose
    # that annotation, it loses **the whole run**: a 400, and no telemetry for
    # any of the other twenty thousand examples. Downgrading one annotation to
    # `unannotated` costs one row's metadata. The example's name, duration and
    # outcome still ship either way.
    #
    # So every one of these produces the same answer — `nil`, meaning
    # unannotated:
    #
    #   * no `@intent:` on either candidate line;
    #   * an `@intent:` on the line above that is *not* a comment-only line —
    #     the trailing form belongs to its own example and lends itself to
    #     nobody;
    #   * an `@intent:` whose payload could not be captured or parsed
    #     ({Finding#problem?} — `KIND_EXTRACTION` / `KIND_PARSE`);
    #   * a file that could not be read at all (`KIND_READ`) — read against
    #     the root bound at construction, never against wherever the cwd has
    #     since moved, so a readable, correctly annotated spec no longer turns
    #     unreadable just because the suite changed directory. What still
    #     lands here is a path that names nothing under that root: genuinely
    #     absent, or relative to some other root this run never bound;
    #   * a syntactically fine annotation the schema rejects;
    #   * the schema itself failing to load.
    #
    # == Cost
    #
    # {AnnotationScanner.each_intent} walks every line of the file it is handed.
    # Scanning per *example* would make a 20,000-example suite read and walk its
    # spec files 20,000 times, on the critical path of somebody's test run. So
    # each file is read and scanned at most once and reduced to an {Index}:
    # O(files), not O(examples). Schema validation is memoized on the same
    # principle — per distinct annotation, not per example carrying it.
    class AnnotationLookup
      # Findings at line 0 are {Finding::KIND_READ} — "this file was never
      # read", not "there is an annotation on line 0". Keeping the sentinel out
      # of the index is what makes {Index#finding_for}'s unconditional
      # `line - 1` lookback safe for an example on line 1.
      FIRST_REAL_LINE = 1

      # A line whose only content is a comment: the preceding-comment form, and
      # the only form an example on the next line may claim. Leading whitespace
      # is allowed because annotations are indented with the examples they
      # describe.
      COMMENT_LINE = /\A\s*#/

      # One file's annotations, split by who is allowed to claim them.
      #
      #   own          every annotation, by the line it was written on
      #   inheritable  only those in the comment form, by that same line
      #
      # The values are the INTENT TO SHIP or nil — the verdict already applied —
      # rather than a Finding, because the two paths that build this index reach
      # a verdict by different routes (the local Scanner for the LINES, or the
      # port's report for the verdicts) and only agree on the answer. Storing the answer is what
      # keeps `#intent_for` from having to know which one ran.
      #
      # A line's own annotation always wins: the trailing form is written *on*
      # the example, so when a file somehow carries both it is the more specific
      # of the two, and a malformed trailing annotation is not quietly
      # backfilled from the comment above it — that would attach an intent its
      # author had already stopped meaning. Hence `key?` rather than a truthy
      # test: a line whose own annotation was rejected answers nil, and must not
      # fall through to the comment above it.
      #
      # `line - 1` is 0 for an example on line 1, and {AnnotationLookup#build_index}
      # is what guarantees that reads back as "no annotation": line 0 is never a
      # key, because the only finding produced there is the KIND_READ sentinel.
      Index = Struct.new(:own, :inheritable) do
        # @return [Hash, nil]
        def intent_for(line)
          return own[line] if own.key?(line)

          inheritable[line - 1]
        end
      end

      # The answer for a file nothing could be read out of. Its own constant so
      # the pessimistic pre-scan cache in {#index_for} and the unreadable-file
      # path cannot drift apart.
      EMPTY_INDEX = Index.new({}.freeze, {}.freeze).freeze

      # The read root, bound here at construction rather than per read. Both
      # clients build one lookup at suite start ({Formatter}'s and
      # {Reporter}'s constructors default it in) and then hand it
      # repo-relative paths, and a suite is free to change the working
      # directory between those two moments. Resolving per read would open
      # every relative spelling against wherever the cwd had since moved —
      # a readable, correctly annotated spec file that no longer resolves
      # from the new cwd answers {EMPTY_INDEX}, which is byte-for-byte what a
      # genuinely unannotated example reports, so nothing downstream could
      # detect the loss. Binding here keeps one run on one root — the same
      # one-binding-per-run rule the reporter already applies to its own
      # relativization, applied to the lookup's half of the pipeline. When
      # the cwd never moves, resolution is the identity on every path the
      # suite hands over.
      #
      # SPGD-1421 added the `root` parameter for the same one-binding rule one
      # level up: the client binds its own relativization root at construction
      # and hands that value here, so both halves of one run resolve against
      # ONE root instead of each reading `Dir.pwd` at its own moment. Both
      # Ruby clients hand that value over now — the Minitest reporter since
      # SPGD-1421, the RSpec formatter since SPGD-1429. The default keeps
      # this constructor's own SPGD-1417 binding — the caller's cwd, read at
      # construction, never re-read per read.
      #
      # @param env [Hash, ENV] where `SPECGUARD_VALIDATE_INTENT` is read from.
      #   Injected for testing, and read LAZILY — see {#backend}.
      # @param root [String] the directory relative spellings resolve against;
      #   bound here, no later than construction, whatever its source.
      def initialize(env: ENV, root: Dir.pwd)
        @env = env
        @indexes = {}
        @root = root
      end

      # The intent to attach to one example, or nil when it is unannotated.
      #
      # Nothing here is rescued: a caller that cannot survive an exception must
      # say so itself, and the formatter does — it wraps this in the same
      # `never_fail_the_run` envelope as everything else, so a blow-up costs the
      # example its annotation and not the suite its exit code. The memoization
      # below is deliberately written so that a failure is cached too, which is
      # what keeps "warns once" from becoming "warns once but rescans the file
      # for every one of the remaining examples".
      #
      # @param file [String, nil] the example's file, as the payload records it.
      #   A relative spelling is resolved against the root bound at
      #   construction — see {#initialize} — and never against the live cwd.
      # @param line [Integer, nil] `example.metadata[:line_number]`
      # @return [Hash, nil] the parsed, schema-valid annotation
      def intent_for(file:, line:)
        return nil unless file.is_a?(String) && !file.empty?
        return nil unless line.is_a?(Integer) && line >= FIRST_REAL_LINE

        index_for(file).intent_for(line)
      end

      private

      # The validator backend, or nil — memoized, including when resolving
      # RAISES.
      #
      # WHY THIS CLASS RESOLVES ONE AT ALL. `CLI` routes the linter through the
      # backend, and since the SPGD-867 cutover the backend is the ONLY
      # validator: the gem no longer carries a Ruby validation arm. Whatever
      # the backend accepts is what the platform must receive, so this asks
      # the same binary the same question rather than a second parser that
      # could disagree with it.
      #
      # Lazily, not in the constructor: {Formatter} builds this at suite start,
      # and `resolve` verifies the binary (two probes, and a raise when it is
      # unusable). Doing that during construction would move a failure out of
      # the formatter's `never_fail_the_run` envelope and into the point where
      # RSpec is still wiring itself up.
      #
      # A {ValidatorError} HERE IS NOT FATAL AND IS NOT nil-THE-ANNOTATION. An
      # unusable binary means this class cannot ask the backend what an
      # annotation says; it does NOT mean the annotation is bad. Since the
      # cutover there is no Ruby arm to fall back to, so probe failure is
      # memoized as nil and `#verdicts_for` answers `unverified_verdicts` for
      # every file: local line discovery keeps working and every annotation is
      # reported as `unannotated` — the honest answer under the formatter's
      # never-fail-the-run contract, while the linter half makes the failure
      # loud (it exits 2 when no binary can be resolved, naming the
      # remediations).
      #
      # The alternative was letting the raise reach {Formatter}'s
      # `never_fail_the_run` envelope. That envelope keeps the RUN alive, but
      # it does so by abandoning the example's annotation. Degrading HERE
      # instead means ONE swallowed probe per suite rather than one per
      # example, with `unverified_verdicts` as the single consistent answer
      # for every file.
      #
      # Cached, including on failure, for the reason {#schema} is: the probe is
      # a subprocess, and re-running it per example is the O(examples) cost this
      # class exists to refuse — on exactly the unhappy path where somebody's CI
      # is already having a bad day.
      def backend
        return @backend if defined?(@backend)

        @backend = nil
        @backend = ValidatorBackend.resolve(env: @env)
      rescue ValidatorError
        # Deliberately swallowed rather than re-raised: @backend is already nil,
        # so #verdicts_for takes the unverified_verdicts arm and the memo keeps
        # this from being re-probed.
        @backend = nil
      end

      # @return [Index]
      def index_for(file)
        return @indexes[file] if @indexes.key?(file)

        # Cache the pessimistic answer *before* the scan, not after. If the scan
        # raises, the raise still reaches the formatter (which warns once and
        # moves on) but the empty index stays behind, so the next example in the
        # same file is answered from the cache instead of re-raising and
        # re-reading. Without this, "warns once" would still mean "re-reads a
        # broken file once per example" — the O(examples) cost this class exists
        # to remove, reappearing on exactly the unhappy path where somebody's CI
        # is already having a bad day.
        @indexes[file] = EMPTY_INDEX
        @indexes[file] = build_index(file)
      end

      # @return [Index]
      def build_index(file)
        # One resolution for both legs: the local read below and the validator
        # subprocess (#verdicts_for -> Runner#check) must answer about the SAME
        # file, and the child inherits this process's working directory rather
        # than being told one — so an unresolved relative spelling used to fail
        # on both legs at once, which is why the degradation was total.
        # Resolving before either leg runs gives both one path. The memo
        # stays keyed by the caller's spelling; the resolution is
        # deterministic per construction, so the two can never disagree.
        resolved = resolve_path(file)

        # The read happens on BOTH paths and first on both. The backend does not
        # need it to find annotations — it reads the file itself — but the
        # comment-form rule below is a property of the LINE an annotation sits
        # on, which no report carries, so the text is required either way. Doing
        # it first also keeps the two paths agreeing about an unreadable file
        # without a subprocess being started to rediscover it.
        text = read(resolved)
        return EMPTY_INDEX if text.nil?

        index_from(verdicts_for(resolved, text), text)
      end

      # A caller-named path, made absolute against the root {#initialize} bound.
      #
      # Absolute spellings pass through untouched — they are what every existing
      # caller hands over, and expanding them could only normalize a string the
      # caller meant literally. A leading `~` passes through too:
      # {File.expand_path} would resolve it against `$HOME` even with a root
      # given, and a path that could not be read before resolution existed must
      # keep reading as unreadable, not start reading somewhere new.
      #
      # @param file [String] a non-empty path, as the caller named it
      # @return [String]
      def resolve_path(file)
        return file if file.start_with?(File::SEPARATOR, "~")

        File.expand_path(file, @root)
      end

      # One shell-out per FILE, which is the cost model this class already
      # commits to: {#index_for} is O(files), `--source` takes files, and the
      # port reports every annotation in one pass with the `file:line` scoping
      # {Index} needs. Per-example would be O(examples) subprocesses, which is
      # the cost this class exists to refuse.
      #
      # `#check` returns one {Linter::Result} per finding. A result that is not
      # `ok?` is an annotation the linter fails the build over, so it ships
      # nothing. Read failures and no-matches arrive line-scoped to 0 and are
      # filtered by {#index_from}.
      #
      # A {ValidatorError} here means the backend could not answer about THIS
      # file's annotations. Since the cutover there is no Ruby arm to fall back
      # to, the honest answer is the one this class already gives for anything
      # it could not verify: every annotation in the file ships `unannotated`.
      # The never-block-CI contract forbids anything louder from the formatter,
      # and the linter — which CAN be loud — is the tool that catches it.
      def verdicts_for(file, text)
        resolved = backend
        return unverified_verdicts(file, text) if resolved.nil?

        resolved.check([file]).map do |result|
          [result.line, result.ok? ? result.representable_intent : nil]
        end
      rescue ValidatorError
        unverified_verdicts(file, text)
      end

      # The lines the scanner still finds, every one answered `nil`. Discovery
      # is a property of the FILE (which lines carry annotations, which are
      # comment-form) and stays local — it is validation that needed the
      # backend. Keeping the lines lets {#index_from} apply the comment-form
      # rule exactly as it does for verdicts the backend did answer.
      def unverified_verdicts(file, text)
        Scanner.scan_text(text, file: file).map { |finding| [finding.line, nil] }
      end

      # @return [Index]
      def index_from(verdicts, text)
        lines = nil
        own = {}
        inheritable = {}

        verdicts.each do |line, intent|
          # Findings at line 0 are {Finding::KIND_READ} — "this file was never
          # read", not "there is an annotation on line 0".
          next unless line.is_a?(Integer) && line >= FIRST_REAL_LINE

          # First wins. `each_intent` resumes scanning after each captured
          # payload, so trailing prose containing a second `@intent:` yields a
          # second finding on the same line. The annotation is the one the
          # author wrote first; the rest of the line is commentary. Stated here
          # rather than left to Hash-insertion order.
          next if own.key?(line)

          own[line] = intent
          # Materialized only once a real annotation has been found, and never
          # for a file `scan_text` refused: its invalid-UTF-8 answer is a single
          # line-0 finding, filtered out above, and splitting such a string is
          # itself an ArgumentError waiting to happen.
          lines ||= text.lines
          inheritable[line] = intent if COMMENT_LINE.match?(lines[line - 1].to_s)
        end

        Index.new(own, inheritable)
      end

      # {Scanner.scan_file} would do this read, but it hands back only Findings
      # and the form of an annotation is a property of the *line* it sits on. So
      # the read happens here and {Scanner.scan_text} — the same pipeline, one
      # stage lower — does the extracting. Nothing about what an annotation *is*
      # is re-implemented; a second extractor is how the tool that tells an
      # author their annotation is wrong and the tool that reports it to the
      # platform end up disagreeing.
      #
      # The rescue mirrors `scan_file`'s own, and the two agree on the answer: it
      # turns an unreadable file into a line-0 KIND_READ Finding, which this
      # class filters out, and nil here becomes {EMPTY_INDEX}. Either way, every
      # example in a file that could not be read is unannotated.
      #
      # {#build_index} hands the path over already resolved — once for both
      # this leg and the validator subprocess — so `file` here opens the same
      # file whichever leg asks, wherever the cwd has since moved.
      #
      # @return [String, nil]
      def read(file)
        File.read(file, encoding: "UTF-8")
      rescue SystemCallError, IOError
        nil
      end

      # Keyed by the intent itself, so an annotation repeated across a suite is
      # checked once rather than once per example that carries it. The
      # shell-out is the expensive stage, and this class is explicitly about
      # not paying O(examples) for work that is O(files).
      #
      # The verdict is now reached while the index is BUILT rather than when an
      # example first claims the line, which makes the cost O(annotations in the
      # file) instead of O(annotations examples ask about) — still bounded by
      # the file, still memoized across files, and it is what lets the index
      # hold one shape whichever path filled it. The visible consequence is that
      # an unloadable schema raises on the first lookup into a file with any
      # annotation rather than the first lookup that lands on one; both are
      # inside the formatter's envelope, and {#index_for}'s pessimistic
      # pre-caching already guarantees the second example does not raise again.
    end
  end
end
