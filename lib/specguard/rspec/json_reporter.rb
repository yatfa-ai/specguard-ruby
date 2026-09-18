# frozen_string_literal: true

require "json"

module SpecGuard
  module RSpec
    # `specguard-lint --json`: the machine-readable renderer over the same
    # `Array<Linter::Result>` the text report is built from.
    #
    # == Why this is a renderer and not a feature
    #
    # {CLI#check} has exactly one branch on which validator produced the
    # verdicts, and it closes immediately: both arms return the same
    # {Linter::Result} list. Everything downstream of it — the FAIL blocks, the
    # summary line, the exit code — is shared code rather than two renderers
    # that have to be kept in step. This hangs off that same point, so it
    # inherits that guarantee: the `--json` document and the text report are the
    # *same checks* rendered twice, not a second implementation that can drift.
    #
    # What the text renderer destroys at the print site is the structure. A
    # {Linter::Result} carries file, line, kind, problem and reasons; the FAIL
    # block flattens all five into prose, leaving a consumer the exit code and a
    # regex. `kind` is the field that suffers most — {Finding}'s own comment
    # says it is carried "because a failed extraction and an unparseable payload
    # both land in `problem`, which makes the two indistinguishable downstream
    # once flattened to prose", and then the CLI flattens it to prose.
    #
    # == The shape, and why it is the port's shape
    #
    # This mirrors `validate-intent --json --source`
    # (open-test-intent, `cmd/validate-intent/report.go`) key for key:
    #
    #   {"schema", "mode", "ok", "summary": {"files", "annotations", "failed"},
    #    "findings": [{"file", "line", "ok", "kind", "errors", "intent"}, ...]}
    #
    # The gem is already a *consumer* of exactly this document —
    # {ValidatorBackend::Runner} runs `--source --json` and reconstructs
    # {Linter::Result}s from it — so emitting a different shape would mean a
    # consumer of both tools needs two parsers for one protocol. It does not
    # try to be byte-identical to the binary's document, only key-, type- and
    # value-identical, which is what a parser sees.
    #
    # Three properties are load-bearing for a consumer and are asserted rather
    # than described (`spec/specguard/rspec/cli_spec.rb`):
    #
    #   * `errors` is ALWAYS a list of strings — `reasons` when the schema
    #     rejected the annotation, `[problem]` when discovery could not produce
    #     one at all, `[]` when it passed. Never null, never a bare string:
    #     `JSONFinding` (open-test-intent, `cmd/validate-intent/report.go`) is
    #     explicit that a consumer must never branch on its type, and this is
    #     the one place the gem's mutually-exclusive `problem`/`reasons` pair
    #     is normalised into the port's single list.
    #   * `line` is null exactly where the finding is not line-scoped, which is
    #     {Linter::Result#line_scoped?} — the same rule `#location` uses to
    #     print `file` rather than `file:0`. `:0` is not somewhere a reader can
    #     go, and emitting it here would hand every CI annotation and quickfix
    #     consumer a line that does not exist.
    #   * `kind` is null on a passing finding and one of `extraction`, `parse`,
    #     `read`, `schema` otherwise. The port has a fifth, `no-match`, which
    #     cannot appear here: {ValidatorBackend} maps it onto
    #     {Finding::KIND_READ} at the seam, because on this side of it a path
    #     that matched nothing *is* a named path that could not be opened.
    #
    # == The counts are handed in, not recomputed
    #
    # `summary.files` and `summary.annotations` are passed by {CLI}, which
    # computes them once for both renderers. Recounting them here would let the
    # text summary line and this document disagree about the same run, which is
    # the failure mode the shared-downstream design exists to prevent — and a
    # disagreement between two renderers of one result list is unfalsifiable
    # from the outside.
    #
    # `ok` is likewise handed in, derived from the exit code the text path would
    # also have produced rather than recomputed from the findings, following
    # `Emit` (open-test-intent, `cmd/validate-intent/report.go`) for the same
    # reason.
    #
    # `summary.failed`, by contrast, is counted here — from the findings this
    # document actually emitted, so `failed` always equals the number of entries
    # with `"ok": false`. Note that it is NOT the text summary's "M malformed":
    # that clause counts malformed *annotations* and reports unreadable files in
    # a separate clause, while `failed` counts every failing finding, read
    # failures included, exactly as the port's `Emit` does. Two different
    # questions, each answered the same way in both implementations.
    #
    # == What is deliberately NOT in the document
    #
    # The backend provenance line (SPGD-247 — one stderr line per run naming the
    # implementation that produced the verdicts) is not duplicated in here.
    # Two reasons, and the decision is recorded rather than defaulted into:
    # it would be the first key by which this document differs from the port's,
    # reintroducing the second parser this shape exists to avoid; and provenance
    # would then have two homes that can disagree about one fact, which is the
    # shape SPGD-247 was written to close, not to widen. `2>` the stderr stream
    # and read the line; it is still exactly one line, on every run, on both
    # arms.
    module JSONReporter
      # The port's `jsonSchemaID` (open-test-intent,
      # `cmd/validate-intent/report.go`), and the basename of the
      # gem's own vendored schema. Pinned to each other by a spec: the document
      # names the protocol it validated against, so it must not be able to name
      # one the gem does not carry.
      SCHEMA_ID = "open-test-intent.v1.json"

      # The port's `--source` mode: annotations found in spec *sources*, which
      # is the only thing `specguard-lint` does. It is not the *selection* mode
      # (`--changed` vs explicit files) — that is this tool's own vocabulary and
      # the port has no field for it. Emitting `"changed"` here would tell a
      # consumer that already reads `validate-intent --json` that it is looking
      # at a mode that does not exist.
      MODE = "source"

      # @param results [Array<Linter::Result>] every verdict, in discovery order
      # @param files [Integer] spec files selected — the count the text path
      #   states in its leading `checked N spec file(s)` line
      # @param annotations [Integer] annotation sites examined — the count the
      #   text path states in its trailing summary line
      # @param ok [Boolean] whether the run passed, derived from the exit code
      # @return [String] one JSON document, without a trailing newline
      def self.render(results, files:, annotations:, ok:)
        findings = results.map { |result| finding(result) }

        JSON.pretty_generate(
          "schema" => SCHEMA_ID,
          "mode" => MODE,
          "ok" => ok,
          "summary" => {
            "files" => files,
            "annotations" => annotations,
            "failed" => findings.count { |entry| !entry["ok"] }
          },
          "findings" => findings
        )
      end

      # @param result [Linter::Result]
      # @return [Hash] one `findings` entry
      def self.finding(result)
        {
          "file" => result.file,
          "line" => result.line_scoped? ? result.line : nil,
          "ok" => result.ok?,
          "kind" => result.kind&.to_s,
          "errors" => errors(result),
          # {Linter::Result#representable_intent}, not `intent`: a payload
          # holding a lone low surrogate parses in Ruby and then cannot be
          # GENERATED, so emitting it raw would raise here and take the whole
          # document with it — a `--json` run that dies rendering a finding it
          # had already decided about. Null is the same answer this document
          # gives for every other payload it does not have.
          "intent" => result.representable_intent
        }
      end

      # `problem` and `reasons` are mutually exclusive by construction and mean
      # the same thing to a consumer — why this finding failed. `kind` is what
      # tells them apart, so both collapse into the one list here and nothing is
      # lost. The port's `RunSourceJSON` performs the identical collapse, and
      # {ValidatorBackend} performs its inverse when reading the port's output.
      #
      # @param result [Linter::Result]
      # @return [Array<String>]
      def self.errors(result)
        return [result.problem] if result.problem

        result.reasons
      end

      private_class_method :finding, :errors
    end
  end
end
