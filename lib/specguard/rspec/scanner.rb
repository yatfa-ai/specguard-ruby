# frozen_string_literal: true

require "json"

module SpecGuard
  module RSpec
    # Runs the discovery pipeline over source files and returns {Finding}s.
    #
    # Pipeline, per `@intent:` token:
    #
    #   {AnnotationScanner} -> {PayloadNormalizer} -> `JSON.parse`
    #
    # This is the whole of the *input* half of the linter. It deliberately stops
    # at "an annotation is a Hash": nothing here loads or applies the
    # OpenTestIntent schema, so a Finding with an `intent` is merely
    # syntactically sound, not valid.
    module Scanner
      module_function

      # @param paths [Enumerable<String>]
      # @return [Array<Finding>] in file-then-line order
      def scan_files(paths)
        paths.flat_map { |path| scan_file(path) }
      end

      # @param path [String]
      # @return [Array<Finding>] one per `@intent:` token; empty when the file
      #   carries none. A file that cannot be read yields a single Finding at
      #   line 0 rather than raising — one bad file must not abort the run.
      #
      #   RATIFIED DIFFERENCE from the binary, for a path that does not exist.
      #   `validate-intent` expands its arguments as glob PATTERNS, so a name
      #   matching nothing is a statement about the pattern —
      #   `error: no file(s) match '<path>'`, on stderr, before any file is
      #   opened. This linter does no globbing: explicit files are checked as
      #   given and `--changed` derives its list from git, so every argument
      #   here is a PATH, and an unopenable one is a read failure OF THAT PATH —
      #   reported on stdout with the errno the binary never had occasion to
      #   name. Adopting the binary's wording would mean giving this gem a
      #   globber first, and changing what `specguard-lint 'foo*_spec.rb'` means
      #   for everyone already using it.
      #
      #   Both tools exit 1 and both name the file; that much is asserted in
      #   spec/specguard/rspec/validator_backend_spec.rb, along with the case
      #   that matters more — a missing file does not stop either tool checking
      #   the good files named beside it.
      #
      #   A path that EXISTS and is not a regular file is the same ratified
      #   difference one step further out. The binary's arguments are glob
      #   PATTERNS whose matches are filtered to regular files, so such a path
      #   folds into the answer a name matching nothing gets — the backend has
      #   nothing else to say about it. This linter does no globbing and hands
      #   the path to `File.read` as given, so what comes back is whatever
      #   reading THAT path does, and never what a nonexistent path gets: the
      #   path is there to be opened, so the failure it does or does not produce
      #   is a fact about the path rather than about a pattern. Ruby tells the
      #   two apart and the backend cannot — asserted under "a path that is not
      #   a regular file" in that same spec, whose subject is a path that
      #   exists, is not a regular file, and is not a directory.
      #
      #   A DIRECTORY is NOT an example of this difference, on either side.
      #   `CLI#select` refuses one named as an explicit path (SPGD-1303) and
      #   `--changed` derives its list from git, so a directory is settled
      #   before this rescue is reached and never reaches the backend either.
      #   What the shared binary makes of a bare directory argument has moved
      #   upstream more than once and is deliberately not restated here: the
      #   difference above is a property of the two sides' path semantics, and
      #   nothing about a directory is needed to state it.
      def scan_file(path)
        begin
          text = File.read(path, encoding: "UTF-8")
        rescue SystemCallError, IOError => e
          return [Finding.new(file: path, line: 0, problem: "could not read file: #{e.message}",
                              kind: Finding::KIND_READ)]
        end

        scan_text(text, file: path)
      end

      # @param text [String] source of one file
      # @param file [String] the path to record on each Finding
      # @return [Array<Finding>]
      def scan_text(text, file:)
        # An invalid byte sequence would make every String operation below raise
        # from deep inside the scanner. Report it as this file's one problem.
        #
        # RATIFIED DIFFERENCE from the binary, in the REASON TEXT only. Both
        # refuse the file — PROTOCOL.md §1.1 makes UTF-8 part of what a JSON
        # text IS, and neither side repairs the bytes — and both name the
        # CONDITION rather than an offset: the binary says `input is not
        # well-formed UTF-8 (PROTOCOL.md §1.1 requires it)`, this says
        # `invalid UTF-8 byte sequence`. Neither wording is specified, so
        # neither is wrong; what matters is that both classify it as a READ
        # failure and neither substitutes U+FFFD and carries on.
        #
        # What is shared is asserted in spec/specguard/rspec/validator_backend_spec.rb,
        # under "the not-well-formed-UTF-8 text is each backend's own": same
        # classification, same file, same `FAIL <file> — could not read file: `
        # prefix, a non-empty reason on both sides, and exit 1 — and the tails
        # are asserted to still DIFFER, so converging them fails that file
        # rather than leaving this comment stale.
        unless text.valid_encoding?
          return [Finding.new(file: file, line: 0, problem: "could not read file: invalid UTF-8 byte sequence",
                              kind: Finding::KIND_READ)]
        end

        AnnotationScanner.each_intent(text).map do |line_no, raw, problem|
          if problem
            Finding.new(file: file, line: line_no, problem: problem, kind: Finding::KIND_EXTRACTION)
          else
            parse(raw, file: file, line: line_no)
          end
        end
      end

      # RATIFIED DIFFERENCE from the binary. Two of them, and only the first is
      # a difference in reason TEXT.
      #
      # == (1) The wording, when both parsers reject the payload
      #
      # `PayloadNormalizer` rescues PROTOCOL.md §1's permissive syntax on both
      # sides, so a payload it can fix renders identically. What reaches
      # `JSON.parse` still broken — a bare-word VALUE, a key that is not a key
      # — is described by whichever JSON parser is doing the parsing: this
      # interpolates Ruby's `JSON::ParserError#message`, while the binary uses
      # its own. So `{bad_key}` is `expected object key, got 'bad_key}' at line
      # 1 column 2` here and `expected a double-quoted property name (line 1,
      # column 2)` there.
      #
      # Reproducing that tail would mean carrying a second parser's diagnostics
      # in a gem whose entire reason for vendoring the schema is to owe
      # open-test-intent nothing at runtime — the argument `scan_text` makes
      # about the DECODER, applied verbatim to the PARSER. PROTOCOL.md
      # specifies the accepted LANGUAGE, not the prose a validator refuses in,
      # so two spellings of one refusal are both conformant.
      #
      # What is shared is asserted in
      # spec/specguard/rspec/validator_backend_spec.rb: same classification,
      # same file, same LINE (unlike a read failure, this one is line-scoped and
      # both agree on the line and even the column), same
      # `could not parse annotation: ` prefix, same counts, and exit 1. Only the
      # tail is unpinned.
      #
      # == (2) THE ACCEPTANCE SET: where the two parsers take different input
      #
      # (1) is about how the two spell the same refusal. This is about payloads
      # where they do not both refuse — a bigger difference, and the generator
      # (1) was hiding.
      #
      # This USED to be a three-member set in which the binary was the
      # permissive side, because its parser reproduced a foreign runtime's
      # grammar that `PROTOCOL.md` had never specified. PROTOCOL.md §1.1 states
      # the grammar now: an RFC 8259 JSON text, with the three points that RFC
      # leaves open settled explicitly. The binary refuses the non-finite
      # literals (§1.1(b)), unpaired surrogate escapes (§1.1(a)) and nesting
      # past 100 (§1.1(c)), and `JSON.parse` refuses or limits all three too, so
      # those three have CONVERGED.
      #
      # WHAT SURVIVES RUNS THE OTHER WAY: this parser is now the permissive one.
      #
      # Read that as scoped to PARSING, which is all this register has ever
      # covered. It is not a statement that the two backends agree everywhere
      # else: the stage BEFORE this one diverged too, and in the opposite
      # direction. Until SPGD-512 the binary's `@intent:` payload search was
      # unbounded where {AnnotationScanner#payload_brace} bounds it at the next
      # token, so a malformed token followed by a well-formed one was captured
      # as valid by the binary and reported no-payload by this gem — binary
      # permissive, gem strict. The Go port of that bound closed it. The lesson
      # worth keeping is that a divergence can live at extraction as easily as
      # at parse, so "what survives" below is the parser's list, not the
      # backends' list.
      #
      #   * A LONE LOW surrogate escape (`\udc00`-`\udfff`). `JSON.parse`
      #     accepts it; §1.1(a) refuses it, because a surrogate escape must form
      #     a pair. Ruby refuses only the HIGH half, which is why the rule here
      #     is narrower than "surrogate escapes diverge".
      #   * The nesting BOUNDARY, by exactly one level and only for an EMPTY
      #     container. §1.1(c) refuses any container deeper than 100. Ruby
      #     checks the depth when it is about to parse a VALUE, so a container
      #     sitting at depth 101 with nothing in it is never checked and is
      #     accepted; put anything inside it and Ruby refuses too. Measured on
      #     json 2.21.2 and pinned, both halves, in
      #     `spec/specguard/rspec/validator_backend_spec.rb`.
      #
      # The surrogate one is not merely a verdict difference. What `JSON.parse`
      # returns for `"\udc00"` is a String whose `valid_encoding?` is FALSE: it
      # cannot be re-serialised and cannot cross the ingest transport, so a
      # payload this parser calls valid is one the gem cannot send. That is the
      # cost §1.1(a) exists to remove, and it is still paid on this path.
      #
      # It produces two shapes, depending on whether the payload this parser
      # accepts then passes the schema. BOTH ARE REACHABLE, one per survivor:
      #
      #   (v)  NOT schema-valid — the CLASSIFICATION differs. The NESTING
      #        survivor lands here and only here. A container at depth 101 is
      #        a container, so it can never occupy a schema-legal slot: every
      #        value the schema permits is a string or an array of strings. So
      #        a payload deep enough to diverge is a payload the schema refuses,
      #        and the two tools refuse it for different stated reasons —
      #
      #          binary: "kind": "parse"   nesting is deeper than 100 levels
      #                                    (PROTOCOL.md §1.1(c))
      #          gem:    "kind": "schema"  preconditions[0]: expected type
      #                                    string, got array
      #
      #        The VERDICT agrees (both fail, both exit 1); only the `kind` and
      #        the reason differ.
      #   (vi) schema-valid — the VERDICT differs. The SURROGATE survivor lands
      #        here: it lives inside a string, and a string is what the schema
      #        permits. This path reports nothing and exits 0; the backend
      #        reports a parse failure and exits 1.
      #
      # RATIFIED, and the reason is scope rather than preference.
      # `specguard-lint` validates through the `validate-intent` binary and
      # only the binary, so closing a gap here would be a change to the
      # DEFAULT path, which the slice that introduced `ValidatorBackend`
      # explicitly holds fixed.
      #
      # RETAINED by design, not awaiting deletion. SPGD-96 — the roadmap that
      # owned the binary, and the remover this comment once pointed at —
      # completed 2026-09-06, having carried out the removal it could: the
      # schema-application arm, gone in `c9dca61` ({Linter}'s header records
      # the survivor shape). This input half survived that cutover on purpose:
      # {Scanner.scan_text} is the formatter's `ValidatorError` rescue path
      # ({AnnotationLookup}) and the engine of the suite's validator stub
      # (`spec/support/validator_stub.rb`), and `parse` is its per-token step —
      # removing it would rewrite discovery, not delete dead code.
      #
      # Asserted from both sides — what this parser accepts, the convergence,
      # and both surviving divergences — in
      # `spec/specguard/rspec/validator_backend_spec.rb` under "the JSON
      # acceptance set".
      #
      # Note that `JSON::NestingError` is a subclass of `JSON::ParserError`, so
      # a nesting refusal Ruby DOES make is already carried by the rescue below
      # and needs no clause of its own. That is about the refusals the two
      # share; it is not a claim that the classification always agrees, which
      # at depth 101 it does not — see (v).
      #
      # @return [Finding]
      def parse(raw, file:, line:)
        intent = JSON.parse(PayloadNormalizer.normalize(raw))

        # A bare `[...]` or scalar is syntactically fine JSON but is not an
        # annotation. Reject it here so downstream stages can assume a Hash.
        unless intent.is_a?(Hash)
          return Finding.new(file: file, line: line, kind: Finding::KIND_PARSE,
                             problem: "annotation payload is not an object")
        end

        Finding.new(file: file, line: line, intent: intent)
      rescue ScanError, JSON::ParserError => e
        Finding.new(file: file, line: line, kind: Finding::KIND_PARSE,
                    problem: "could not parse annotation: #{e.message}")
      end

      # == The structural pass: annotations the extraction can never claim
      #
      # Everything above validates each annotation IN ISOLATION — one payload,
      # one verdict. But the formatter's extraction contract
      # ({AnnotationLookup}, SPGD-12 §2) is positional: an annotation reaches
      # an example only through its own line (the trailing form, and only when
      # that line IS the example's) or through the comment-form line
      # IMMEDIATELY ABOVE it. Two shapes fall outside both and are dead the
      # moment they are written — silently discarded by extraction while this
      # pipeline counts them as valid annotations and the run exits 0:
      #
      #   * the STACKED pair (SPGD-897, found in the audit): two consecutive
      #     comment-form `@intent:` lines above one `it` — the UPPER line is
      #     never claimed, because the one-line lookback takes only the line
      #     just above the example. Measured: 16 such stacked pairs shipped
      #     through `specguard-lint` exit 0, every upper contract dead.
      #   * the GROUP line (SPGD-1510, cost SPGD-1475 a full rework round): an
      #     `@intent:` trailing on a `describe`/`context`/… line. The line is
      #     no example's own, and it is not comment-only, so no lookback can
      #     ever claim it — the example beneath it silently ingests as
      #     unannotated. A describe insertion that swallowed a newline is how
      #     the shape is born.
      #
      # Both are reported loudly, not skipped — the same stance
      # {AnnotationScanner} takes for NO_PAYLOAD.
      #
      # A comment-form annotation line is a comment-only line
      # ({AnnotationLookup::COMMENT_LINE}) carrying the `@intent:` token. The
      # trailing same-line form is claimed ONLY when the line itself defines
      # an example ({EXAMPLE_LINE}); there the annotation belongs to its own
      # example's line and the lookback is not involved. On any other line the
      # trailing form is dead too — an example-group line carrying it is now
      # flagged by {GROUP_LINE}'s pass below, with the one-liner exemption
      # ({EXAMPLE_ON_LINE}) keeping `describe "x" do it("y") { } end` claims
      # intact.
      #
      # @param paths [Enumerable<String>]
      # @return [Array<Finding>] one per unreachable annotation, in
      #   file-then-line order. A file that cannot be read contributes
      #   nothing here — {ValidatorBackend} already reports read failures, and
      #   this pass has nothing positional to say about a file it never saw.
      def unreachable_findings(paths)
        paths.flat_map { |path| unreachable_findings_in_file(path) }
      end

      # @param path [String]
      # @return [Array<Finding>]
      def unreachable_findings_in_file(path)
        begin
          text = File.read(path, encoding: "UTF-8")
        rescue SystemCallError, IOError
          return []
        end

        unreachable_findings_in_text(text, file: path)
      end

      UNREACHABLE_ANNOTATION =
        "unreachable annotation: the previous line is also a comment-form @intent:, " \
        "so the one-line lookback claims only the line just above the example " \
        "and this annotation is silently discarded at extraction (SPGD-12 §2)"

      UNREACHABLE_GROUP_ANNOTATION =
        "unreachable annotation: this @intent: sits trailing on an example-group line " \
        "(describe/context/...), and annotations attach to examples, never to groups — " \
        "extraction (SPGD-12 §2) is one-line and example-anchored, so no example can ever " \
        "claim it. Move it onto its example's `it` line, or to the comment line directly " \
        "above that `it`"

      # A comment-only line carrying an `@intent:` token — the only form an
      # example on the NEXT line may claim ({AnnotationLookup::COMMENT_LINE}).
      COMMENT_INTENT_LINE = /\A\s*#.*@intent:/

      # The line an annotation run may be claimed from: the first example
      # keyword. The lookback rule is `example.metadata[:line_number] - 1`, so
      # only the comment form on the line immediately above an example is
      # inheritable — which makes an EXAMPLE the anchor of the whole rule.
      #
      # Anchoring on the example is what keeps this pass off annotation
      # corpora with no examples at all (the recorded-binary fixtures in
      # spec/fixtures/): there is no lookback there to silently discard
      # anything, so there is nothing to report. The defects this pass exists
      # for are annotations an author believed were attached to a real
      # example: stacked lines above it (SPGD-897), and the trailing form on
      # a group line directly above it (SPGD-1510).
      EXAMPLE_LINE = /\A\s*(?:it|specify)\b/

      # @param text [String] source of one file
      # @param file [String] path to record on each Finding
      # @return [Array<Finding>] the structural findings for one file, in line
      #   order: one per comment-form `@intent:` line in a stacked run (see
      #   {stacked_findings_in_text}) plus one per group line carrying the
      #   trailing form (see {group_line_findings_in_text}). The two passes
      #   are disjoint by construction — one reads only comment-only lines,
      #   the other only lines that are not — so the merge cannot double-flag
      #   a line, and the sort restores the file-then-line order
      #   {unreachable_findings} promises.
      def unreachable_findings_in_text(text, file:)
        # A file that is not valid UTF-8 is reported once, loudly, by the
        # backend as a read failure; nothing positional can be said about it,
        # and `lines` below would raise on the invalid bytes.
        return [] unless text.valid_encoding?

        (stacked_findings_in_text(text, file: file) +
         group_line_findings_in_text(text, file: file)).sort_by(&:line)
      end

      # @param text [String] source of one file
      # @param file [String] path to record on each Finding
      # @return [Array<Finding>] one per comment-form `@intent:` line in a
      #   stacked run — a maximal run of consecutive comment-form `@intent:`
      #   lines immediately above an example — except the run's LAST line,
      #   which is the one the one-line lookback claims. For the canonical
      #   two-line stack above one `it`, that is the UPPER line.
      def stacked_findings_in_text(text, file:)
        # A file that is not valid UTF-8 is reported once, loudly, by the
        # backend as a read failure; nothing positional can be said about it,
        # and `lines` below would raise on the invalid bytes.
        return [] unless text.valid_encoding?

        lines = text.lines
        i = 0
        findings = []

        while i < lines.length
          unless COMMENT_INTENT_LINE.match?(lines[i])
            i += 1
            next
          end

          run_start = i
          i += 1 while i < lines.length && COMMENT_INTENT_LINE.match?(lines[i])
          run_end = i # exclusive; lines[run_end] is the line after the run

          if run_end < lines.length && EXAMPLE_LINE.match?(lines[run_end]) && run_start < run_end - 1
            (run_start...(run_end - 1)).each do |j|
              findings << Finding.new(file: file, line: j + 1, problem: UNREACHABLE_ANNOTATION,
                                      kind: Finding::KIND_UNREACHABLE)
            end
          end
        end

        findings
      end

      # RSpec's example-group keywords, at the start of a line and optionally
      # `RSpec.`-prefixed. A line matching this hosts a GROUP, not an example
      # — and {AnnotationLookup}'s extraction can claim an annotation only
      # from an example's own line or the comment-only line above it, so an
      # `@intent:` written here is unreachable wherever it sits on the line.
      GROUP_LINE =
        /\A\s*(?:RSpec\.)?(?:describe|context|feature|shared_examples|shared_examples_for|shared_context|example_group)\b/

      # A token WITH its payload opener: what the rest of the pipeline treats
      # as an annotation on a group line. The `{` is load-bearing — a bare
      # `@intent:` token is a {AnnotationScanner::NO_PAYLOAD} extraction
      # failure the main pipeline already reports loudly, and (because
      # extraction is marker-based, SPGD-8 §7) the token is ALSO found inside
      # quoted strings: this repo's own suite carries
      # `describe "unreachable stacked @intent: annotations"`, which is prose,
      # not an annotation, and must not read as one. A line matching this is
      # one the scanner captured a payload from (or began capturing one),
      # which is the population this pass has standing to judge. The naive
      # search inherits the scanner's string-literal limitation in the exotic
      # direction only: a group line whose prose embeds `@intent: {` reads as
      # annotated (a flag the pipeline independently agrees with, since
      # extraction captures that literal too), never the reverse.
      INTENT_WITH_PAYLOAD = /@intent:\s*\{/

      # The one-liner exemption: a group line that ALSO defines an example on
      # the same line is that example's own line, so its trailing annotation
      # is claimed by the example and must not be flagged:
      #
      #   describe "one" do it("x") { } end # @intent: { ... }
      #
      # Two guards keep prose from reading as an example call. The match runs
      # against the code BEFORE the `@intent:` token — the payload is English
      # an author wrote about a behavior ("...when it's given one"), and
      # reading `it'` there as a call exempted the exact group-line shape
      # this pass exists to flag. And the call must sit after a block opener
      # (`do`, `{`, `;`), because the description string is part of the code
      # side too: `describe "the cost of rendering it" do` ends in the word
      # `it`, and `it"` is not a call. What this heuristic still cannot see:
      # a description string containing the literal sequence `do it` /
      # `do specify` (or `{ it`), as in `describe "how to do it right" do`,
      # still reads as a call and is wrongly exempted — a missed flag, and
      # only ever a missed flag: prose can turn the exemption ON, never a
      # real example OFF. The one-line example's own payload is never
      # consulted, so a payload can never exempt anything.
      EXAMPLE_ON_LINE = /(?:\bdo\b|\{|;)\s*(?:it|specify)\b/

      # @param text [String] source of one file
      # @param file [String] path to record on each Finding
      # @return [Array<Finding>] one per example-group line carrying an
      #   `@intent:` token, for lines that define no example of their own
      #   ({EXAMPLE_ON_LINE}). Comment-only lines are left to
      #   {stacked_findings_in_text}: a comment above a group is a different
      #   shape, deliberately out of scope here (SPGD-1510 flags the group
      #   line ITSELF).
      def group_line_findings_in_text(text, file:)
        # Same UTF-8 contract as the stacked pass above.
        return [] unless text.valid_encoding?

        text.lines.each_with_index.filter_map do |line, idx|
          # Comment-only lines belong to the stacked pass; this pass reads the
          # group line ITSELF. (A `#`-leading line could never match
          # GROUP_LINE anyway — the guard states the division, not a filter.)
          next if line.lstrip.start_with?("#")
          next unless GROUP_LINE.match?(line)
          next unless INTENT_WITH_PAYLOAD.match?(line)
          # The exemption sees the code before the token; the payload and
          # anything after it are prose and must never read as an example
          # call. The token is guaranteed present (INTENT_WITH_PAYLOAD just
          # matched), so `split` always yields the code side.
          code = line.split("@intent:", 2).first
          next if EXAMPLE_ON_LINE.match?(code)

          Finding.new(file: file, line: idx + 1, problem: UNREACHABLE_GROUP_ANNOTATION,
                      kind: Finding::KIND_UNREACHABLE)
        end
      end
    end
  end
end
