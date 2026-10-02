# frozen_string_literal: true

require "json"
require "net/http"
require "uri"
require "zlib"

require_relative "configuration"
require_relative "../version"

module SpecGuard
  module Client
    # The one HTTP call this gem makes: `POST <endpoint>/api/v1/ingest`,
    # carrying a whole run.
    #
    # == Why this returns a result instead of raising
    #
    # {SpecGuard::RSpecFormatter}'s never-block-CI guard is a `rescue` around
    # each hook, and a `rescue` is structurally blind to the failure that
    # matters most here: `Net::HTTP` hands back `Net::HTTPUnauthorized` as an
    # ordinary return value. A wrong API key therefore raises nothing, warns
    # nothing and logs nothing — the run's telemetry disappears in complete
    # silence, which is precisely the outcome the client-gem spec's "if the API
    # key is wrong … it logs a warning to stderr" forbids.
    #
    # So the two failure families are made the same *shape* rather than left to
    # two different mechanisms: {#deliver} answers a {Result} for a non-2xx
    # response and a {Result} for a raised exception, and the caller has one
    # thing to check. Nothing escapes this class except `Interrupt`,
    # `SignalException` and `SystemExit` — Ctrl-C must stay Ctrl-C.
    #
    # == One request per process, gzipped once it is big enough
    #
    # A run goes in a single POST, and the body is compressed above a size
    # threshold. Both halves are decisions rather than defaults, and the
    # roadmap asked for them to be made deliberately rather than discovered in
    # production, so they are written down here.
    #
    # === Batching: no, and this is settled
    #
    #   * `Ingest::Payload` derives `total_specs_count` from the specs of *that*
    #     request. Splitting a run across N POSTs with no way to say they are
    #     one run would produce N `TestRun` rows with a split denominator,
    #     corrupting the headline annotated-ratio metric.
    #   * That is qualified rather than absolute, and the qualification is
    #     `ci_run_id` + `shard_id`. The platform folds every POST carrying the
    #     same run id onto one `TestRun`, keyed by shard so a slice that arrives
    #     twice replaces itself, which is what makes a *sharded* run — N
    #     processes, N POSTs, one run — land as one row. So the rule this class
    #     keeps is narrower than it was: **one process sends one request.**
    #   * Batching a single process's own run into several POSTs stays wrong,
    #     and not only for the denominator: every part would carry the same
    #     `shard_id`, so the parts would overwrite one another and the row would
    #     keep only the last. Fixing that means a new part-of-a-shard concept on
    #     the platform, which is a schema change bought to solve a problem that
    #     compression already solved.
    #
    # === Streaming: no, for the same reason, and the reason is measured
    #
    # The pressure that made batching and streaming look necessary was size,
    # and size is now a number rather than a worry. Measured by running a real
    # 200-file / 20,000-example suite through this gem's own formatter, half of
    # the examples annotated:
    #
    #   identity   7,354,782 bytes   7.01 MiB    needs 5.9 Mbit/s to write in 10s
    #   gzip         346,206 bytes   0.33 MiB    needs 0.3 Mbit/s
    #   ratio           21.2x        95.3% saved       60 ms to compress
    #
    # Uncompressed, that body has to be *written* inside
    # `Configuration::DEFAULT_TIMEOUT_SECONDS` (10). At 5 Mbit/s of uplink it
    # takes 11.8s and fails as a `write_timeout`; the run then lands in
    # `log/test_results.jsonl` and the platform never sees it. Compressed, the
    # same run takes 0.55s on that link and 2.8s on a 1 Mbit/s one. The 60 ms
    # spent compressing is noise against a suite that took minutes.
    #
    # Two honesties about that ratio. It is *below* the 35x this change was
    # proposed on, because SPGD-159 has since added `id` and `spec_file_path`
    # to every row — re-measure rather than quote, is the lesson. And it is
    # probably *above* what a real suite gets: synthetic example names repeat
    # more than human ones do, so treat 21x as the optimistic end. Nothing here
    # depends on the exact figure. Even a pessimistic 5x moves the 20k case
    # from "cannot ship on a slow link" to "ships with room to spare", and
    # 0.33 MiB is not a payload anyone needs to chunk.
    #
    # So: compression yes, batching and streaming no. Recorded rather than left
    # implicit — an undocumented decision is one that gets re-opened in six
    # months by someone who cannot tell it was ever made.
    #
    # === Why a threshold rather than always
    #
    # Below {GZIP_THRESHOLD_BYTES} the round trip buys nothing worth paying for
    # in opacity: a small run stays identity-encoded, so it is still readable
    # with `curl` and `tcpdump`, and the local-file and stub-server paths still
    # show a human a JSON body. Compression is for the case that could not ship
    # at all, not a uniform policy.
    #
    # Compression also sits *inside* the never-block-CI contract. A `Zlib`
    # failure falls back to the identity body — which the platform still
    # accepts — rather than raising: a run must not be lost to an optimisation.
    #
    # === The version floor this creates, which is a deploy order and not a merge order
    #
    # Sending `Content-Encoding: gzip` requires a platform that can inflate one,
    # and that arrived with `GzipRequestBody` (SPGD-175). "Merge the platform PR
    # first" is the half of this that is easy to say and is *not* sufficient:
    # merge order only settles the source trees. What this gem actually talks to
    # is a **deployment**.
    #
    # So a gem at this version pointed at an installation deployed before
    # `GzipRequestBody` will 400 every run over {GZIP_THRESHOLD_BYTES} — the
    # inflater is not there, the body reaches the JSON parser still gzipped, and
    # `Api::V1::IngestsController` refuses it. {#deliver} answers
    # `Result(outcome: :rejected, code: 400)`; there is no retry-as-identity, so
    # the formatter falls back to `log/test_results.jsonl` and the run is lost
    # to the platform. That is precisely the failure this change exists to
    # close, reintroduced for precisely the large suites it targets — and it is
    # silent apart from one stderr line, because CI still goes green.
    #
    # Written down rather than fixed, deliberately. A 400-triggered retry with
    # the identity body would paper over it, but it doubles the request count on
    # every genuinely-malformed payload and makes a client-side bug look like a
    # flake; that is a contract decision, not a detail to slip in here. The
    # honest statement of the constraint is a version floor: **this gem requires
    # a platform deployment that includes `GzipRequestBody`.**
    class Transport
      # `config/routes.rb` mounts `post "ingest"` under the `/api/v1` scope.
      # Part of the platform's contract, so it is not configurable — the
      # `endpoint` setting is the installation's address and nothing more.
      PATH = "/api/v1/ingest"
      CONTENT_TYPE = "application/json"
      USER_AGENT = "specguard-ruby/#{SpecGuard::VERSION}"
      CONTENT_ENCODING = "gzip"

      # Bodies at least this large are gzipped; smaller ones go identity. See
      # the class comment for why this is a threshold and not a switch.
      #
      # 256 KiB is roughly where the round trip starts paying — a few thousand
      # examples. It is a judgement call, not a measured optimum, and the only
      # thing that depends on the exact number is how large a run has to be
      # before `curl` stops showing you a readable body.
      GZIP_THRESHOLD_BYTES = 256 * 1024

      # What the ingest endpoint said, in the one form the caller has to handle.
      #
      # `outcome` is one of:
      #
      #   :success   a 2xx. `code` carries it (202 in the happy path).
      #   :rejected  a non-2xx. `code` carries it; nothing was raised.
      #   :failed    an exception was raised. `error` carries it.
      #
      # `reasons` is the refusal in the platform's own words — the strings
      # `Api::BaseController#render_bad_request` puts on the wire, each naming
      # one offending spec by index, file and line. It is populated only on
      # `:rejected`, and only when the body actually said something this class
      # could read; a proxy's HTML 502 leaves it nil and the reader gets
      # exactly what they got before.
      #
      # `body` is the mirror of that on the accepting side: the 202 document
      # `Api::V1::IngestsController` renders — `test_run_id`, `total_specs`,
      # `annotated_specs`, `annotated_ratio`, `embedding_status` — parsed, and
      # populated only on `:success`. It was discarded until {IngestCLI}
      # needed to say *which run* a re-delivered line landed on, and it is
      # added rather than substituted: nothing that read a {Result} before
      # reads a different one now.
      #
      # It degrades to `nil` on exactly the terms `reasons` does, and for the
      # same reason turned around: a 202 whose body will not parse is still an
      # acceptance, and relabelling it would tell the operator something untrue
      # about a run the platform has already stored. See {#test_run_id}.
      Result = Struct.new(:outcome, :code, :error, :reasons, :body, keyword_init: true) do
        # The status codes worth spelling out, because each implies a different
        # thing for the reader to *do*. A 401 means "rotate or fix the key"; a
        # 400 means "the payload this gem built was refused", which is a bug
        # report and not a credentials problem. Printing a bare number would
        # leave a CI operator to guess which of the two they are looking at.
        ADVICE = {
          400 => "the endpoint rejected the payload",
          401 => "the API key was not accepted",
          403 => "this API key may not write to that repository",
          404 => "no ingest endpoint at that URL — check SPECGUARD_ENDPOINT",
          413 => "the payload was too large for the endpoint",
          429 => "rate limited by the endpoint"
        }.freeze

        # How many of the platform's reasons are spelled out, with an
        # `and N more` tail standing in for the rest.
        #
        # A cap rather than the whole list, because the list is unbounded at
        # its source: `Ingest::Payload` appends one error *per bad spec*, so a
        # systemic client bug on a 20,000-example suite comes back with
        # ~20,000 strings. Three is enough to see the shape of the failure —
        # they are near-identical when the cause is systemic — and the count
        # tells the reader how widespread it is.
        MAX_RENDERED_REASONS = 3

        # Ceiling on the spelled-out reasons, before the `and N more` tail,
        # which is appended afterwards so the count can never be the thing that
        # gets truncated away.
        MAX_REASONS_LENGTH = 300

        def success? = outcome == :success

        # The id of the `TestRun` this delivery landed on, as the endpoint
        # reported it — `nil` whenever that cannot be said honestly: a refusal,
        # an exception, a 202 with an unreadable body, or one whose
        # `test_run_id` is not a scalar.
        #
        # Returned as a String so two deliveries can be compared without
        # caring whether the platform spells an id as a UUID or a number. Two
        # accepted lines answering with the same value landed on the same row;
        # that is the only claim about folding this class can support, and
        # {IngestCLI} makes exactly that one.
        #
        # @return [String, nil]
        def test_run_id
          value = body.is_a?(Hash) ? body["test_run_id"] : nil
          value.is_a?(String) || value.is_a?(Numeric) ? value.to_s : nil
        end

        # A single clause naming what went wrong, for the one stderr line a run
        # is allowed. `nil` on success, because there is nothing to say.
        #
        # @return [String, nil]
        def reason
          case outcome
          when :success then nil
          when :rejected then [+"HTTP #{code}", ADVICE[code], rendered_reasons].compact.join(" — ")
          else "#{error.class}: #{error.message}"
          end
        end

        private

        # The refusal, bounded and flattened to fit on the one line. `nil` when
        # there is nothing readable to add, which is what keeps the bare
        # `HTTP 400 — the endpoint rejected the payload` intact for every body
        # this class could not make sense of.
        def rendered_reasons
          cleaned = Array(reasons).filter_map { |value| one_line(value) }
          return nil if cleaned.empty?

          rendered = cleaned.take(MAX_RENDERED_REASONS).join("; ")
          rendered = "#{rendered[0, MAX_REASONS_LENGTH - 1]}…" if rendered.length > MAX_REASONS_LENGTH

          omitted = cleaned.length - MAX_RENDERED_REASONS
          omitted.positive? ? "#{rendered} and #{omitted} more" : rendered
        end

        # One line, guaranteed. Newlines, tabs, ANSI escapes and every other
        # control character collapse to a single space, so nothing arriving
        # from the network can smear itself across a CI log or forge lines
        # that look like they came from something else. `scrub` first because
        # a body from a proxy is bytes, not necessarily valid UTF-8, and
        # `gsub` raises on an invalid sequence.
        #
        # @return [String, nil] nil for a non-String and for anything that was
        #   only whitespace to begin with.
        def one_line(value)
          return nil unless value.is_a?(String)

          text = value.scrub("").gsub(/[[:space:][:cntrl:]]+/, " ").strip
          text.empty? ? nil : text
        end
      end

      # @param endpoint [String, nil] the installation's base URL. Any trailing
      #   slashes are dropped; a path prefix is preserved, so an installation
      #   behind `https://tools.example.com/specguard` works.
      # @param api_key [String, nil] sent verbatim as a Bearer token.
      # @param timeout [Numeric, String, nil] seconds. Anything that is not a
      #   positive finite number falls back to the default rather than raising:
      #   a typo in `SPECGUARD_TIMEOUT` must not be able to fail a suite.
      def initialize(endpoint:, api_key:, timeout: Configuration::DEFAULT_TIMEOUT_SECONDS)
        @endpoint = endpoint
        @api_key = api_key
        @timeout = sanitize_timeout(timeout)
      end

      attr_reader :timeout

      # Where this transport would POST.
      #
      # @return [URI::HTTP]
      # @raise [ArgumentError] when the endpoint is missing or is not an
      #   http(s) URL. Raised rather than returned because {#deliver} converts
      #   it into a {Result} like every other failure, and a caller asking for
      #   the URI directly wants to know.
      def uri
        @uri ||= build_uri
      end

      # @param payload [Hash] the run, as {SpecGuard::RSpecFormatter#payload}
      #   assembles it. Sent as-is: its key names are already the platform's
      #   ingest contract, and reshaping it here would put the wire format two
      #   files away from the code that decides it.
      # @return [Result] never nil, never raised through.
      def deliver(payload)
        response = post(JSON.generate(payload))
        code = response.code.to_i

        return Result.new(outcome: :success, code: code, body: success_body(response)) if
          response.is_a?(Net::HTTPSuccess)

        Result.new(outcome: :rejected, code: code, reasons: refusal_reasons(response))
      rescue ScriptError, StandardError => e
        # Connection refused, DNS failure, TLS failure, open/read timeout, a
        # malformed endpoint — one family, one shape. `ScriptError` is in the
        # list for the same reason the formatter's guard names it: an autoload
        # blowing up under `net/http` is not a `StandardError`, and a bare
        # rescue would let it escape and take the suite's exit code with it.
        Result.new(outcome: :failed, error: e)
      end

      private

      # What the platform said about the run it accepted, or `nil` when the
      # body did not say anything this class can use.
      #
      # The guard is {#refusal_reasons}'s, argued the other way round. There it
      # keeps a refusal from being relabelled an exception; here it keeps an
      # *acceptance* from being relabelled at all. The platform has stored the
      # run by the time it writes this body, so a truncated read, an empty
      # body, or a proxy that rewrote the 202 into HTML must cost the caller
      # the decoration and nothing else. Every failure of reading degrades to
      # `nil`, and `Result#success?` is what it was before this existed.
      def success_body(response)
        body = JSON.parse(response.body.to_s)
        body if body.is_a?(Hash)
      rescue ScriptError, StandardError
        nil
      end

      # What the platform said about the refusal, or `nil` when the body did
      # not say anything this class can use.
      #
      # `Api::BaseController` shapes both refusal bodies deliberately for a
      # client to read: `render_bad_request` carries every validation failure
      # in `details` and repeats the first in `message`, and
      # `render_unauthorized` carries `message` alone. So `details` is
      # preferred and `message` is the fallback, which is exactly the 400/401
      # split rather than two special cases.
      #
      # == Why the guard is here and not the method-level one
      #
      # {#deliver}'s `rescue` turns anything raised into
      # `Result(outcome: :failed)`, and a body that will not parse is not a
      # delivery failure — the delivery plainly succeeded and was refused. To
      # let a `JSON::ParserError` reach that rescue would relabel a 400 as an
      # exception and tell the operator something untrue about what happened,
      # for the sake of a decoration. So every failure of *reading* degrades to
      # `nil` here and the run is told exactly what it was told before this
      # existed. That covers the empty body, the HTML a proxy answers a 413
      # with, a JSON scalar, and a read that dies part-way through a body whose
      # status line had already arrived.
      def refusal_reasons(response)
        body = JSON.parse(response.body.to_s)
        return nil unless body.is_a?(Hash)

        details = body["details"]
        return details if details.is_a?(Array) && details.any? && details.all?(String)

        message = body["message"]
        [message] if message.is_a?(String)
      rescue ScriptError, StandardError
        nil
      end

      def post(body)
        target = uri

        http = Net::HTTP.new(target.host, target.port)
        http.use_ssl = target.scheme == "https"
        # All three, not just the two the spec names. Compression takes a
        # 20k-example run from 7.01 MiB to 0.33 MiB, which is what puts the
        # write comfortably inside the budget rather than past it — but a peer
        # that accepts the connection and then stops reading still hangs in the
        # *write* whatever the body's size, so the timeout is the thing that
        # bounds it. Same unbounded wait, reached by a different door.
        http.open_timeout = @timeout
        http.read_timeout = @timeout
        http.write_timeout = @timeout

        http.start { |connection| connection.request(build_request(target, body)) }
      end

      def build_request(target, body)
        request = Net::HTTP::Post.new(target.request_uri)
        # `Api::BaseController#bearer_token` matches /\ABearer\s+(?<token>.+)\z/i.
        request["Authorization"] = "Bearer #{@api_key}"
        # Describes the body *inside* any encoding, which is what
        # `Content-Type` means — the platform's `GzipRequestBody` inflates and
        # then hands an ordinary JSON request downstream.
        request["Content-Type"] = CONTENT_TYPE
        request["Accept"] = CONTENT_TYPE
        request["User-Agent"] = USER_AGENT

        compressed = compress(body)
        request["Content-Encoding"] = CONTENT_ENCODING if compressed
        # `Net::HTTP::Post#body=` sets `Content-Length` from what it is given,
        # so the length always describes the bytes actually on the wire.
        request.body = compressed || body
        request
      end

      # The compressed body, or `nil` to mean "send it as it is" — for a run
      # under the threshold and, deliberately, for a compression that failed.
      #
      # Returning `nil` on failure rather than letting it out is the whole
      # point: an identity body is something the platform accepts, so a broken
      # `Zlib` costs a large run some bandwidth and nothing else. Letting the
      # error reach {#deliver} would turn it into `Result(outcome: :failed)`
      # and lose the run to a *saving*.
      #
      # `ScriptError, StandardError` matches {#deliver}'s own guard rather than
      # naming `Zlib::Error`: the failure worth catching here is as likely to be
      # the `zlib` extension missing from a stripped-down Ruby, which is a
      # `LoadError` and so a `ScriptError`, as it is a compression fault.
      def compress(body)
        return nil if body.bytesize < GZIP_THRESHOLD_BYTES

        Zlib.gzip(body)
      rescue ScriptError, StandardError
        nil
      end

      def build_uri
        base = @endpoint.to_s.strip
        raise ArgumentError, "no endpoint is configured (set SPECGUARD_ENDPOINT)" if base.empty?

        parsed = URI.parse(base.sub(%r{/+\z}, "") + PATH)
        # `URI::HTTPS < URI::HTTP`, so this admits both and rejects the
        # scheme-less `specguard.example.com` that `URI.parse` happily returns
        # as a `URI::Generic` with a nil host — which `Net::HTTP` would then
        # try to connect to.
        raise ArgumentError, "endpoint must be an http:// or https:// URL, got #{base.inspect}" unless
          parsed.is_a?(URI::HTTP) && !parsed.host.to_s.empty?

        parsed
      end

      def sanitize_timeout(value)
        parsed = Float(value, exception: false)
        return Configuration::DEFAULT_TIMEOUT_SECONDS unless parsed&.finite? && parsed.positive?

        parsed
      end
    end
  end
end
