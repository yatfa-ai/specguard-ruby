# frozen_string_literal: true

require "stringio"
require "specguard/client/transport"

require_relative "../../support/stub_ingest_endpoint"

# The one HTTP call this gem makes, against a real socket.
#
# Everything here is about the two things a `rescue` around a POST cannot see:
# a response that arrived and said no, and a request that never arrived at all.
# `Net::HTTP` returns `Net::HTTPUnauthorized` as an ordinary value, so a wrong
# API key raises nothing — and the formatter's never-block-CI guard is a
# `rescue`. Making both families the same {Result} shape is what gives the
# caller one thing to check.
RSpec.describe SpecGuard::Client::Transport do
  let(:payload) do
    {
      "commit_sha" => "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2",
      "branch" => "main",
      "duration_seconds" => 1.25,
      "specs" => [
        { "file_path" => "spec/orders_spec.rb", "line_number" => 4, "name" => "Order checks out",
          "duration" => 0.01, "outcome" => "passed", "status" => "unannotated", "intent" => nil }
      ]
    }
  end

  def transport_to(server, api_key: "sgk_abc123", timeout: 5)
    described_class.new(endpoint: server.endpoint, api_key: api_key, timeout: timeout)
  end

  # Criterion 1.
  describe "the request it puts on the wire" do
    subject(:request) { captured }

    # One round trip, read back from the server's own record of what arrived.
    # Memoized rather than taken in a `before(:context)` hook: a constant or an
    # ivar shared across examples here would have to be assigned at the *lexical*
    # scope, which inside an `RSpec.describe` block is top level.
    let(:captured) do
      StubIngestEndpoint.run do |server|
        transport_to(server).deliver(payload)
        server.requests.first
      end
    end

    # @intent: { entity: "Transport", action: "deliver the run", behavior: "delivery uses the POST verb against the ingest endpoint", layer: "unit" }
    it "POSTs" do
      expect(request.verb).to eq("POST")
    end

    # `config/routes.rb` mounts `post "ingest"` inside the `/api/v1` scope. The
    # client owns the host; the path is the platform's and is not configurable.
    # @intent: { entity: "Transport", action: "deliver the run", behavior: "the request targets the ingest path, which the endpoint setting does not already include", layer: "unit" }
    it "posts to /api/v1/ingest, which the endpoint setting does not include" do
      expect(request.path).to eq("/api/v1/ingest")
    end

    # `Api::BaseController#bearer_token` matches /\ABearer\s+(?<token>.+)\z/i
    # and 401s on anything else — including the `Token ` and bare-key forms an
    # implementation might reasonably have guessed at.
    # @intent: { entity: "Transport", action: "authenticate the run", behavior: "the api key travels as a Bearer token in the authorization header the platform parses", layer: "unit" }
    it "authenticates with a Bearer token in the form the platform parses" do
      expect(request.headers["authorization"]).to eq("Bearer sgk_abc123")
    end

    # @intent: { entity: "Transport", action: "deliver the run", behavior: "the body is declared as JSON, without which the platform would parse nothing", layer: "unit" }
    it "declares a JSON body, without which Rails parses nothing" do
      expect(request.headers["content-type"]).to eq("application/json")
    end

    # @intent: { entity: "Transport", action: "identify itself", behavior: "the user agent names the gem so the platform can tell its clients apart", layer: "unit" }
    it "identifies itself, so the platform can tell its clients apart" do
      expect(request.headers["user-agent"]).to eq("specguard-ruby/#{SpecGuard::VERSION}")
    end

    # The body is `#payload` verbatim. Reshaping it in transport would put the
    # wire format two files away from the code that decides it.
    # @intent: { entity: "Transport", action: "deliver the run", behavior: "the payload arrives unchanged, key for key", layer: "unit" }
    it "sends the payload unchanged, key for key" do
      expect(request.json).to eq(payload)
    end

    # This example used to assert the opposite, and the reason it did was true
    # at the time: the platform could not inflate a request body, so identity
    # was the only encoding that landed. `GzipRequestBody` (SPGD-175) removed
    # that constraint, and this run is *still* identity-encoded — for a
    # different reason. It is far under the threshold, and a small body stays
    # readable to `curl`, `tcpdump` and anyone reading the stub server's record
    # of what arrived.
    #
    # The size assertion is not decoration: without it this example would keep
    # passing while silently testing nothing the day the fixture grows past the
    # threshold.
    # @intent: { entity: "Transport", action: "compress large runs", behavior: "a small run stays uncompressed so it remains inspectable on the wire", layer: "unit" }
    it "leaves a small run uncompressed, so it stays inspectable on the wire" do
      expect(payload.to_json.bytesize).to be < described_class::GZIP_THRESHOLD_BYTES
      expect(request.headers["content-encoding"]).to be_nil
    end

    # == Why `eq` over the sorted key set, and not another `headers[...]` check
    #
    # README's "What SpecGuard collects" enumerates the request headers and
    # tells a customer that exactly two of them — `Authorization` and
    # `User-Agent` — say anything about them, and that the rest are plumbing
    # carrying nothing about their code. That is a claim a security review
    # reads before deciding whether this data may leave their perimeter, so it
    # has to be a *maintained* claim rather than a snapshot of the day it was
    # written.
    #
    # Every other header assertion in this file is additive: they each name one
    # header and pass regardless of what else was sent. A header added to
    # `#build_request` tomorrow — a project id, a tenant hint, an experiment
    # flag — ships green through all of them with the README still promising
    # this list. Comparing the *whole* sorted key set is the only shape that
    # cannot: it fails, and names the header that appeared.
    #
    # That drift is measured, not hypothetical. `Content-Encoding` arrived with
    # SPGD-175 and `Accept-Encoding` is a `Net::HTTP` default that
    # `#build_request` never mentions — both are on the wire, and neither is
    # visible from reading `#build_request` alone. Hence the assertion is made
    # against what the stub server actually received.
    #
    # If this fails: update the header list in README's "What SpecGuard
    # collects" to match what is now sent, then update this list. Do not update
    # this list alone — the disclosure is the point of the pin.
    # @intent: { entity: "Transport", action: "disclose its headers", behavior: "exactly the headers the readme discloses are sent, and no others", layer: "unit" }
    it "sends exactly the headers the README discloses, and no others" do
      expect(request.headers.keys.sort).to eq(
        %w[accept accept-encoding authorization content-length content-type host user-agent]
      )
    end
  end

  # == The one disclosure that is about where the run goes, not what is in it
  #
  # `#post` builds its client as `Net::HTTP.new(host, port)` — two arguments,
  # so the third, `p_addr`, takes its default of `:ENV`. That default is the
  # whole subject of this block: Ruby then resolves a proxy out of the
  # environment, and with `http_proxy` set the entire payload goes to the proxy
  # instead of to `SPECGUARD_ENDPOINT`.
  #
  # README's "What SpecGuard collects" discloses that, because the section one
  # heading above it tells a perimeter-conscious reader that `SPECGUARD_ENDPOINT`
  # is the lever controlling where their data goes, and this is a second lever
  # they did not set through us.
  #
  # == Why these examples exist when the key-set pins already do
  #
  # They cannot reach this. Every other pin added with that disclosure asserts
  # over `Configuration`'s frozen `*_KEYS` constants; this read happens in
  # `Transport`, inside stdlib, against no constant at all. So the proxy
  # paragraph was the only claim in the section still standing on prose — which
  # is the exact position the header list and the environment list were both in
  # when each of them turned out to be wrong.
  #
  # == Why the disclosed *shape* is asserted, not the absence of a read
  #
  # "Nothing else is read" is unprovable from in here. What is provable is the
  # behaviour the README now describes, so that is what is pinned: the proxy is
  # taken, it is taken for a TLS endpoint too, `no_proxy` suppresses it, and
  # `https_proxy` alone does nothing. Each of those is a sentence in the
  # section. If someone later passes `nil` for `p_addr` and silently stops
  # honouring proxies, these fail — and that is a disclosure defect in the
  # opposite direction, worth catching just as much.
  #
  # == The `https_proxy` example is the reason to probe rather than reason
  #
  # `URI.parse("https://…").find_proxy` does consult `https_proxy`, so reading
  # the docs suggests `Net::HTTP` honours it for a TLS endpoint. It does not:
  # `Net::HTTP#proxy_uri` resolves against a `URI::HTTP` built with the literal
  # scheme `"http"` whatever `use_ssl` is, so `http_proxy` governs both and
  # `https_proxy` governs neither. Stating the plausible version would have put
  # a false sentence in a privacy disclosure. Pinned so it stays checked.
  describe "the proxy variables the README discloses" do
    # `.invalid` is reserved by RFC 6761 and never resolves, so an unproxied
    # attempt cannot leave this machine even if something here regresses: the
    # examples that expect no proxying prove it by the request never arriving,
    # and a real hostname would make that a claim about the network instead.
    let(:unreachable_endpoint) { "https://ingest.specguard.invalid" }

    # Saved and restored around each example, and every proxy variable cleared
    # first — a developer or a CI runner with `http_proxy` already exported
    # would otherwise change what these examples mean.
    def with_env(overrides)
      saved = ENV.to_h
      ENV.keys.grep(/\A(http|https|no|cgi_http)_proxy\z/i).each { |key| ENV.delete(key) }
      overrides.each { |key, value| ENV[key] = value }
      yield
    ensure
      ENV.replace(saved)
    end

    # Returns what arrived at the stub server, which is standing in for the
    # *proxy* here rather than for the ingest endpoint. A proxied request is
    # recognisable without inspecting the socket: HTTP/1.1 has the client send
    # the absolute URI on the request line when it is talking to a proxy, so
    # the recorded path is `http://host/api/v1/ingest` rather than the origin
    # form `/api/v1/ingest`.
    def requests_arriving_at_proxy(vars, endpoint: unreachable_endpoint, extra_env: {})
      StubIngestEndpoint.run do |server|
        proxy = "http://127.0.0.1:#{server.port}"

        with_env(vars.to_h { |name| [name, proxy] }.merge(extra_env)) do
          described_class.new(endpoint: endpoint, api_key: "sgk_abc123", timeout: 5).deliver(payload)
        end

        server.requests
      end
    end

    # @intent: { entity: "Transport", action: "honour proxy variables", behavior: "the run is sent to the proxy named by the lowercase http proxy variable", layer: "unit" }
    it "sends the run to the proxy named by http_proxy" do
      arrived = requests_arriving_at_proxy(%w[http_proxy], endpoint: "http://ingest.specguard.invalid")

      expect(arrived.map(&:path)).to eq(["http://ingest.specguard.invalid/api/v1/ingest"])
    end

    # Ruby prints "The environment variable HTTP_PROXY is discouraged" to stderr
    # on this path — unconditionally, not under `$VERBOSE`, so it cannot be
    # switched off. Captured rather than left to litter the suite's output. The
    # warning is itself corroboration that the read happens; the assertion below
    # is on the request that arrived, which is the stronger evidence.
    # @intent: { entity: "Transport", action: "honour proxy variables", behavior: "the uppercase spelling of the proxy variable works the same way", layer: "unit" }
    it "honours the uppercase HTTP_PROXY spelling too" do
      original = $stderr
      $stderr = StringIO.new

      arrived = requests_arriving_at_proxy(%w[HTTP_PROXY], endpoint: "http://ingest.specguard.invalid")

      expect(arrived.map(&:path)).to eq(["http://ingest.specguard.invalid/api/v1/ingest"])
    ensure
      $stderr = original
    end

    # The claim a reader is most likely to get wrong, so the one most worth
    # pinning. A TLS endpoint is tunnelled, so the proxy sees `CONNECT` and the
    # authority rather than a POST — the run still went to the proxy, which is
    # the disclosed fact.
    # @intent: { entity: "Transport", action: "honour proxy variables", behavior: "an https endpoint routes through the plain http proxy variable too, not the https one", layer: "unit" }
    it "routes an https endpoint through http_proxy as well, not https_proxy" do
      arrived = requests_arriving_at_proxy(%w[http_proxy])

      expect(arrived.map(&:verb)).to eq(["CONNECT"])
    end

    # == These last two are differential on purpose
    #
    # Both disclose an *absence* — the run was not proxied — and "nothing
    # arrived at the stub" is the classic assertion that also passes when the
    # harness is broken: a transport that delivered nowhere at all, a port that
    # was never listening, a `deliver` that raised on line one, would each give
    # a green empty. That is Vacuous Green, and it is worth avoiding here more
    # than usual, because a false green on these two would republish the exact
    # claim this round was opened to correct.
    #
    # So each runs its own control in the same example, changing one variable
    # name and nothing else. The control proves the request *can* reach the
    # stub through this setup; the assertion then means the variable is what
    # stopped it, which is what the README actually says.
    # @intent: { entity: "Transport", action: "honour proxy variables", behavior: "the https proxy variable is ignored even for an https endpoint, so that run is not proxied", layer: "unit" }
    it "ignores https_proxy even for an https endpoint, so that run is not proxied" do
      through_https_proxy = requests_arriving_at_proxy(%w[https_proxy])
      through_http_proxy = requests_arriving_at_proxy(%w[http_proxy])

      expect(through_http_proxy).not_to be_empty
      expect(through_https_proxy).to be_empty
    end

    # @intent: { entity: "Transport", action: "honour proxy variables", behavior: "no proxy suppresses the proxy for a matching host", layer: "unit" }
    it "lets no_proxy suppress the proxy for a matching host" do
      origin = "http://ingest.specguard.invalid"

      with_no_proxy = requests_arriving_at_proxy(
        %w[http_proxy], endpoint: origin, extra_env: { "no_proxy" => "ingest.specguard.invalid" }
      )
      without_no_proxy = requests_arriving_at_proxy(%w[http_proxy], endpoint: origin)

      expect(without_no_proxy).not_to be_empty
      expect(with_no_proxy).to be_empty
    end
  end

  # A 20,000-example run serializes to 7,354,782 bytes (7.01 MiB), and `#post`
  # bounds the whole request — the *write* included — with one timeout, 10s by
  # default. Below 5.9 Mbit/s of uplink that body cannot be written in time:
  # `#deliver` answers `Result(outcome: :failed)`, the formatter falls back to
  # `log/test_results.jsonl`, and the platform never receives the run. Which is
  # the large-suite case the whole formatter exists for. Gzipped, the same body
  # is 346,206 bytes (0.33 MiB) — 21.2x.
  #
  # `Transport`'s class comment owns those figures, including how they were
  # measured and why 21.2x is the optimistic end. They are repeated here only
  # because this is where the behavior they justify is proved; if they are ever
  # re-measured, that comment is the one that has to change and this one is the
  # second site. An earlier draft of this file quoted the *proposal*'s numbers
  # (~6 MiB / ~0.17 MiB / 35x), which SPGD-159 had already invalidated by adding
  # `id` and `spec_file_path` to every row — re-measure rather than quote.
  #
  # Those are figures for a *real* formatter run. The fixture below is not one,
  # and is deliberately not described as one: `run_of` builds a leaner row than
  # the formatter emits, so `run_of(20_000)` is 4,655,671 bytes (4.44 MiB),
  # gzipping to 243,458 (19.1x). That is the right trade for a unit spec — it
  # exercises the same code path at the same order of magnitude without a
  # multi-second fixture build — but it means this file proves the *mechanism*
  # at scale, while the 7.01 MiB figure above is the thing the mechanism exists
  # for. Do not read the two as the same measurement.
  describe "a run big enough to need compressing" do
    # Sized by construction rather than by a hopeful example count: the row
    # shape changes (SPGD-159 added two fields), and a fixed count would one day
    # stop clearing the threshold and quietly stop testing compression.
    def run_of(examples)
      row = payload["specs"].first

      payload.merge("specs" => Array.new(examples) do |i|
        row.merge("id" => "./spec/models/model_#{i}_spec.rb[1:1]",
                  "file_path" => "spec/models/model_#{i}_spec.rb",
                  "line_number" => i + 1,
                  "name" => "Model#{i} does the one thing it is for")
      end)
    end

    let(:big) { run_of(2_000) }

    let(:captured) do
      StubIngestEndpoint.run do |server|
        transport_to(server).deliver(big)
        server.requests.first
      end
    end

    before { expect(big.to_json.bytesize).to be > described_class::GZIP_THRESHOLD_BYTES }

    # @intent: { entity: "Transport", action: "compress large runs", behavior: "a run big enough to compress declares its body gzipped, which the platform inflater keys on", layer: "unit" }
    it "declares the body gzipped, which the platform's inflater keys on" do
      expect(captured.headers["content-encoding"]).to eq("gzip")
    end

    # `Content-Type` describes the body *inside* the encoding. Sending
    # `application/gzip` would be the natural-looking mistake, and the platform
    # inflates first and then parses as JSON, so it would 400 every large run.
    # @intent: { entity: "Transport", action: "compress large runs", behavior: "the compressed body still declares the payload itself as JSON", layer: "unit" }
    it "still declares the payload itself as JSON" do
      expect(captured.headers["content-type"]).to eq("application/json")
    end

    # @intent: { entity: "Transport", action: "compress large runs", behavior: "materially fewer bytes go on the wire than the payload serializes to", layer: "unit" }
    it "puts materially fewer bytes on the wire than the payload serializes to" do
      expect(captured.body.bytesize).to be < (big.to_json.bytesize / 10)
    end

    # The length has to describe the bytes actually sent, not the payload they
    # came from. `ActionDispatch::Request#raw_post` reads exactly
    # `Content-Length` bytes, so an over-large value hangs the read and an
    # under-large one hands the inflater a truncated stream.
    # @intent: { entity: "Transport", action: "compress large runs", behavior: "the content length header matches what was actually written", layer: "unit" }
    it "sets Content-Length to what it actually wrote" do
      expect(captured.headers["content-length"]).to eq(captured.body.bytesize.to_s)
    end

    # The compressed path's half of the pin above. A large run is the shape a
    # security review is most likely to capture off a proxy, and it is the one
    # that carries the extra header — so the README's list is only honest if
    # *this* set is pinned too, not just the identity one.
    # @intent: { entity: "Transport", action: "compress large runs", behavior: "a compressed run carries exactly the disclosed headers plus the gzip one", layer: "unit" }
    it "sends exactly the headers the README discloses, plus the gzip one" do
      expect(captured.headers.keys.sort).to eq(
        %w[accept accept-encoding authorization content-encoding content-length
           content-type host user-agent]
      )
    end

    # The claim the header alone cannot make. A transport that set
    # `Content-Encoding: gzip` and then gzipped the wrong string — or gzipped
    # it twice — passes every assertion above and loses the run in production.
    # @intent: { entity: "Transport", action: "compress large runs", behavior: "the payload round-trips key for key once the receiver inflates it", layer: "unit" }
    it "round-trips key for key once the receiver inflates it" do
      expect(captured.json).to eq(big)
    end

    # The scale target itself, at the volume the roadmap named, because the
    # threshold examples above prove the mechanism on a body that only just
    # clears it. 4.44 MiB of JSON through a real socket — see the note above on
    # why this fixture is leaner than the 7.01 MiB a real 20k run produces.
    # @intent: { entity: "Transport", action: "compress large runs", behavior: "a twenty-thousand-example run also round-trips key for key", layer: "unit" }
    it "round-trips a 20,000-example run key for key" do
      huge = run_of(20_000)

      arrived = StubIngestEndpoint.run do |server|
        transport_to(server, timeout: 30).deliver(huge)
        server.requests.first
      end

      expect(arrived.headers["content-encoding"]).to eq("gzip")
      expect(arrived.json).to eq(huge)
      expect(arrived.json["specs"].length).to eq(20_000)
    end

    # Compression is an optimisation, and the never-block-CI contract says an
    # optimisation may not cost a run. Both branches of `#compress`'s guard are
    # exercised: a `Zlib` fault, and the `zlib` extension missing from a
    # stripped-down Ruby — a `LoadError`, which is a `ScriptError` and which a
    # bare `rescue` would not catch.
    describe "when compression itself fails" do
      [[Zlib::BufError, "out of buffer space"],
       [NotImplementedError, "no zlib in this build"]].each do |error, message|
        # @intent: { entity: "Transport", action: "survive compression failure", behavior: "when gzip raises the run is still delivered identity-encoded and accepted", layer: "unit" }
        it "still delivers the run, identity-encoded, after a #{error}" do
          allow(Zlib).to receive(:gzip).and_raise(error, message)

          StubIngestEndpoint.run(status: 202) do |server|
            result = transport_to(server).deliver(big)
            arrived = server.requests.first

            expect(result).to be_success
            expect(arrived.headers["content-encoding"]).to be_nil
            expect(arrived.json).to eq(big)
          end
        end

        # @intent: { entity: "Transport", action: "survive compression failure", behavior: "a gzip failure never raises out of deliver", layer: "unit" }
        it "does not raise out of #deliver after a #{error}" do
          allow(Zlib).to receive(:gzip).and_raise(error, message)

          StubIngestEndpoint.run(status: 202) do |server|
            expect { transport_to(server).deliver(big) }.not_to raise_error
          end
        end
      end
    end
  end

  # @intent: { entity: "Transport", action: "deliver the run", behavior: "the whole run goes out in a single request rather than streaming parts", layer: "unit" }
  it "sends the whole run in a single request" do
    StubIngestEndpoint.run do |server|
      transport_to(server).deliver(payload.merge("specs" => Array.new(50) { payload["specs"].first }))

      expect(server.requests.length).to eq(1)
    end
  end

  describe "a 202, which is what the ingest endpoint answers on success" do
    # @intent: { entity: "Transport", action: "read a success answer", behavior: "the accepted status reports success carrying the code", layer: "unit" }
    it "reports success, carrying the code" do
      StubIngestEndpoint.run(status: 202) do |server|
        result = transport_to(server).deliver(payload)

        expect(result).to have_attributes(success?: true, outcome: :success, code: 202)
      end
    end

    # @intent: { entity: "Transport", action: "read a success answer", behavior: "a success has nothing to warn about", layer: "unit" }
    it "has nothing to warn about" do
      StubIngestEndpoint.run(status: 202) do |server|
        expect(transport_to(server).deliver(payload).reason).to be_nil
      end
    end

    # @intent: { entity: "Transport", action: "read a success answer", behavior: "any two-hundreds status reads as success rather than only the exact code seen today", layer: "unit" }
    it "accepts any 2xx rather than only the exact code it expects today" do
      StubIngestEndpoint.run(status: 200) do |server|
        expect(transport_to(server).deliver(payload)).to be_success
      end
    end

    # SPGD-631. The 202 body used to be dropped on the floor, which left a
    # replayed line unable to say WHICH run it had landed on — the one fact
    # that makes "these two deliveries folded onto one row" an observation
    # rather than a guess. It is carried now, and every assertion above this
    # one is unchanged, which is the whole of what "additively" claims.
    describe "the body it now carries back" do
      # @intent: { entity: "Transport", action: "read a success answer", behavior: "the endpoint answer body is parsed so a caller can name the run it landed on", layer: "unit" }
      it "parses the endpoint's answer, so a caller can name the run it landed on" do
        StubIngestEndpoint.run(status: 202, body: '{"test_run_id":"tr_42","annotated_ratio":0.5}') do |server|
          result = transport_to(server).deliver(payload)

          expect(result.body).to eq("test_run_id" => "tr_42", "annotated_ratio" => 0.5)
          expect(result.test_run_id).to eq("tr_42")
        end
      end

      # A numeric id is still an id. Stringified so two deliveries can be
      # compared without the caller caring how the platform spells one.
      # @intent: { entity: "Transport", action: "read a success answer", behavior: "a numeric run id in the answer is stringified rather than dropped", layer: "unit" }
      it "stringifies a numeric id rather than dropping it" do
        StubIngestEndpoint.run(status: 202, body: '{"test_run_id":42}') do |server|
          expect(transport_to(server).deliver(payload).test_run_id).to eq("42")
        end
      end

      # The mirror of `#refusal_reasons`' degradation, and the more important
      # half: the platform has STORED the run by the time it writes this body,
      # so a proxy that rewrote the 202 must cost the caller the decoration and
      # nothing else. Relabelling it would report a stored run as lost.
      [
        ["an empty body", ""],
        ["a body that is not JSON", "<html>accepted</html>"],
        ["a JSON scalar", "202"],
        ["a JSON array", '[{"test_run_id":"tr_42"}]']
      ].each do |description, body|
        # @intent: { entity: "Transport", action: "read a success answer", behavior: "an empty or blank answer body still reads as success with no run id", layer: "unit" }
        it "stays a success with no body for #{description}" do
          StubIngestEndpoint.run(status: 202, body: body) do |server|
            result = transport_to(server).deliver(payload)

            expect(result).to have_attributes(success?: true, outcome: :success, code: 202, reason: nil)
            expect(result.body).to be_nil
            expect(result.test_run_id).to be_nil
          end
        end
      end

      # A refusal has no body to carry, and reading one off a rejection would
      # be the same relabelling in the other direction.
      # @intent: { entity: "Transport", action: "read a success answer", behavior: "a refusal answer leaves the body nil, the reasons field being what speaks there", layer: "unit" }
      it "leaves the body nil on a refusal, where `reasons` is the field that speaks" do
        StubIngestEndpoint.run(status: 400, body: '{"message":"no"}') do |server|
          result = transport_to(server).deliver(payload)

          expect(result.body).to be_nil
          expect(result.test_run_id).to be_nil
          expect(result.reasons).to eq(["no"])
        end
      end
    end
  end

  # FIND 2, at its source. None of these raise, which is why a `rescue` alone
  # loses them all without a trace.
  describe "a non-2xx response" do
    {
      400 => "the endpoint rejected the payload",
      401 => "the API key was not accepted",
      403 => "this API key may not write to that repository",
      404 => "no ingest endpoint at that URL",
      429 => "rate limited",
      500 => nil
    }.each do |status, advice|
      context "when the endpoint answers #{status}" do
        # @intent: { entity: "Transport", action: "read a refusal", behavior: "a non-success status reports a rejection rather than a success", layer: "unit" }
        it "reports a rejection rather than a success" do
          StubIngestEndpoint.run(status: status) do |server|
            expect(transport_to(server).deliver(payload))
              .to have_attributes(success?: false, outcome: :rejected, code: status)
          end
        end

        # The number is the non-negotiable part: a 401 means "rotate the key"
        # and a 400 means "this gem built a body the platform refused", which
        # are different people's problems.
        # @intent: { entity: "Transport", action: "read a refusal", behavior: "the refusal names its status in a line a CI operator can read", layer: "unit" }
        it "names the status in something a CI operator can read" do
          StubIngestEndpoint.run(status: status) do |server|
            reason = transport_to(server).deliver(payload).reason

            expect(reason).to include("HTTP #{status}")
            expect(reason).to include(advice) if advice
          end
        end
      end
    end

    # @intent: { entity: "Transport", action: "read a refusal", behavior: "a refusal never raises, so nothing above it can be relying on an exception", layer: "unit" }
    it "does not raise, so nothing above it can be relying on one" do
      StubIngestEndpoint.run(status: 500) do |server|
        expect { transport_to(server).deliver(payload) }.not_to raise_error
      end
    end
  end

  # The platform already names the offending spec by index, file and line in
  # the body it refuses with — `Api::BaseController#render_bad_request` puts
  # every validation failure in `details` and repeats the first in `message`,
  # with a comment saying it is shaped that way *for a client to read*. Until
  # this, the client read none of it, so an operator got `HTTP 400 — the
  # endpoint rejected the payload` and had to reproduce the run to find out
  # which of 20,000 specs was wrong.
  #
  # Everything below still has to fit on one line and still has to leave the
  # `outcome` alone, which is what most of these examples are actually about.
  describe "the reasons the endpoint gave for refusing" do
    # The 400 body, verbatim in the shape `Ingest::Payload` produces it.
    let(:detail) do
      "spec 3 (spec/foo_spec.rb:9): line_number is required and must be a positive integer"
    end

    def reason_for(status:, body:)
      StubIngestEndpoint.run(status: status, body: body) do |server|
        transport_to(server).deliver(payload).reason
      end
    end

    # @intent: { entity: "Transport", action: "report refusal reasons", behavior: "an offending spec in the refusal details is named, so the run need not be reproduced to find it", layer: "unit" }
    it "names the offending spec, so the run does not have to be reproduced to find it" do
      reason = reason_for(status: 400, body: JSON.generate("details" => [detail]))

      expect(reason).to include(detail)
    end

    # Appended to, not replacing: the status is the part that says whose
    # problem this is, and it stays first.
    # @intent: { entity: "Transport", action: "report refusal reasons", behavior: "the status and the standing advice keep printing alongside the reasons", layer: "unit" }
    it "keeps the status and the advice it already printed" do
      reason = reason_for(status: 400, body: JSON.generate("details" => [detail]))

      expect(reason).to start_with("HTTP 400 — the endpoint rejected the payload")
    end

    # The 401 body has no `details` at all — `render_unauthorized` carries
    # `message` alone — so the fallback is the whole of what that status can
    # say, not a defensive extra.
    # @intent: { entity: "Transport", action: "report refusal reasons", behavior: "a body with no details falls back to its message field, which is every unauthorized answer", layer: "unit" }
    it "falls back to `message` for a body that has no details, which is every 401" do
      reason = reason_for(status: 401,
                          body: JSON.generate("error" => "unauthorized",
                                              "message" => "A valid Bearer API key is required."))

      expect(reason).to include("A valid Bearer API key is required.")
    end

    # @intent: { entity: "Transport", action: "report refusal reasons", behavior: "the full details are preferred over the first-error echo in the message field", layer: "unit" }
    it "prefers the full details over the first-error echo in `message`" do
      reason = reason_for(status: 400,
                          body: JSON.generate("message" => detail, "details" => [detail, "spec 7: name is required"]))

      expect(reason).to include("spec 7: name is required")
    end

    # `Ingest::Payload` appends one error *per bad spec* and the response caps
    # nothing (`RETAINED_REASONS_PER_ROW` bounds only the persisted row), so a
    # systemic client bug on a 20k suite answers with ~20,000 strings. Splicing
    # that list into the warning would bury the suite's own output — which is
    # the failure mode the formatter's one-warning budget exists to prevent,
    # reintroduced one layer down.
    describe "a refusal with more reasons than a line can hold" do
      let(:reason) do
        reason_for(status: 400,
                   body: JSON.generate("details" => Array.new(500) { |i| "spec #{i}: name is required" }))
      end

      # @intent: { entity: "Transport", action: "cap the reason line", behavior: "a refusal with many reasons spells out only the first few", layer: "unit" }
      it "spells out the first few" do
        expect(reason).to include("spec 0: name is required", "spec 2: name is required")
      end

      # @intent: { entity: "Transport", action: "cap the reason line", behavior: "the reasons beyond the cap are counted rather than printed", layer: "unit" }
      it "counts the rest rather than printing them" do
        expect(reason).to include("and 497 more")
        expect(reason).not_to include("spec 3: name is required")
      end

      # @intent: { entity: "Transport", action: "cap the reason line", behavior: "the whole refusal still comes out as one line", layer: "unit" }
      it "is still one line" do
        expect(reason.lines.length).to eq(1)
      end
    end

    # A 413 from a proxy or a 502 from a load balancer never reaches the
    # platform's renderer, so the body is HTML, or empty, or a truncated
    # fragment of JSON. None of that is a *delivery* failure — the request
    # plainly arrived and was refused — so it must not reach {#deliver}'s
    # `rescue` and relabel the outcome as `:failed`, which would tell the
    # operator something untrue for the sake of a decoration.
    describe "a body that cannot be read" do
      {
        "empty" => "",
        "HTML from a proxy" => "<html><head><title>413 Request Entity Too Large</title></head></html>",
        "truncated JSON" => '{"details":["spec 3 (spec',
        "a JSON scalar" => '"nope"',
        "JSON with details of the wrong shape" => '{"details":[{"spec":3}]}',
        "JSON with no key this cares about" => '{"error":"bad_request"}'
      }.each do |description, body|
        context "when the body is #{description}" do
          # @intent: { entity: "Transport", action: "survive unreadable bodies", behavior: "a body that cannot be parsed still reports a rejection rather than a failure", layer: "unit" }
          it "still reports a rejection rather than a failure" do
            StubIngestEndpoint.run(status: 400, body: body) do |server|
              expect(transport_to(server).deliver(payload))
                .to have_attributes(outcome: :rejected, code: 400)
            end
          end

          # @intent: { entity: "Transport", action: "survive unreadable bodies", behavior: "an unreadable body degrades to exactly the line printed before bodies were parsed", layer: "unit" }
          it "degrades to exactly the line it printed before" do
            expect(reason_for(status: 400, body: body))
              .to eq("HTTP 400 — the endpoint rejected the payload")
          end
        end
      end
    end

    # Whatever answered is on the network, and the warning goes to a CI log
    # that later gets read as lines. A body carrying newlines could otherwise
    # forge output that looks like it came from the suite, or from this gem.
    describe "a reason carrying things a log line cannot hold" do
      # @intent: { entity: "Transport", action: "sanitise reasons", behavior: "a newline inside a reason is flattened rather than emitting a second log line", layer: "unit" }
      it "flattens newlines instead of emitting a second line" do
        reason = reason_for(status: 400,
                            body: JSON.generate("details" => ["spec 3 failed\nSpecGuard: everything is fine"]))

        expect(reason.lines.length).to eq(1)
        expect(reason).to include("spec 3 failed SpecGuard: everything is fine")
      end

      # @intent: { entity: "Transport", action: "sanitise reasons", behavior: "control characters are stripped so a colour escape cannot survive into logs", layer: "unit" }
      it "strips control characters, so a colour escape cannot survive" do
        reason = reason_for(status: 400,
                            body: JSON.generate("details" => ["spec 3 \e[31mred\e[0m"]))

        expect(reason).not_to include("\e")
      end

      # @intent: { entity: "Transport", action: "sanitise reasons", behavior: "a single enormous reason is capped rather than printed in full", layer: "unit" }
      it "caps a single enormous reason rather than printing all of it" do
        reason = reason_for(status: 400, body: JSON.generate("details" => ["x" * 5_000]))

        expect(reason.length).to be < 400
      end
    end
  end

  # Criterion 4. One shape for the whole family, so the caller has one branch.
  describe "a request that never gets an answer" do
    # @intent: { entity: "Transport", action: "survive no answer", behavior: "a refused connection reports a failure rather than raising", layer: "unit" }
    it "reports a failure when the connection is refused" do
      # Bound, then closed: the port is guaranteed to have been free, and
      # nothing is listening on it now.
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server.close

      result = described_class.new(endpoint: "http://127.0.0.1:#{port}", api_key: "k", timeout: 2)
                              .deliver(payload)

      expect(result).to have_attributes(success?: false, outcome: :failed)
      expect(result.error).to be_a(SystemCallError)
    end

    # @intent: { entity: "Transport", action: "survive no answer", behavior: "a host that does not resolve reports a failure the same way", layer: "unit" }
    it "reports a failure when the host does not resolve" do
      result = described_class
               .new(endpoint: "http://specguard.invalid", api_key: "k", timeout: 2)
               .deliver(payload)

      expect(result).to have_attributes(success?: false, outcome: :failed)
      expect(result.reason).to be_a(String)
    end

    # Criterion 6, at the unit level: the budget is the budget, and a peer that
    # accepts the connection and then says nothing is the shape that would
    # otherwise sit there for `Net::HTTP`'s stock 60 seconds.
    # @intent: { entity: "Transport", action: "survive no answer", behavior: "a silent endpoint is given up on within the configured budget", layer: "unit" }
    it "gives up on a silent endpoint within the configured budget" do
      StubIngestEndpoint.run(hang: true) do |server|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = transport_to(server, timeout: 1).deliver(payload)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

        expect(result.outcome).to eq(:failed)
        expect(result.error).to be_a(Net::ReadTimeout)
        expect(elapsed).to be < 5
      end
    end
  end

  # A misconfiguration is delivered as a failure like any other, rather than as
  # an exception the formatter's guard would have to catch separately.
  describe "an endpoint that is not a URL" do
    ["", "   ", nil].each do |value|
      # @intent: { entity: "Transport", action: "refuse bad endpoints", behavior: "an endpoint value that is not a URL reports a failure rather than posting anywhere", layer: "unit" }
      it "reports a failure rather than posting to #{value.inspect}" do
        result = described_class.new(endpoint: value, api_key: "k", timeout: 1).deliver(payload)

        expect(result.outcome).to eq(:failed)
        expect(result.reason).to include("no endpoint is configured")
      end
    end

    # `URI.parse` returns a `URI::Generic` with a nil host for this rather than
    # raising, and `Net::HTTP` would then try to connect to nowhere.
    # @intent: { entity: "Transport", action: "refuse bad endpoints", behavior: "a bare host with no scheme is rejected", layer: "unit" }
    it "rejects a bare host with no scheme" do
      result = described_class.new(endpoint: "specguard.example.com", api_key: "k", timeout: 1)
                              .deliver(payload)

      expect(result.outcome).to eq(:failed)
      expect(result.reason).to include("http:// or https://")
    end

    # @intent: { entity: "Transport", action: "refuse bad endpoints", behavior: "a scheme it cannot speak is rejected", layer: "unit" }
    it "rejects a scheme it cannot speak" do
      result = described_class.new(endpoint: "ftp://specguard.example.com", api_key: "k", timeout: 1)
                              .deliver(payload)

      expect(result.outcome).to eq(:failed)
    end
  end

  describe "#uri" do
    # @intent: { entity: "Transport", action: "build the target uri", behavior: "the platform path is appended to the configured installation", layer: "unit" }
    it "appends the platform's path to the configured installation" do
      transport = described_class.new(endpoint: "https://specguard.example.com", api_key: "k")

      expect(transport.uri.to_s).to eq("https://specguard.example.com/api/v1/ingest")
    end

    # A trailing slash is what a copy-paste out of a browser's address bar
    # gives you, and `"https://host/" + "/api/v1/ingest"` is a 404.
    # @intent: { entity: "Transport", action: "build the target uri", behavior: "a trailing slash on the endpoint does not double the path separator", layer: "unit" }
    it "does not double the slash when the endpoint has a trailing one" do
      transport = described_class.new(endpoint: "https://specguard.example.com///", api_key: "k")

      expect(transport.uri.to_s).to eq("https://specguard.example.com/api/v1/ingest")
    end

    # SpecGuard is self-hostable, and a self-hosted one may well sit behind a
    # path on a shared hostname.
    # @intent: { entity: "Transport", action: "build the target uri", behavior: "a path prefix on the installation is kept for mounts under one", layer: "unit" }
    it "keeps a path prefix, for an installation mounted under one" do
      transport = described_class.new(endpoint: "https://tools.example.com/specguard", api_key: "k")

      expect(transport.uri.to_s).to eq("https://tools.example.com/specguard/api/v1/ingest")
    end

    # @intent: { entity: "Transport", action: "build the target uri", behavior: "an https endpoint uses TLS and an http one does not", layer: "unit" }
    it "uses TLS for an https endpoint and not for an http one" do
      expect(described_class.new(endpoint: "https://x.example.com", api_key: "k").uri.scheme).to eq("https")
      expect(described_class.new(endpoint: "http://x.example.com", api_key: "k").uri.scheme).to eq("http")
    end
  end

  describe "the timeout budget" do
    def timeout_for(value) = described_class.new(endpoint: "https://x.example.com", api_key: "k",
                                                 timeout: value).timeout

    # @intent: { entity: "Transport", action: "bound the timeout", behavior: "the timeout defaults to the configuration budget rather than the http library sixty seconds", layer: "unit" }
    it "defaults to the configuration's, not Net::HTTP's 60 seconds" do
      expect(described_class.new(endpoint: "https://x.example.com", api_key: "k").timeout).to eq(10)
    end

    # @intent: { entity: "Transport", action: "bound the timeout", behavior: "a configured budget is honoured", layer: "unit" }
    it "honours a configured budget" do
      expect(timeout_for(2.5)).to eq(2.5)
    end

    # @intent: { entity: "Transport", action: "bound the timeout", behavior: "a budget arriving as the string an environment variable carries is accepted", layer: "unit" }
    it "accepts the string a configured ENV variable arrives as" do
      expect(timeout_for("3")).to eq(3.0)
    end

    # A `0` here means "time out immediately" to Net::HTTP: a typo would turn
    # into a run that silently never delivers anything.
    [0, -1, "ten", nil, Float::INFINITY, Float::NAN].each do |value|
      # @intent: { entity: "Transport", action: "bound the timeout", behavior: "an unparseable budget value falls back to the default rather than being trusted", layer: "unit" }
      it "falls back to the default rather than trusting #{value.inspect}" do
        expect(timeout_for(value)).to eq(10)
      end
    end
  end

  # The never-block-CI contract, seen from inside the transport: it must not be
  # possible for this class to end a suite, and it must still be possible to
  # stop one with Ctrl-C.
  describe "what it refuses to let escape" do
    # @intent: { entity: "Transport", action: "contain escapes", behavior: "a ScriptError, which a bare rescue misses, is swallowed into a failure result", layer: "unit" }
    it "swallows a ScriptError, which a bare rescue would miss" do
      allow(Net::HTTP).to receive(:new).and_raise(NotImplementedError, "nope")

      result = described_class.new(endpoint: "https://x.example.com", api_key: "k").deliver(payload)

      expect(result).to have_attributes(outcome: :failed)
      expect(result.reason).to include("NotImplementedError")
    end

    # @intent: { entity: "Transport", action: "contain escapes", behavior: "a payload that will not serialize is swallowed rather than escaping deliver", layer: "unit" }
    it "swallows a payload that will not serialize" do
      unserializable = { "specs" => [Object.new] }
      allow(JSON).to receive(:generate).and_raise(JSON::GeneratorError, "cannot serialize")

      expect(described_class.new(endpoint: "https://x.example.com", api_key: "k").deliver(unserializable))
        .to have_attributes(outcome: :failed)
    end

    # Ctrl-C must stay Ctrl-C. Reporting an interrupt as "delivery failed" is
    # its own small lie, and would make a long suite harder to stop.
    # @intent: { entity: "Transport", action: "contain escapes", behavior: "an interrupt is not swallowed, keeping ctrl-c working during delivery", layer: "unit" }
    it "does NOT swallow an interrupt" do
      allow(Net::HTTP).to receive(:new).and_raise(Interrupt)

      expect { described_class.new(endpoint: "https://x.example.com", api_key: "k").deliver(payload) }
        .to raise_error(Interrupt)
    end
  end

  # SPGD-1577: an `sga_` agent key covers a SET of repositories, so the request
  # (not the credential) names the run's repository, as a path segment.
  describe "the repository-scoped route" do
    def repo_transport_to(server, repository_id, **options)
      described_class.new(endpoint: server.endpoint, api_key: "sga_abc123", timeout: 5,
                          repository_id: repository_id, **options)
    end

    # @intent: { entity: "Transport", action: "build the target uri", behavior: "with a repository id the uri path is the repository-scoped ingest route", layer: "unit" }
    it "targets /api/v1/repositories/<id>/ingest when a repository id is given" do
      transport = described_class.new(endpoint: "https://specguard.example.com", api_key: "k", repository_id: "42")

      expect(transport.uri.path).to eq("/api/v1/repositories/42/ingest")
    end

    # @intent: { entity: "Transport", action: "build the target uri", behavior: "a nil or blank repository id leaves the uri byte-identical to the unscoped one", layer: "unit" }
    it "is byte-identical to the unscoped uri for a nil or blank id" do
      plain = described_class.new(endpoint: "https://specguard.example.com", api_key: "k").uri.to_s

      [nil, "", "   "].each do |blank|
        scoped = described_class.new(endpoint: "https://specguard.example.com", api_key: "k", repository_id: blank)
        expect(scoped.uri.to_s).to eq(plain)
      end
    end

    # @intent: { entity: "Transport", action: "deliver the run", behavior: "with a repository id the request on the wire carries the scoped path and the same bearer header", layer: "unit" }
    it "puts the scoped path on the wire with the same Bearer header" do
      StubIngestEndpoint.run do |server|
        repo_transport_to(server, "42").deliver(payload)
        request = server.requests.first

        expect(request.path).to eq("/api/v1/repositories/42/ingest")
        expect(request.headers["authorization"]).to eq("Bearer sga_abc123")
        expect(request.json).to eq(payload)
      end
    end

    # @intent: { entity: "Transport", action: "compress large runs", behavior: "a large run on the repository-scoped route is still gzipped", layer: "unit" }
    it "still gzips a run over the threshold on the scoped route" do
      big = { "commit_sha" => "a" * 40, "branch" => "main",
              "specs" => Array.new(2_000) do |i|
                { "file_path" => "spec/f#{i}_spec.rb", "line_number" => i, "name" => "example number #{i}",
                  "duration" => 0.01, "outcome" => "passed", "status" => "unannotated", "intent" => nil }
              end }
      expect(big.to_json.bytesize).to be > described_class::GZIP_THRESHOLD_BYTES

      StubIngestEndpoint.run do |server|
        repo_transport_to(server, "42").deliver(big)
        request = server.requests.first

        expect(request.path).to eq("/api/v1/repositories/42/ingest")
        expect(request.headers["content-encoding"]).to eq("gzip")
        expect(request.json).to eq(big)
      end
    end

    ["4/../x", "42?x=1", "..", "42#f", "4 2", "a/b", "%2e%2e", "4.2"].each do |unsafe|
      # @intent: { entity: "Transport", action: "build the target uri", behavior: "a repository id that is unsafe as a path segment is refused rather than concatenated raw", layer: "unit" }
      it "refuses the path-unsafe id #{unsafe.inspect} from #uri" do
        transport = described_class.new(endpoint: "https://specguard.example.com", api_key: "k",
                                        repository_id: unsafe)

        expect { transport.uri }.to raise_error(ArgumentError, /SPECGUARD_REPOSITORY_ID/)
      end

      # @intent: { entity: "Transport", action: "deliver the run", behavior: "a path-unsafe repository id never reaches the wire", layer: "unit" }
      it "sends nothing for the path-unsafe id #{unsafe.inspect}" do
        StubIngestEndpoint.run do |server|
          result = repo_transport_to(server, unsafe).deliver(payload)

          expect(result).to have_attributes(outcome: :failed)
          expect(result.error).to be_a(ArgumentError)
          expect(server.requests).to be_empty
        end
      end
    end

    # @intent: { entity: "Transport", action: "read a refusal", behavior: "a 404 under a repository id does not tell the user to check the endpoint and names the repository id", layer: "unit" }
    it "renders a 404 under a repository id without the endpoint advice" do
      StubIngestEndpoint.run(status: 404) do |server|
        reason = repo_transport_to(server, "42").deliver(payload).reason

        expect(reason).to eq("HTTP 404 — no repository with that id is available to this API key — " \
                             "check SPECGUARD_REPOSITORY_ID")
        expect(reason).not_to include("SPECGUARD_ENDPOINT")
      end
    end

    # @intent: { entity: "Transport", action: "read a refusal", behavior: "a 404 without a repository id keeps the existing endpoint advice unchanged", layer: "unit" }
    it "keeps today's exact 404 sentence when no repository id is configured" do
      StubIngestEndpoint.run(status: 404) do |server|
        reason = transport_to(server).deliver(payload).reason

        expect(reason).to eq("HTTP 404 — no ingest endpoint at that URL — check SPECGUARD_ENDPOINT")
      end
    end

    # @intent: { entity: "Transport", action: "read a refusal", behavior: "a result built without the repository flag keeps the existing 404 sentence", layer: "unit" }
    it "leaves a Result built without the flag on the existing wording" do
      result = described_class::Result.new(outcome: :rejected, code: 404)

      expect(result.reason).to eq("HTTP 404 — no ingest endpoint at that URL — check SPECGUARD_ENDPOINT")
    end
  end

  describe ".from_configuration" do
    let(:configuration) do
      instance_double(
        SpecGuard::Client::Configuration,
        endpoint: "https://specguard.example.com", api_key: "sgk_abc", timeout: 7, repository_id: "42"
      )
    end

    # @intent: { entity: "Transport", action: "build from a configuration", behavior: "forwards endpoint, api_key, timeout and repository_id to the constructor unchanged", layer: "unit" }
    it "passes all four configuration attributes to Transport.new" do
      allow(described_class).to receive(:new).and_call_original

      described_class.from_configuration(configuration)

      expect(described_class).to have_received(:new).with(
        endpoint: "https://specguard.example.com", api_key: "sgk_abc", timeout: 7, repository_id: "42"
      )
    end

    # @intent: { entity: "Transport", action: "build from a configuration", behavior: "the built transport carries the configured timeout and repository-scoped uri", layer: "unit" }
    it "returns a transport scoped to the configured repository and timeout" do
      transport = described_class.from_configuration(configuration)

      expect(transport).to be_a(described_class)
      expect(transport.timeout).to eq(7)
      expect(transport.uri.to_s).to eq("https://specguard.example.com/api/v1/repositories/42/ingest")
    end
  end
end
