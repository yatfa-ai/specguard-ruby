# frozen_string_literal: true

require "json"

module SpecGuard
  module RSpec
    # The shared verdict shape both renderers and the exit code derive from.
    #
    # == Where this sits after SPGD-867 (the cutover)
    #
    # This used to be a class that APPLIED the schema to Findings the Ruby
    # scanner had produced. That Ruby hand-rolled validation arm is gone:
    # `specguard-lint` validates through the `validate-intent` binary and only
    # the binary ({ValidatorBackend}), and the formatter's half
    # ({AnnotationLookup}) asks the same binary. What survives is the one
    # thing both sides of the seam still share — {Result}, the single shape
    # the reporter and the exit code are both derived from, so "what was
    # printed" and "what we exited with" cannot drift apart.
    #
    # == What counts as a failure
    #
    # Three things make an annotation malformed, reaching the same verdict
    # from different directions:
    #
    #   * the payload could not be captured off the line at all
    #     (`Finding::KIND_EXTRACTION`) — a typo'd annotation;
    #   * it was captured but is not JSON even after normalization
    #     (`Finding::KIND_PARSE`);
    #   * it parsed but violates the schema.
    #
    # All three are "an annotation is malformed", which the contract fixes at
    # exit 1. A **missing** annotation is not among them — "lint, don't
    # require" (SPGD-12 §1): a file with no `@intent:` at all is clean.
    #
    # `Finding::KIND_READ` — a spec file that could not be opened or is not
    # valid UTF-8 — is also reported as a failure, and therefore also exits 1.
    # That matches `validate-intent`, which classifies it separately (its own
    # `read` kind) and still reports it as `FAIL` with exit 1.
    #
    # `Finding::KIND_UNREACHABLE` — an annotation that is well-formed in
    # isolation but can never be extracted, so the one-line lookback
    # (SPGD-12 §2) never claims it — is also reported as a failure, and
    # therefore also exits 1. Two shapes reach this kind: a comment-form
    # `@intent:` stacked above another comment-form `@intent:` line (SPGD-900),
    # and an `@intent:` trailing on an example-group line, which is no
    # example's own and not comment-only (SPGD-1510). Nothing about either is
    # malformed; the contract is dead metadata, counted by the linter and
    # discarded by extraction, and the structural pass that flags them
    # (SPGD-900, SPGD-1510) reports it loudly rather than letting it pass as
    # clean.
    module Linter
      # One annotation's verdict. `problem` is set when discovery could not
      # produce an intent at all; `reasons` when the schema rejected one.
      # They are mutually exclusive by construction.
      #
      # `intent` is WHAT THE PAYLOAD PARSED TO, carried alongside the verdict
      # rather than left for a second parser to re-derive. It is nil when there
      # was no payload (any `problem`), and — like the port's `intent` key — it
      # is populated even when `reasons` is not empty: a schema-rejected
      # annotation did parse, and `ok?` already reports the verdict.
      Result = Data.define(:file, :line, :kind, :problem, :reasons, :intent) do
        def initialize(file:, line:, kind: nil, problem: nil, reasons: [], intent: nil)
          super
        end

        def ok?
          problem.nil? && reasons.empty?
        end

        def failed?
          !ok?
        end

        # A read failure is not line-scoped: nothing in the file was ever seen,
        # and slice 1's `line` is a 0 sentinel rather than a location. The
        # binary drops the line for exactly these findings (`JSONFinding` in
        # open-test-intent's cmd/validate-intent/report.go — "`line` is null
        # where a finding is not line-scoped, `kind` is null on a passing
        # finding"), and `:0` is not somewhere a reader can go: anything
        # parsing `file:line` — CI annotations, editor quickfix, review
        # comments — would point at a line that does not exist.
        #
        # This is what makes `kind` load-bearing rather than decorative.
        #
        # The rule is a predicate rather than an inline comparison because it
        # has two renderers: `CLI#report_failure` prints `file` instead of
        # `file:0`, and `JSONReporter` emits `"line": null` for the same
        # findings. Spelling `kind == Finding::KIND_READ` in both would let one
        # of them keep emitting the sentinel after the rule changed here.
        def line_scoped?
          kind != Finding::KIND_READ
        end

        def location
          line_scoped? ? "#{file}:#{line}" : file
        end

        # The nesting budget a payload gets, well under `JSON.generate`'s
        # default ceiling of 100.
        #
        # The margin is deliberate rather than tight. Both renderers WRAP the
        # payload before generating it — {JSONReporter} in `findings[] ->
        # finding -> intent` and {Formatter} in `specs[] -> spec -> intent`,
        # three levels each — so a payload probed at the bare ceiling would be
        # accepted here and still raise there. Budgeting 32 leaves either
        # envelope room to grow without silently re-opening this hole.
        #
        # It costs nothing real: the schema admits four string values and
        # nothing nested, so every payload a consumer could act on is depth 1.
        # Anything deep enough to be refused here was already schema-invalid;
        # this only decides whether its finding also carries the value.
        MAX_INTENT_DEPTH = 32

        # The intent, but only when it is a value this gem can actually hand on
        # — nil otherwise.
        #
        # Parsing a payload is not the same as being able to REPRODUCE it, and
        # Ruby draws that line in a place the validator does not. Three classes
        # clear the binary's verdict AND then detonate at the point of USE:
        #
        # * a lone LOW surrogate (`"\udc00Or"`) — the report parser may accept
        #   it and hand back a String whose `valid_encoding?` is false, and
        #   `JSON.generate` refuses that same value with `source sequence is
        #   illegal/malformed utf-8`;
        # * a non-finite Float — {ValidatorBackend}'s parse options set
        #   `allow_nan: true` on the way IN, while generate's default is
        #   `allow_nan: false` on the way OUT;
        # * a container nested past the generator's `max_nesting` — the same
        #   asymmetry, since those parse options also set `max_nesting: false`.
        #
        # The last two are the parse options' own doing. Relaxing the parse side
        # without relaxing the generate side does not remove the failure, it
        # MOVES it — out of the parser, where it costs one annotation its
        # payload, and into the generator, where it costs the whole batch its
        # document and its exit code. Admitting a value we cannot then emit is
        # strictly worse than never admitting it.
        #
        # So the question is ASKED rather than enumerated: hand the value to
        # the generator and see whether it comes back. A predicate that lists the
        # known-bad shapes is a list somebody has to keep complete, and the two
        # cases above are exactly what that list missed while covering the
        # first. `JSON.generate` is not an approximation of the oracle here, it
        # IS the call both renderers go on to make.
        #
        # Answered here, once, because BOTH renderers need it and neither is the
        # natural owner. Nothing is substituted — a repaired payload is one the
        # author did not write, and shipping it is indistinguishable downstream
        # from shipping the right one (KB SPGD-78). Unshippable means
        # unannotated.
        def representable_intent
          intent unless unrepresentable?(intent)
        end

        private

        # `NestingError` is rescued alongside `GeneratorError` rather than
        # folded into it: despite being what the GENERATOR raises past
        # max_nesting`, it descends from `JSON::ParserError`, so catching
        # `GeneratorError` alone would let the over-deep case straight through.
        def unrepresentable?(value)
          JSON.generate(value, max_nesting: MAX_INTENT_DEPTH)
          false
        rescue JSON::GeneratorError, JSON::NestingError
          true
        end
      end
    end
  end
end
