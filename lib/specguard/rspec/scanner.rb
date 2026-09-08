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
      #   A path that exists and is NOT A REGULAR FILE lands in the same rescue
      #   and is the same ratified difference one step further out: this rescue
      #   has an errno and reports it (`Is a directory @ io_fread - <path>`),
      #   while the binary's glob filters non-regular matches away and answers
      #   exactly as it does for a name matching nothing. Ruby tells the two
      #   apart and the backend cannot — asserted under "a path that is not a
      #   regular file" in that same spec.
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
      # ({AnnotationLookup}, SPGD-12 §2) is positional: only the comment-form
      # annotation on the line IMMEDIATELY ABOVE an example is inheritable.
      # So when two consecutive comment-form `@intent:` lines sit above one
      # `it`, the UPPER line is unreachable — silently discarded by the
      # one-line lookback — while this pipeline counts it as a valid
      # annotation and the run exits 0. Measured (SPGD-897 audit): 16 such
      # stacked pairs shipped through `specguard-lint` exit 0, every upper
      # contract dead. Reported loudly, not skipped — the same stance
      # {AnnotationScanner} takes for NO_PAYLOAD.
      #
      # A comment-form annotation line is a comment-only line
      # ({AnnotationLookup::COMMENT_LINE}) carrying the `@intent:` token. The
      # trailing same-line form never matches COMMENT_LINE, so it is never
      # flagged and never makes a neighbour unreachable — its annotation
      # belongs to its own example's line and the lookback is not involved.
      #
      # @param paths [Enumerable<String>]
      # @return [Array<Finding>] one per unreachable comment-form annotation,
      #   in file-then-line order. A file that cannot be read contributes
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
      # anything, so there is nothing to report. The defect this pass exists
      # for (SPGD-897) is stacked lines above a real example — an annotation
      # the author believed was attached to the `it` under it.
      EXAMPLE_LINE = /\A\s*(?:it|specify)\b/

      # @param text [String] source of one file
      # @param file [String] path to record on each Finding
      # @return [Array<Finding>] one per comment-form `@intent:` line in a
      #   stacked run — a maximal run of consecutive comment-form `@intent:`
      #   lines immediately above an example — except the run's LAST line,
      #   which is the one the one-line lookback claims. For the canonical
      #   two-line stack above one `it`, that is the UPPER line.
      def unreachable_findings_in_text(text, file:)
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
    end
  end
end
