# frozen_string_literal: true

require "json"

module SpecGuard
  module RSpec
    # `specguard-ingest --json`: the machine-readable renderer over the same
    # per-line facts the human report is built from.
    #
    # == Why a second renderer, on the one command that most needed it
    #
    # An HTTP 400 is the only *permanent* verdict in this command's contract
    # ({IngestCLI::CONTENT_REFUSAL_CODES}) — a refused line is refused every
    # time it is offered — so the only way to land the run is to learn which
    # specs the platform objected to and fix the payload. The platform sends one
    # error per offending spec, each naming it by index, file and line
    # (`Ingest::Payload#label`, and `Api::BaseController#render_bad_request`
    # puts every one of them on the wire). {Transport::Result} keeps the whole
    # array, and then {Transport::Result#reason} renders three of them,
    # truncated to 300 characters, because it is built for the **one stderr
    # line an in-run CI warning is allowed**.
    #
    # That cap is right where it was set and is not touched here. It is a cap on
    # a *line*, and this document is not a line: `specguard-ingest` already
    # prints a row per line, a summary and its folding observations, out of band
    # and nowhere near a CI log. So the refusal's own grounds do not reach a
    # second channel, and this is that channel — the command whose entire job is
    # to fix and re-send a refused run can now show you all of why it was
    # refused.
    #
    # This is SPGD-305 done again for the gem's other executable, and it is a
    # RENDERER: it reads the {IngestCLI::LineResult}s the delivery already
    # produced and the {IngestCLI::ListedLine}s the listing already extracted,
    # and decides nothing. The exit code, the statuses, the selection and the
    # cap are all upstream of here and identical on both paths.
    #
    # == Why it is NOT `json_reporter.rb`
    #
    # {JSONReporter} is the *lint* document over `Linter::Result`, and it mirrors
    # `validate-intent --json --source` key for key on purpose: the gem consumes
    # that document, so the two must not need two parsers. This one is about
    # **deliveries**, not annotations. It therefore does not claim that
    # document's `"schema" => "open-test-intent.v1.json"` or its
    # `"mode" => "source"` — naming a schema this document has nothing to do
    # with would assert a conformance it cannot have. `"tool"` says what wrote
    # it instead.
    #
    # == There is no `ok` and no `exit_code` in the document
    #
    # Deliberately, and this is the one place the two renderers differ in kind
    # rather than in form. {JSONReporter} carries an `ok` because a linter's
    # verdict is a boolean. This command's is not: 0, 1 and 2 mean "accepted",
    # "the platform refused content" and "this tool could not do its job", and
    # collapsing that to a boolean would have to pick which of 1 and 2 counts as
    # false — the exact confusion {IngestCLI}'s class comment is arranged
    # against. Restating the integer here would be a second copy of a fact the
    # process already exits with, free to drift from it. So the exit status
    # stays the one carrier of the verdict, unchanged by this flag, and the
    # document carries the facts it is computed from.
    #
    # == Which runs emit a document
    #
    # By cause, not by exit code. {JSONReporter}'s rule — a run that checked
    # nothing must not emit `{"findings": []}`, because that is how a gate that
    # checked nothing gets mistaken for one that found nothing — transfers, but
    # it does not transfer as "no exit-2 run emits a document": this command
    # reaches 2 with a *real* report on a file whose lines were delivered and
    # one of them never arrived.
    #
    # So the line is drawn where the file was: a run that got as far as reading
    # <file> emits a document, whatever its exit code and even when the file
    # held nothing to deliver (`"lines": []` next to a `summary` of zeroes is a
    # true statement about an empty file, and the warning naming *why* it was
    # empty is on stderr either way). A run that never got that far — a bad
    # flag, `--from-line` with `--lines`, no endpoint or API key, a file that
    # cannot be read — emits prose on stderr and nothing at all on stdout,
    # because there is nothing yet to be a document about.
    #
    # == The counts are handed in, not recomputed
    #
    # `summary`'s status counts are the ones {IngestCLI} computes once for
    # whichever renderer runs, for {JSONReporter}'s reason: two renderers of one
    # result list that can disagree about how much of a file was delivered are
    # worse than prose alone, because the disagreement is unfalsifiable from
    # outside the process. That holds on the listing path too, where the only
    # count that can be positive is `unparseable` and the text summary states no
    # counterpart to disagree with — it is handed in anyway, so the discipline
    # is structural at both entry points rather than true of one by luck. The
    # folding observations are the same shape of thing — one grouping, rendered
    # here as data and there as a sentence.
    module IngestReporter
      # What wrote the document. Not a schema id: see the class comment.
      TOOL = "specguard-ingest"

      # Whether lines were sent or only shown. The distinction a consumer most
      # needs, because it decides whether the status counts below are verdicts
      # or zeroes — see {#summary}'s `attempted`.
      MODE_DELIVER = "deliver"
      MODE_LIST = "list"

      # A listed line that is a run. Its delivery-side counterparts are
      # {IngestCLI::STATUS_LABELS}' keys, rendered by name (`undelivered`, not
      # the prose renderer's `not delivered`) so a consumer branches on the
      # tool's vocabulary rather than on its wording.
      STATUS_LISTED = "listed"
      STATUS_UNPARSEABLE = "unparseable"

      # @param source [IngestCLI::Source] the file, its blanks, its skips and
      #   the typed lines it does not have
      # @param results [Array<IngestCLI::LineResult>] one per line delivered,
      #   in the file's order
      # @param counts [Hash{Symbol=>Integer}] status counts, computed once by
      #   {IngestCLI} for both renderers
      # @param foldings [Array<IngestCLI::Folding>] the folding observations,
      #   grouped once for both renderers
      # @return [String] one JSON document, without a trailing newline
      def self.render_delivery(source:, results:, counts:, foldings:)
        document(
          mode: MODE_DELIVER,
          source: source,
          lines: results.map { |result| delivered(result) },
          summary: summary(source, lines: results.length, counts: counts, attempted: attempted(counts)),
          foldings: foldings.map { |folding| folded(folding) }
        )
      end

      # @param source [IngestCLI::Source]
      # @param lines [Array<IngestCLI::ListedLine>] the envelope facts the text
      #   listing prints, extracted once for both renderers
      # @param counts [Hash{Symbol=>Integer}] status counts, computed once by
      #   {IngestCLI} for both renderers — `unparseable` is the only one a
      #   listing can carry
      # @return [String] one JSON document, without a trailing newline
      def self.render_listing(source:, lines:, counts:)
        # Every delivery status is 0 and `attempted` is 0, which is this
        # document's way of saying what the text listing says in words:
        # nothing was delivered. `unparseable` is the one that can be positive,
        # because a line that is not a run is knowable without sending it — and
        # it is stated for the reason the text row states it, so a preview
        # cannot under-report what the delivery would do.
        document(
          mode: MODE_LIST,
          source: source,
          lines: lines.map { |line| listed(line) },
          summary: summary(source, lines: lines.length, attempted: 0, counts: counts),
          foldings: []
        )
      end

      def self.document(mode:, source:, lines:, summary:, foldings:)
        JSON.pretty_generate(
          "tool" => TOOL,
          "mode" => mode,
          "file" => source.path,
          "summary" => summary,
          "lines" => lines,
          "foldings" => foldings
        )
      end

      # `lines` is the rows in this document; `attempted` is how many of them
      # were offered to the endpoint. The pair is what keeps the four status
      # counts readable: three zeroes under `"mode": "list"` mean "nothing was
      # sent", and the same three under a delivery of 40 lines would mean
      # something very different.
      #
      # `blank` and `skipped` are the two ways a line of <file> is not a row
      # here. They are stated always, and for the reason {IngestCLI::Source}
      # counts rather than drops them: a summary that quietly narrows what it is
      # summarising is the failure this command is arranged against.
      #
      # `absent` is that same rule pointed the other way — at the numbers that
      # were typed rather than at the lines that were read. A `--lines` entry
      # naming past the end of the file is held back by nothing and read as
      # nothing, so `skipped` (which counts lines of <file>) structurally cannot
      # carry it, and without this key a satisfied selector and a phantom one
      # render the identical document. It is `null` rather than `[]` where the
      # selector was fully satisfied, on {#selector}'s terms: a fact that does
      # not apply is absent, never a fabricated empty.
      def self.summary(source, lines:, counts:, attempted:)
        {
          "lines" => lines,
          "attempted" => attempted,
          "accepted" => counts.fetch(:accepted, 0),
          "refused" => counts.fetch(:refused, 0),
          "undelivered" => counts.fetch(:undelivered, 0),
          "unparseable" => counts.fetch(:unparseable, 0),
          "blank" => source.blank,
          "skipped" => source.skipped,
          "absent" => absent(source),
          "selector" => selector(source)
        }
      end

      # The typed line numbers the file does not have, in the shorthand they
      # were typed in and computed by {IngestCLI} once for both renderers — the
      # discipline the counts above are held to, applied to the one fact the
      # text summary and this document could otherwise disagree about.
      #
      # @return [Array<String>, nil]
      def self.absent(source)
        source.absent.empty? ? nil : source.absent
      end

      # Every line that reached the endpoint, which is every line except the
      # ones that were never a run.
      def self.attempted(counts)
        counts.fetch(:accepted, 0) + counts.fetch(:refused, 0) + counts.fetch(:undelivered, 0)
      end

      # Which flag held lines back, named on exactly the terms the text summary
      # names it: only when it demonstrably held something back. `--from-line`
      # defaults to 1 when it was not given at all, so reporting it
      # unconditionally would claim a selector the user never typed.
      #
      # @return [String, nil]
      def self.selector(source)
        return nil unless source.skipped.positive?

        source.selector == :line_set ? "--lines" : "--from-line"
      end

      # One delivered line.
      #
      # `code` is the HTTP status, and `null` where there is not one: a line
      # that was never a run, and a delivery that never got an answer at all
      # (connection refused, DNS, TLS, a timeout). Together with `status` it is
      # what tells the two apart from a refusal, which is why `reasons` can
      # collapse all three into one list.
      #
      # `test_run_id` and `ci_run_id` are Strings or `null`, on the terms
      # {Transport::Result#test_run_id} and {IngestCLI}'s `#scalar` already set:
      # a non-scalar is not an id, and inventing structure the envelope does not
      # have is not this tool's business.
      def self.delivered(result)
        {
          "number" => result.number,
          "status" => result.status.to_s,
          "code" => result.code,
          "reasons" => reasons(result.reasons),
          "test_run_id" => result.test_run_id,
          "ci_run_id" => result.ci_run_id
        }
      end

      # One listed line: the envelope facts the text row prints, as values
      # rather than as prose. `null` is the row's `no branch` / `no specs` /
      # `no duration_seconds` — a fact the line does not carry, which is a
      # different thing from one it carries as empty.
      def self.listed(line)
        {
          "number" => line.number,
          "status" => line.problem ? STATUS_UNPARSEABLE : STATUS_LISTED,
          "reasons" => reasons(line.problem),
          "branch" => line.branch,
          "commit_sha" => line.commit_sha,
          "ci_run_id" => line.ci_run_id,
          "examples" => line.examples,
          "duration_seconds" => line.duration_seconds
        }
      end

      def self.folded(folding)
        {
          "ci_run_id" => folding.ci_run_id,
          "test_run_id" => folding.test_run_id,
          "lines" => folding.numbers
        }
      end

      # ALWAYS a list of strings — `[]` where the line landed and where a
      # refusal's body said nothing this gem could read, never `null` and never
      # a bare string. {JSONReporter}'s `errors` makes the identical guarantee
      # for the identical reason: `JSONFinding` (open-test-intent,
      # `cmd/validate-intent/report.go`) is explicit that a consumer
      # must never have to branch on the type of the field that says why
      # something failed, and one list is what lets a refusal's per-spec errors,
      # a socket error and "this line is not a run" be read by one code path.
      #
      # The whole array, uncapped — that is the point of the document. It is
      # what the platform sent, in its own words and in its own order, filtered
      # only of what is not a String, because the source is a free-form JSON
      # body and a Hash in there is not a reason.
      #
      # `scrub` for the same reason {Transport::Result#one_line} does it: a body
      # from a proxy is bytes, not necessarily valid UTF-8, and `JSON.generate`
      # raises on an invalid sequence. Raising here would cost the run its whole
      # document — stdout empty, exit 2, an internal error on stderr — over a
      # decoration. Note what is NOT done: the whitespace is left alone.
      # Collapsing it is `#one_line`'s job because a CI log has one line to
      # spend, and a JSON string has no such budget.
      #
      # @param values [Array, String, nil]
      # @return [Array<String>]
      def self.reasons(values)
        Array(values).filter_map { |value| value.scrub("") if value.is_a?(String) }
      end

      private_class_method :document, :summary, :attempted, :absent, :selector, :delivered, :listed, :folded,
                           :reasons
    end
  end
end
