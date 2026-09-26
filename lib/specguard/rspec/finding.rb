# frozen_string_literal: true

module SpecGuard
  module RSpec
    # One `@intent:` annotation, located and (where possible) parsed.
    #
    # Exactly one of `intent` and `problem` is non-nil:
    #
    #   * `intent`  — the parsed annotation as a Hash with String keys. Says
    #     nothing about whether it is *valid*; schema validation is a later
    #     stage, so a Finding with an `intent` may still be rejected then.
    #   * `problem` — why this annotation could not be turned into a Hash at
    #     all, as a human-readable sentence.
    #
    # `kind` names *how* it failed and is nil when it did not. It is carried
    # here rather than reconstructed by the caller because a failed extraction
    # and an unparseable payload both land in `problem`, which makes the two
    # indistinguishable downstream once flattened to prose.
    #
    # `line` is the 1-based line the annotation sits on — except under
    # {KIND_READ}, where nothing in the file was ever seen and
    # {Scanner.scan_file} / {Scanner.scan_text} construct the Finding with a
    # `line` of 0. That 0 is a sentinel standing in for "no line", not a
    # position anything can be pointed at.
    #
    # NOTE: this is a subclass of an anonymous `Data.define` rather than a
    # `Data.define do ... end` block, because a constant assigned inside that
    # block binds to the *lexically* enclosing module (SpecGuard::RSpec) rather
    # than to the value class — so KIND_EXTRACTION below would silently not be
    # `Finding::KIND_EXTRACTION`.
    class Finding < Data.define(:file, :line, :intent, :problem, :kind)
      # The annotation's payload could not be captured off the line at all
      # (unterminated literal, or no `{...}` after the token).
      KIND_EXTRACTION = :extraction

      # The payload was captured but is not JSON even after normalization.
      KIND_PARSE = :parse

      # The file itself could not be read (missing, unopenable, or not valid
      # UTF-8), so no annotation in it was ever seen. Distinct from
      # {KIND_EXTRACTION} — nothing here is a claim about an annotation — and
      # named after the `read` kind the validator's `--json` report carries, so
      # the two classifications line up.
      KIND_READ = :read

      # The payload parsed but violates the OpenTestIntent schema. Not produced
      # by discovery — {Linter} stamps it — but it lives here so the full set
      # of ways an annotation can fail is written down in one place.
      KIND_SCHEMA = :schema

      # The annotation is well-formed in isolation but can never be EXTRACTED.
      # Two shapes, both dead the moment they are written:
      #
      #   * a comment-form `@intent:` stacked above another comment-form
      #     `@intent:` line, so the one-line lookback (SPGD-12 §2 —
      #     {AnnotationLookup} claims only the comment on the line immediately
      #     above an example) always skips it in favour of the lower line;
      #   * an `@intent:` trailing on an example-group line
      #     ({Scanner::GROUP_LINE} — SPGD-1510): a group line is no example's
      #     own and is not comment-only, so no extraction rule can ever reach
      #     it, and the example beneath it silently ingests unannotated.
      #
      # Either way the contract is dead metadata: counted by the linter,
      # discarded by extraction. Produced by {Scanner}'s structural pass, not
      # by {AnnotationScanner} — each annotation is scanned in isolation
      # there, which is exactly why these defects are invisible to it.
      KIND_UNREACHABLE = :unreachable

      def initialize(file:, line:, intent: nil, problem: nil, kind: nil)
        super
      end

      # True when the annotation yielded a Hash. Not a claim that it is *valid*.
      def extracted?
        problem.nil?
      end

      def problem?
        !problem.nil?
      end

      # Deliberately no `#location` here. Rendering `file:line` off a Finding
      # prints `file:0` for the {KIND_READ} sentinel above, and `:0` is not
      # somewhere a reader can go — anything parsing `file:line` would be sent
      # to a line that does not exist. {Linter::Result#line_scoped?} is where
      # that rule lives, and both renderers that obey it ({CLI#report_failure}
      # and {JSONReporter}) are sited on that object so neither can drift from
      # it. A copy of the predicate on this one is the third spelling that
      # comment warns against, so render a Finding through {Linter::Result}.
    end
  end
end
