# frozen_string_literal: true

require "json"
require "open3"
require "stringio"
require "tmpdir"

require "specguard/rspec/ingest_cli"

require_relative "../../support/stub_ingest_endpoint"

# `specguard-ingest`, against a real socket.
#
# The command exists to make one README sentence true — the formatter writes an
# undelivered run to `log/test_results.jsonl` "so the run can be replayed later"
# — and the thing worth testing is therefore not that a method was called but
# that a saved line comes back off disk and lands on the endpoint as the same
# body it was refused as. So this drives {StubIngestEndpoint} rather than a
# double, exactly as `transport_spec.rb` does and for the reason argued there.
#
# The other half is the exit contract, which is `specguard-lint`'s (SPGD-12 §1)
# transferred: Ruby maps every internal failure onto exit 1, and 1 is already
# spent here on "the endpoint refused a line". Every exit-2 example below is
# guarding the same property from a different door — a tool failure must never
# borrow the code that means "the platform said no to your run".
#
# NOW registered in `regression_targets_spec.rb`, which it deliberately was not
# before SPGD-669. That file locks `specguard-lint`'s default output path for
# SPGD-305's constraint — the `--json` renderer must not have moved a byte of the
# human one — and the reason this command was exempt was that it had no second
# renderer to be held to. It has one now, and the same edits that gave it one are
# on the default path: `#report` and `#list` grew a branch, `#summary_line` took
# its counts as an argument, and `#list_row` reads a struct instead of a payload.
# So the byte lock is there for the same reason lint's is, and the behavioural
# examples stay here, next to the behaviour they describe.
RSpec.describe SpecGuard::RSpec::IngestCLI do
  subject(:cli) { described_class.new(stdout: stdout, stderr: stderr, env: env) }

  let(:stdout) { StringIO.new }
  let(:stderr) { StringIO.new }
  let(:endpoint) { nil }
  let(:api_key) { "sgk_abc123" }
  let(:env) do
    { "SPECGUARD_ENDPOINT" => endpoint, "SPECGUARD_API_KEY" => api_key, "SPECGUARD_TIMEOUT" => "5" }.compact
  end

  def out = stdout.string
  def err = stderr.string

  # One whole run, as `SpecGuard::RSpecFormatter#payload` assembles it and as
  # `#append` writes it: `JSON.generate` over the same Hash the transport would
  # have posted, which is the identity this command is built on.
  def run_payload(ci_run_id: "17442", commit_sha: "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2")
    {
      "commit_sha" => commit_sha,
      "branch" => "main",
      "ci_run_id" => ci_run_id,
      "shard_id" => "1",
      "duration_seconds" => 1.25,
      "specs" => [
        { "id" => "./spec/orders_spec.rb[1:1]", "spec_file_path" => "spec/orders_spec.rb",
          "file_path" => "spec/orders_spec.rb", "line_number" => 4, "name" => "Order checks out",
          "duration" => 0.01, "outcome" => "passed", "status" => "unannotated", "intent" => nil }
      ]
    }
  end

  # A sink file with the given lines, written exactly as the formatter writes
  # one: `JSON.generate(data)` plus a newline, appended.
  def sink(*lines)
    path = File.join(@dir, "test_results.jsonl")
    File.write(path, lines.map { |line| "#{line.is_a?(String) ? line : JSON.generate(line)}\n" }.join)
    path
  end

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  # A port nothing is listening on. Bound and released rather than picked out of
  # the air, so the example cannot collide with something that happens to be
  # running on this machine.
  def dead_endpoint
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    server.close
    "http://127.0.0.1:#{port}"
  end

  describe "0 — every line accepted" do
    # @intent: { entity: "specguard-ingest", action: "re-deliver a saved line", behavior: "the saved run line goes to the endpoint byte for byte as the body it was offered", layer: "unit" }
    it "re-delivers the saved line as the body the endpoint was offered, byte for byte" do
      payload = run_payload

      StubIngestEndpoint.run do |server|
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                             .run([sink(payload)])

        expect(code).to eq(0)
        expect(server.requests.length).to eq(1)
        expect(server.requests.first.json).to eq(payload)
        expect(server.requests.first.path).to eq("/api/v1/ingest")
        expect(server.requests.first.headers["authorization"]).to eq("Bearer sgk_abc123")
      end
    end

    # Criterion 1, whole: the run refused for a rotated key, replayed after the
    # secret is fixed, reaches the platform. Every line, in order.
    # @intent: { entity: "specguard-ingest", action: "deliver a multi-run file", behavior: "every line of a file holding several runs is delivered", layer: "unit" }
    it "delivers every line of a multi-run file" do
      StubIngestEndpoint.run do |server|
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                             .run([sink(run_payload(ci_run_id: "1"),
                                        run_payload(ci_run_id: "2"),
                                        run_payload(ci_run_id: "3"))])

        expect(code).to eq(0)
        expect(server.requests.map { |request| request.json["ci_run_id"] }).to eq(%w[1 2 3])
      end
    end

    # @intent: { entity: "specguard-ingest", action: "report each line", behavior: "each line is reported by its number with the run id the endpoint said it landed on", layer: "unit" }
    it "reports each line by its number, with the run the endpoint said it landed on" do
      StubIngestEndpoint.run(body: '{"test_run_id":"tr_7"}') do |server|
        path = sink(run_payload(ci_run_id: "17442"))
        described_class.new(stdout: stdout, stderr: stderr,
                            env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([path])

        expect(out).to eq(<<~OUT)
          line 1: accepted — HTTP 202, test_run_id tr_7, ci_run_id 17442
          specguard-ingest: delivered 1 of 1 run from #{path}
        OUT
      end
    end

    # Criterion 4. The 202 body carries no created-versus-updated flag, so the
    # only honest statement about folding is one made from two observations:
    # same run identity out, same run id back. Note what is NOT said — nothing
    # about a line WITHOUT a `ci_run_id`, whose new row is created inside
    # `RunRecorder` where this command cannot see it.
    # @intent: { entity: "specguard-ingest", action: "report folding", behavior: "folding is stated only where two delivered lines actually observed it", layer: "unit" }
    it "states folding only where two lines observed it" do
      StubIngestEndpoint.run(body: '{"test_run_id":"tr_7"}') do |server|
        path = sink(run_payload(ci_run_id: "17442"), run_payload(ci_run_id: "17442"))
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([path])

        expect(code).to eq(0)
        expect(out).to eq(<<~OUT)
          line 1: accepted — HTTP 202, test_run_id tr_7, ci_run_id 17442
          line 2: accepted — HTTP 202, test_run_id tr_7, ci_run_id 17442
          specguard-ingest: delivered 2 of 2 runs from #{path}
          specguard-ingest: lines 1, 2 carried ci_run_id 17442 and each came back with test_run_id tr_7 — the endpoint folded them onto one run
        OUT
      end
    end

    # @intent: { entity: "specguard-ingest", action: "report folding", behavior: "a line with no run identity is said so and nothing further is claimed about it", layer: "unit" }
    it "says a line carried no run identity, and claims nothing further about it" do
      StubIngestEndpoint.run(body: '{"test_run_id":"tr_7"}') do |server|
        described_class.new(stdout: stdout, stderr: stderr,
                            env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                       .run([sink(run_payload(ci_run_id: nil))])

        expect(out).to include("line 1: accepted — HTTP 202, test_run_id tr_7, no ci_run_id")
        expect(out).not_to include("folded")
        expect(out).not_to include("created")
      end
    end

    # Two lines that came back with the same id but went out with DIFFERENT run
    # identities are not evidence of anything the endpoint did on purpose, so
    # no sentence is manufactured for them.
    # @intent: { entity: "specguard-ingest", action: "report folding", behavior: "no folding is claimed for lines that shared no ci run id", layer: "unit" }
    it "does not claim folding for lines that shared no ci_run_id" do
      StubIngestEndpoint.run(body: '{"test_run_id":"tr_7"}') do |server|
        described_class.new(stdout: stdout, stderr: stderr,
                            env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                       .run([sink(run_payload(ci_run_id: "1"), run_payload(ci_run_id: "2"))])

        expect(out).not_to include("folded")
      end
    end

    # A 202 whose body will not parse is still a 202: the platform stored the
    # run before it wrote the body. The id is reported as unknown rather than
    # the acceptance being downgraded.
    # @intent: { entity: "specguard-ingest", action: "report each line", behavior: "an unreadable success body reports as an unknown id rather than a failure", layer: "unit" }
    it "reports an unreadable success body as an unknown id, not as a failure" do
      StubIngestEndpoint.run(body: "<html>accepted</html>") do |server|
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                             .run([sink(run_payload)])

        expect(code).to eq(0)
        expect(out).to include("line 1: accepted — HTTP 202, test_run_id (not reported), ci_run_id 17442")
      end
    end
  end

  describe "1 — the endpoint refused a line" do
    # @intent: { entity: "specguard-ingest exit contract", action: "render a refusal", behavior: "a refused line exits one and renders the endpoint own reasons", layer: "unit" }
    it "exits 1 and renders the endpoint's own reasons" do
      body = JSON.generate(
        "message" => "payload is invalid",
        "details" => ["spec 3 (spec/orders_spec.rb:9): line_number is required and must be a positive integer"]
      )

      StubIngestEndpoint.run(status: 400, body: body) do |server|
        path = sink(run_payload)
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([path])

        expect(code).to eq(1)
        expect(out).to eq(<<~OUT)
          line 1: refused — HTTP 400 — the endpoint rejected the payload — spec 3 (spec/orders_spec.rb:9): line_number is required and must be a positive integer
          specguard-ingest: delivered 0 of 1 run from #{path}; 1 refused
        OUT
      end
    end

    # The 400 is the ONLY status that reaches this code, and this is why:
    # `Api::V1::IngestsController#create` forms an opinion about a payload in
    # exactly one place, `render_bad_request(payload.errors)`. Every other
    # non-2xx is covered under exit 2 below.
    #
    # The boundary is therefore drawn on the STATUS, never on what the body
    # happens to say. This body is the 401's message word for word, and it is
    # still a 400: the code decides the verdict, and the body only decides what
    # gets echoed after it. Read against the 401 row in the table under exit 2
    # — which says something equally auth-flavoured and exits 2 — the pair
    # shows the discriminator is the status and nothing else.
    # @intent: { entity: "specguard-ingest exit contract", action: "render a refusal", behavior: "the status alone is enough to exit one whatever the body reads like", layer: "unit" }
    it "exits 1 on the status alone, whatever the body reads like" do
      StubIngestEndpoint.run(status: 400, body: '{"message":"invalid api key"}') do |server|
        path = sink(run_payload)
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([path])

        expect(code).to eq(1)
        expect(out).to include(
          "line 1: refused — HTTP 400 — the endpoint rejected the payload — invalid api key"
        )
      end
    end

    # Criterion 3. A file that was only partly accepted must be resumable, and
    # that needs the report to say WHICH lines landed — not how many.
    # @intent: { entity: "specguard-ingest exit contract", action: "render a refusal", behavior: "a partly-accepted file is numbered line by line in the report", layer: "unit" }
    it "numbers a partly-accepted file line by line" do
      responses = [{ status: 202 }, { status: 400, body: '{"message":"spec 2: outcome is required"}' },
                   { status: 202 }]

      StubIngestEndpoint.run(body: '{"test_run_id":"tr_7"}', responses: responses) do |server|
        path = sink(run_payload(ci_run_id: "a"), run_payload(ci_run_id: "b"), run_payload(ci_run_id: "c"))
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([path])

        expect(code).to eq(1)
        expect(out).to eq(<<~OUT)
          line 1: accepted — HTTP 202, test_run_id tr_7, ci_run_id a
          line 2: refused — HTTP 400 — the endpoint rejected the payload — spec 2: outcome is required
          line 3: accepted — HTTP 202, test_run_id tr_7, ci_run_id c
          specguard-ingest: delivered 2 of 3 runs from #{path}; 1 refused
        OUT
      end
    end

    # @intent: { entity: "specguard-ingest exit contract", action: "render a refusal", behavior: "the lines after a refusal are still delivered rather than stopping at the first", layer: "unit" }
    it "delivers the lines after a refusal rather than stopping at the first" do
      StubIngestEndpoint.run(responses: [{ status: 400 }, { status: 202 }]) do |server|
        described_class.new(stdout: stdout, stderr: stderr,
                            env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                       .run([sink(run_payload(ci_run_id: "a"), run_payload(ci_run_id: "b"))])

        expect(server.requests.length).to eq(2)
      end
    end
  end

  describe "2 — the tool could not do its job" do
    # The `EXIT_MISUSE` reasoning, verbatim from `cli.rb`: a run that delivered
    # nothing must not report as a content failure.
    context "when delivery is not configured" do
      let(:endpoint) { nil }

      # @intent: { entity: "specguard-ingest exit contract", action: "exit misuse", behavior: "a missing endpoint exits two naming the endpoint without reading the file", layer: "unit" }
      it "exits 2 naming the endpoint, without reading the file" do
        expect(cli.run([sink(run_payload)])).to eq(2)
        expect(err).to eq("specguard-ingest: error: no endpoint is configured (set SPECGUARD_ENDPOINT)\n")
        expect(out).to be_empty
      end

      # Named separately from the endpoint: they fail for different reasons and
      # are fixed in different places.
      # @intent: { entity: "specguard-ingest exit contract", action: "exit misuse", behavior: "a missing api key alone exits two naming the key", layer: "unit" }
      it "exits 2 naming the API key when only that is missing" do
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: { "SPECGUARD_ENDPOINT" => "https://specguard.example.com" })
                             .run([sink(run_payload)])

        expect(code).to eq(2)
        expect(err).to eq("specguard-ingest: error: no API key is configured (set SPECGUARD_API_KEY)\n")
      end

      # One exit 2 rather than N identical delivery failures: a malformed
      # endpoint is a configuration problem, and reporting it once as one is
      # the difference between "fix this variable" and "the network is flaky".
      # @intent: { entity: "specguard-ingest exit contract", action: "exit misuse", behavior: "an endpoint that is not an http URL exits two", layer: "unit" }
      it "exits 2 on an endpoint that is not an http(s) URL" do
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => "specguard.example.com"))
                             .run([sink(run_payload, run_payload)])

        expect(code).to eq(2)
        expect(err).to include("endpoint must be an http:// or https:// URL")
      end
    end

    context "when the file cannot be read" do
      let(:endpoint) { "https://specguard.example.com" }

      # @intent: { entity: "specguard-ingest exit contract", action: "exit misuse", behavior: "a file that does not exist exits two", layer: "unit" }
      it "exits 2 on a file that does not exist" do
        expect(cli.run([File.join(@dir, "gone.jsonl")])).to eq(2)
        expect(err).to eq("specguard-ingest: error: no such file: #{File.join(@dir, 'gone.jsonl')}\n")
      end

      # @intent: { entity: "specguard-ingest exit contract", action: "exit misuse", behavior: "a directory handed as the file exits two", layer: "unit" }
      it "exits 2 on a directory" do
        expect(cli.run([@dir])).to eq(2)
        expect(err).to eq("specguard-ingest: error: not a file: #{@dir}\n")
      end

      # @intent: { entity: "specguard-ingest exit contract", action: "exit misuse", behavior: "a file the tool may not open exits two", layer: "unit" }
      it "exits 2 on a file it may not open" do
        path = sink(run_payload)
        File.chmod(0o000, path)
        skip "running as root, which can read an unreadable file" if File.readable?(path)

        expect(cli.run([path])).to eq(2)
        expect(err).to include("could not read #{path}")
      end
    end

    context "when a line cannot be parsed" do
      # @intent: { entity: "specguard-ingest exit contract", action: "rank the codes", behavior: "a tool failure outranks a refusal waiting on the same file", layer: "unit" }
      it "exits 2, and 2 outranks a refusal on the same file" do
        StubIngestEndpoint.run(status: 400, body: '{"message":"no"}') do |server|
          path = sink(run_payload, "{not json", run_payload)
          code = described_class.new(stdout: stdout, stderr: stderr,
                                     env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([path])

          expect(code).to eq(2)
          expect(out).to include("line 2: unparseable — could not parse the line as JSON:")
          expect(out).to include("specguard-ingest: delivered 0 of 3 runs from #{path}; " \
                                 "2 refused; 1 could not be parsed")
        end
      end

      # A truncated last line — a sink written by a process that was killed —
      # must not cost the lines before it.
      # @intent: { entity: "specguard-ingest exit contract", action: "rank the codes", behavior: "every line that could be parsed is still delivered when others could not", layer: "unit" }
      it "still delivers every line it could parse" do
        StubIngestEndpoint.run do |server|
          code = described_class.new(stdout: stdout, stderr: stderr,
                                     env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                               .run([sink(run_payload(ci_run_id: "a"), run_payload(ci_run_id: "b"),
                                          '{"commit_sha":"abc","spe')])

          expect(code).to eq(2)
          expect(server.requests.map { |request| request.json["ci_run_id"] }).to eq(%w[a b])
        end
      end

      # `JSON.parse` answers a bare `"text"` line with a String and `null` with
      # nil. Neither is a run, and neither may be posted as one.
      [['"a bare string"', "String"], ["null", "NilClass"], ["[1,2]", "Array"], ["42", "Integer"]].each do |line, type|
        # @intent: { entity: "specguard-ingest exit contract", action: "refuse non-run lines", behavior: "a line that parses but is not a run is refused rather than posted", layer: "unit" }
        it "refuses to post #{line}, which parses but is not a run" do
          StubIngestEndpoint.run do |server|
            code = described_class.new(stdout: stdout, stderr: stderr,
                                       env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([sink(line)])

            expect(code).to eq(2)
            expect(out).to include("line 1: unparseable — the line is #{type} JSON, and a run is an object")
            expect(server.requests).to be_empty
          end
        end
      end

      # Pointing this command at a binary file is the obvious way to get a line
      # that is not valid UTF-8, and `String#strip` raises on one. Reported as
      # the line problem it is, rather than as an internal error — this tool is
      # not broken, it was handed something that is not a run.
      # @intent: { entity: "specguard-ingest exit contract", action: "refuse non-run lines", behavior: "a line that is not valid UTF-8 is reported as unparseable rather than as a bug", layer: "unit" }
      it "reports a line that is not valid UTF-8 as unparseable, not as a bug in itself" do
        path = File.join(@dir, "binary.jsonl")
        File.open(path, "wb") do |file|
          file.write("#{JSON.generate(run_payload)}\n")
          file.write([0xC3, 0x28, 0xFF, 0x0A].pack("C*"))
        end

        StubIngestEndpoint.run do |server|
          code = described_class.new(stdout: stdout, stderr: stderr,
                                     env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([path])

          expect(code).to eq(2)
          expect(out).to include("line 2: unparseable — the line is not valid UTF-8, so it cannot be a run")
          expect(err).to be_empty
          # The good line still landed.
          expect(server.requests.length).to eq(1)
        end
      end
    end

    # The endpoint never answered, so no verdict about the content exists.
    # Reporting this as a 1 would be the tool telling an operator their run is
    # bad on the strength of a socket error.
    # @intent: { entity: "specguard-ingest exit contract", action: "survive an unreachable endpoint", behavior: "an endpoint that cannot be reached at all exits two", layer: "unit" }
    it "exits 2 when the endpoint could not be reached at all" do
      code = described_class.new(stdout: stdout, stderr: stderr,
                                 env: env.merge("SPECGUARD_ENDPOINT" => dead_endpoint,
                                                "SPECGUARD_TIMEOUT" => "2")).run([sink(run_payload)])

      expect(code).to eq(2)
      expect(out).to include("line 1: not delivered — Errno::ECONNREFUSED")
      expect(out).to include("1 could not be delivered")
    end

    # `Transport::Result`'s `:rejected` means "a non-2xx came back", which is
    # NOT the claim "the endpoint read this payload and judged it". The platform
    # answers a 401 from `authenticate_api_key!`'s `before_action` without ever
    # constructing `Ingest::Payload`, and a 403, 404, 429 or 5xx never reaches a
    # body either. Nothing was stored in any of them, so none of them may borrow
    # the code that means "your run was refused".
    describe "when the endpoint answered without ever reading the payload" do
      {
        401 => "the API key was not accepted",
        403 => "this API key may not write to that repository",
        404 => "no ingest endpoint at that URL — check SPECGUARD_ENDPOINT",
        429 => "rate limited by the endpoint",
        500 => nil,
        503 => nil
      }.each do |status, advice|
        # @intent: { entity: "specguard-ingest exit contract", action: "survive an unreachable endpoint", behavior: "a status answered without reading the payload reports as not delivered and exits two", layer: "unit" }
        it "exits 2 for a #{status}, reporting it as not delivered" do
          StubIngestEndpoint.run(status: status, body: '{"message":"nope"}') do |server|
            code = described_class.new(stdout: stdout, stderr: stderr,
                                       env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                                 .run([sink(run_payload)])

            expect(code).to eq(2)
            expect(out).to include("line 1: not delivered — HTTP #{status}")
            expect(out).to include(advice) if advice
            expect(out).to include("1 could not be delivered")
          end
        end
      end

      # The case that fixes the rule in place: an UNSET endpoint is a 2 from
      # `build_transport`, so an endpoint set to the WRONG URL must be a 2 as
      # well — same operator mistake, same fix. A 1 would also contradict the
      # tool's own advice on the very same line, which tells them to go and fix
      # `SPECGUARD_ENDPOINT`.
      # @intent: { entity: "specguard-ingest exit contract", action: "survive an unreachable endpoint", behavior: "a wrong endpoint URL exits the same way an unset one does", layer: "unit" }
      it "agrees with itself: a wrong endpoint URL exits the same as an unset one" do
        unset = described_class.new(stdout: StringIO.new, stderr: StringIO.new,
                                    env: { "SPECGUARD_API_KEY" => "sgk_abc" }).run([sink(run_payload)])

        StubIngestEndpoint.run(status: 404, body: '{"message":"not found"}') do |server|
          wrong = described_class.new(stdout: stdout, stderr: stderr,
                                      env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                                .run([sink(run_payload)])

          expect([unset, wrong]).to eq([2, 2])
        end
      end

      # A 500 is not hypothetical here: the formatter's own README lists it
      # among the statuses that write the fallback line, so it is a first-class
      # inhabitant of the files this command is pointed at. Retrying once the
      # platform recovers is the right move, and exit 1 is the signal that says
      # do not — so 2 has to outrank a genuine 400 on the same file.
      # @intent: { entity: "specguard-ingest exit contract", action: "survive an unreachable endpoint", behavior: "a server error outranks a real content refusal on the same file", layer: "unit" }
      it "lets a 5xx outrank a real content refusal on the same file" do
        StubIngestEndpoint.run(responses: [{ status: 400, body: '{"message":"spec 2: outcome is required"}' },
                                           { status: 500, body: '{"message":"upstream boom"}' }]) do |server|
          path = sink(run_payload(ci_run_id: "a"), run_payload(ci_run_id: "b"))
          code = described_class.new(stdout: stdout, stderr: stderr,
                                     env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([path])

          expect(code).to eq(2)
          expect(out).to eq(<<~OUT)
            line 1: refused — HTTP 400 — the endpoint rejected the payload — spec 2: outcome is required
            line 2: not delivered — HTTP 500 — upstream boom
            specguard-ingest: delivered 0 of 2 runs from #{path}; 1 refused; 1 could not be delivered
          OUT
        end
      end
    end

    describe "misuse of the command line" do
      let(:endpoint) { "https://specguard.example.com" }

      # @intent: { entity: "specguard-ingest options", action: "exit misuse", behavior: "running with no file given exits two", layer: "unit" }
      it "exits 2 with no file given" do
        expect(cli.run([])).to eq(2)
        expect(err).to eq("specguard-ingest: error: no file given — #{described_class::BANNER}\n")
      end

      # A typo'd flag is the likeliest route to a false "the endpoint refused
      # your run": uncaught, OptionParser raises and Ruby exits 1.
      # @intent: { entity: "specguard-ingest options", action: "exit misuse", behavior: "an unknown flag exits two rather than letting the Ruby default one stand", layer: "unit" }
      it "exits 2 on an unknown flag rather than letting Ruby's 1 stand" do
        expect(cli.run(["--replaay", "file.jsonl"])).to eq(2)
        expect(err).to eq("specguard-ingest: error: invalid option: --replaay\n")
      end

      # @intent: { entity: "specguard-ingest options", action: "exit misuse", behavior: "two files given exit two rather than guessing which was meant", layer: "unit" }
      it "exits 2 rather than guessing which of two files was meant" do
        expect(cli.run(%w[one.jsonl two.jsonl])).to eq(2)
        expect(err).to include("one file at a time, got 2: one.jsonl, two.jsonl")
      end
    end
  end

  describe "a file with nothing in it to deliver" do
    # `specguard-lint`'s ratified answer to the same shape: the contract has no
    # code for "there was nothing to do", so 0 stands and the warning carries
    # the weight. What must not happen is a silent 0 — "sent nothing" reading
    # as "sent everything".
    # @intent: { entity: "specguard-ingest", action: "handle an empty file", behavior: "a file with nothing to deliver exits zero and says so on stderr rather than reporting a clean run", layer: "unit" }
    it "exits 0 and says so on stderr, rather than reporting a clean run" do
      path = File.join(@dir, "empty.jsonl")
      File.write(path, "")

      expect(cli_for("https://specguard.example.com").run([path])).to eq(0)
      expect(err).to eq("specguard-ingest: warning: #{path} holds no runs to deliver\n")
      expect(out).to be_empty
    end

    # @intent: { entity: "specguard-ingest", action: "handle an empty file", behavior: "the blank lines skipped are counted rather than dropped from the report", layer: "unit" }
    it "counts the blank lines it skipped rather than dropping them from the report" do
      StubIngestEndpoint.run do |server|
        path = File.join(@dir, "gappy.jsonl")
        File.write(path, "#{JSON.generate(run_payload)}\n\n\n#{JSON.generate(run_payload)}\n")
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([path])

        expect(code).to eq(0)
        # Numbered from the FILE, so line 4 in this report is line 4 in an
        # editor — which is the property that makes the report resumable.
        expect(out).to include("line 1: accepted")
        expect(out).to include("line 4: accepted")
        expect(out).to include("delivered 2 of 2 runs from #{path}; 2 blank lines skipped")
      end
    end
  end

  # Criterion 3's second half. Numbering a partly-accepted file is only worth
  # something if acting on the report does not mean re-sending the lines that
  # already landed — and re-sending is not free: a line carrying no `ci_run_id`
  # has no identity for `RunRecorder` to fold onto, so it becomes a second row.
  describe "--from-line, resuming a partly-accepted file" do
    # @intent: { entity: "specguard-ingest --from-line", action: "resume a file", behavior: "the lines before the resume point are skipped and the rest delivered", layer: "unit" }
    it "skips the lines before N and delivers the rest" do
      StubIngestEndpoint.run do |server|
        path = sink(run_payload(ci_run_id: "a"), run_payload(ci_run_id: "b"), run_payload(ci_run_id: "c"))
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                             .run(["--from-line", "2", path])

        expect(code).to eq(0)
        expect(server.requests.map { |request| request.json["ci_run_id"] }).to eq(%w[b c])
      end
    end

    # The whole point of resuming from a report: the numbers have to be the
    # SAME numbers. A renumbered report (which is what `tail -n +2` would give
    # you) makes the second run's "line 2" a different line from the first's.
    # @intent: { entity: "specguard-ingest --from-line", action: "resume a file", behavior: "the file own numbering is kept rather than renumbering from the resume point", layer: "unit" }
    it "keeps the file's own numbering rather than renumbering from the resume point" do
      StubIngestEndpoint.run(body: '{"test_run_id":"tr_7"}') do |server|
        path = sink(run_payload(ci_run_id: "a"), run_payload(ci_run_id: "b"), run_payload(ci_run_id: "c"))
        described_class.new(stdout: stdout, stderr: stderr,
                            env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                       .run(["--from-line", "3", path])

        expect(out).to eq(<<~OUT)
          line 3: accepted — HTTP 202, test_run_id tr_7, ci_run_id c
          specguard-ingest: delivered 1 of 1 run from #{path}; 2 earlier lines skipped by --from-line
        OUT
      end
    end

    # A skip that is not reported is a summary quietly narrowing what it is
    # summarising — and here it would read as "your whole file is delivered".
    # @intent: { entity: "specguard-ingest --from-line", action: "resume a file", behavior: "skipping past everything says so on stderr", layer: "unit" }
    it "says so on stderr when it skipped past everything" do
      StubIngestEndpoint.run do |server|
        path = sink(run_payload, run_payload)
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                             .run(["--from-line", "9", path])

        expect(code).to eq(0)
        expect(err).to eq("specguard-ingest: warning: #{path} holds no runs to deliver " \
                          "(2 earlier lines skipped by --from-line)\n")
        expect(server.requests).to be_empty
      end
    end

    # @intent: { entity: "specguard-ingest --from-line", action: "resume a file", behavior: "the whole file is delivered when the flag is absent", layer: "unit" }
    it "delivers the whole file when the flag is absent" do
      StubIngestEndpoint.run do |server|
        described_class.new(stdout: stdout, stderr: stderr,
                            env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                       .run([sink(run_payload, run_payload)])

        expect(server.requests.length).to eq(2)
      end
    end

    context "when the flag itself is misused" do
      let(:endpoint) { "https://specguard.example.com" }

      # `to_i` would make this 0 and silently deliver the whole file — the one
      # outcome a resume flag exists to prevent — so it is a 2 instead.
      # @intent: { entity: "specguard-ingest --from-line", action: "refuse bad values", behavior: "a non-numeric resume point exits two rather than falling back to the whole file", layer: "unit" }
      it "exits 2 on a non-numeric N rather than falling back to the whole file" do
        expect(cli.run(["--from-line", "twelve", "file.jsonl"])).to eq(2)
        expect(err).to include("invalid argument: --from-line twelve")
      end

      [0, -3].each do |value|
        # @intent: { entity: "specguard-ingest --from-line", action: "refuse bad values", behavior: "each nonsense resume value exits two on its own", layer: "unit" }
        it "exits 2 on --from-line #{value}" do
          expect(cli.run(["--from-line", value.to_s, "file.jsonl"])).to eq(2)
          expect(err).to eq("specguard-ingest: error: --from-line must be 1 or greater, got #{value}\n")
        end
      end
    end
  end

  # `--lines`, the selector `--from-line` could not be. A suffix is the wrong
  # shape for the set a per-line report points at: the sink is append-only and
  # mixes CI failures with ordinary keyless laptop runs, so the wanted lines are
  # a suffix at most once — and a 400 is a *content* verdict, refused every time
  # it is offered, so a 400 at line 3 of a 40-line file is a line no `--from-line`
  # can ever step over.
  describe "--lines, sending an arbitrary set of them" do
    # ⭐ The case the flag exists for, played out in full rather than asserted in
    # the abstract: a file whose line 3 the endpoint will always refuse cannot
    # be delivered to completion by any suffix, and IS delivered to completion —
    # exit 0 — by naming the set around it. Both halves run against a real
    # socket, so "the rest landed" is what arrived, not what was mocked.
    # @intent: { entity: "specguard-ingest --lines", action: "send an arbitrary set", behavior: "a file is delivered around a permanently-refused interior line and still exits zero", layer: "unit" }
    it "delivers a file around a permanently-refused interior line, exiting 0" do
      path = sink(*%w[a b c d e].map { |id| run_payload(ci_run_id: id) })
      refusal = { status: 400, body: '{"message":"spec 1: outcome is required"}' }

      whole = StubIngestEndpoint.run(responses: [{}, {}, refusal, {}, {}]) do |server|
        described_class.new(stdout: stdout, stderr: stderr,
                            env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run([path])
      end

      expect(whole).to eq(1)
      expect(out).to include("line 3: refused")

      StubIngestEndpoint.run do |server|
        code = described_class.new(stdout: StringIO.new, stderr: StringIO.new,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                             .run(["--lines", "1,2,4-5", path])

        expect(code).to eq(0)
        expect(server.requests.map { |request| request.json["ci_run_id"] }).to eq(%w[a b d e])
      end
    end

    # @intent: { entity: "specguard-ingest --lines", action: "send an arbitrary set", behavior: "exactly the numbers and ranges the spec names are sent, in the file own order", layer: "unit" }
    it "sends exactly the numbers and ranges the spec names, in the file's order" do
      StubIngestEndpoint.run do |server|
        path = sink(*%w[a b c d e f].map { |id| run_payload(ci_run_id: id) })
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                             .run(["--lines", "5-6,1", path])

        expect(code).to eq(0)
        expect(server.requests.map { |request| request.json["ci_run_id"] }).to eq(%w[a e f])
      end
    end

    # Criterion 4 under the new selector. The numbers are the file's, and an
    # interior selection is where a renumbering bug would actually show: line 4
    # is the second line delivered and must still report as 4.
    # @intent: { entity: "specguard-ingest --lines", action: "send an arbitrary set", behavior: "an interior set keeps the file own numbering", layer: "unit" }
    it "keeps the file's own numbering for an interior set" do
      StubIngestEndpoint.run(body: '{"test_run_id":"tr_7"}') do |server|
        path = sink(*%w[a b c d e].map { |id| run_payload(ci_run_id: id) })
        described_class.new(stdout: stdout, stderr: stderr,
                            env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                       .run(["--lines", "2,4", path])

        expect(out).to eq(<<~OUT)
          line 2: accepted — HTTP 202, test_run_id tr_7, ci_run_id b
          line 4: accepted — HTTP 202, test_run_id tr_7, ci_run_id d
          specguard-ingest: delivered 2 of 2 runs from #{path}; 3 lines not selected by --lines
        OUT
      end
    end

    # The `Source` struct's own rule: held-back lines are counted rather than
    # dropped, because a summary that quietly narrows what it is summarising is
    # the failure this project keeps finding. The wording has to be accurate
    # too — the lines `--lines` holds back are not "earlier", they are wherever
    # in the file they sit, and three summaries carry the clause.
    # @intent: { entity: "specguard-ingest --lines", action: "send an arbitrary set", behavior: "the held-back lines are counted in the delivery summary", layer: "unit" }
    it "counts the lines it held back, in the delivery summary" do
      StubIngestEndpoint.run do |server|
        path = sink(run_payload, run_payload, run_payload)
        described_class.new(stdout: stdout, stderr: stderr,
                            env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                       .run(["--lines", "2", path])

        expect(out).to include("delivered 1 of 1 run from #{path}; 2 lines not selected by --lines")
        expect(out).not_to include("--from-line")
      end
    end

    # @intent: { entity: "specguard-ingest --lines", action: "send an arbitrary set", behavior: "the single held-back line is counted in the singular", layer: "unit" }
    it "counts the one line it held back in the singular" do
      StubIngestEndpoint.run do |server|
        path = sink(run_payload, run_payload)
        described_class.new(stdout: stdout, stderr: stderr,
                            env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                       .run(["--lines", "1", path])

        expect(out).to include("1 line not selected by --lines")
      end
    end

    # The empty-file detail, which is the summary that matters most here: a
    # spec naming lines the file does not have delivers nothing, and a silent 0
    # would read as "your whole file is delivered".
    # @intent: { entity: "specguard-ingest --lines", action: "send an arbitrary set", behavior: "a spec naming nothing the file has says so on stderr", layer: "unit" }
    it "says on stderr when the spec named nothing the file has" do
      StubIngestEndpoint.run do |server|
        path = sink(run_payload, run_payload)
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                             .run(["--lines", "9-11", path])

        expect(code).to eq(0)
        expect(err).to eq("specguard-ingest: warning: #{path} holds no runs to deliver " \
                          "(2 lines not selected by --lines)\n")
        expect(server.requests).to be_empty
      end
    end

    # `--lines` sits in the same branch position the suffix test held, so the
    # blank counting and the file's numbering are inherited rather than
    # reimplemented: a blank line the spec names is still a blank line.
    # @intent: { entity: "specguard-ingest --lines", action: "send an arbitrary set", behavior: "the blank-line counting is inherited rather than re-decided", layer: "unit" }
    it "inherits the blank-line counting rather than re-deciding it" do
      StubIngestEndpoint.run do |server|
        path = File.join(@dir, "gappy.jsonl")
        File.write(path, "#{JSON.generate(run_payload)}\n\n#{JSON.generate(run_payload)}\n")
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                             .run(["--lines", "2-3", path])

        expect(code).to eq(0)
        expect(out).to include("line 3: accepted")
        expect(out).to include("delivered 1 of 1 run from #{path}; 1 blank line skipped; " \
                               "1 line not selected by --lines")
      end
    end

    # @intent: { entity: "specguard-ingest --lines", action: "send an arbitrary set", behavior: "the whole file is delivered when the flag is absent", layer: "unit" }
    it "delivers the whole file when the flag is absent" do
      StubIngestEndpoint.run do |server|
        described_class.new(stdout: stdout, stderr: stderr,
                            env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                       .run([sink(run_payload, run_payload)])

        expect(server.requests.length).to eq(2)
        expect(out).not_to include("not selected")
      end
    end

    # ⭐ Criterion 2. `--list` is the documented route to the numbers, so a
    # preview that disagreed with the delivery would be worse than no preview:
    # it would hand the user a set they did not send. Asserted as the two
    # actually agreeing on the same file and the same spec, not as two
    # independent expectations that happen to match.
    # @intent: { entity: "specguard-ingest --lines", action: "preview under list", behavior: "the list preview shows exactly the lines the same spec delivers", layer: "unit" }
    it "previews under --list exactly the lines the same spec delivers" do
      path = sink(*%w[a b c d e f].map { |id| run_payload(ci_run_id: id) })
      spec = "2,4-5"

      described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--list", "--lines", spec, path])
      listed = out.scan(/^line (\d+):/).flatten

      StubIngestEndpoint.run do |server|
        delivered_stdout = StringIO.new
        described_class.new(stdout: delivered_stdout, stderr: StringIO.new,
                            env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                       .run(["--lines", spec, path])

        expect(listed).to eq(%w[2 4 5])
        expect(delivered_stdout.string.scan(/^line (\d+):/).flatten).to eq(listed)
        expect(server.requests.map { |request| request.json["ci_run_id"] }).to eq(%w[b d e])
      end
    end

    # Listing needs no credentials, and that must hold for the new selector too
    # — the file most worth previewing a set out of is the keyless one.
    # @intent: { entity: "specguard-ingest --lines", action: "preview under list", behavior: "a set lists with neither endpoint nor key set and delivers nothing", layer: "unit" }
    it "lists a set with neither endpoint nor API key set, and delivers nothing" do
      path = sink(run_payload(ci_run_id: "a"), run_payload(ci_run_id: "b"), run_payload(ci_run_id: "c"))
      code = described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--list", "--lines", "3", path])

      expect(code).to eq(0)
      expect(out).to include("line 3: branch main")
      expect(out).not_to include("line 1:")
      expect(out).to include("listed 1 line from #{path}; 2 lines not selected by --lines; nothing was delivered")
      expect(err).to be_empty
    end

    # @intent: { entity: "specguard-ingest --lines", action: "preview under list", behavior: "a listed spec naming nothing the file has says so on stderr", layer: "unit" }
    it "says on stderr when a listed spec named nothing the file has" do
      path = sink(run_payload)
      code = described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--list", "--lines", "4", path])

      expect(code).to eq(0)
      expect(err).to eq("specguard-ingest: warning: #{path} holds no runs to list (1 line not selected by --lines)\n")
      expect(out).to be_empty
    end

    # ⭐ The composition rule, decided rather than emergent. `--from-line` and
    # `--lines` answer the same question, and intersecting them would drop a
    # number the user typed without a word — `--from-line 5 --lines 3,7` would
    # deliver only 7, and the 3 would vanish. Quietly narrowing what it was
    # asked for is the failure the whole file is arranged against, so the pair
    # is refused. It is a 2 for the same reason every other misuse is: nothing
    # was offered to an endpoint, so no verdict about anyone's run exists.
    describe "given together with --from-line" do
      let(:endpoint) { "https://specguard.example.com" }

      # @intent: { entity: "specguard-ingest flag combination", action: "refuse conflicting selectors", behavior: "the resume flag with the lines flag exits two rather than silently intersecting", layer: "unit" }
      it "exits 2 rather than silently intersecting the two" do
        path = sink(run_payload, run_payload, run_payload)

        expect(cli.run(["--from-line", "2", "--lines", "3", path])).to eq(2)
        expect(err).to eq("specguard-ingest: error: --from-line and --lines both choose which lines to send; " \
                          "give one or the other\n")
        expect(out).to be_empty
      end

      # @intent: { entity: "specguard-ingest flag combination", action: "refuse conflicting selectors", behavior: "the pair is refused whichever order it is written in", layer: "unit" }
      it "refuses the pair whichever order they are written in" do
        path = sink(run_payload)
        second = described_class.new(stdout: StringIO.new, stderr: StringIO.new, env: env)

        expect(cli.run(["--lines", "1", "--from-line", "1", path])).to eq(2)
        expect(second.run(["--from-line", "1", "--lines", "1", path])).to eq(2)
      end

      # The refusal is about the pair, not about either flag — each still works
      # on its own, and `--list` is not a way around it.
      # @intent: { entity: "specguard-ingest flag combination", action: "refuse conflicting selectors", behavior: "either flag alone is accepted and the pair is refused under list too", layer: "unit" }
      it "still accepts either one alone, and refuses the pair under --list too" do
        path = sink(run_payload, run_payload)
        alone = described_class.new(stdout: StringIO.new, stderr: StringIO.new, env: {})
        pair = described_class.new(stdout: StringIO.new, stderr: StringIO.new, env: {})

        expect(alone.run(["--list", "--lines", "1", path])).to eq(0)
        expect(pair.run(["--list", "--lines", "1", "--from-line", "1", path])).to eq(2)
      end
    end

    # The other half of the composition question, pinned so that last-wins is a
    # decision rather than an OptionParser default nobody looked at. The pair
    # above is refused because two *different* flags answering one question
    # would yield a set smaller than either names; a repeat is one flag
    # answering twice, where the later value *replaces* the earlier rather than
    # intersecting it. Nothing is quietly narrowed — the delivered set is
    # exactly the last one typed — and it is what lets a wrapper script's baked
    # in selector be corrected by appending a new one.
    describe "given more than once" do
      # @intent: { entity: "specguard-ingest flag combination", action: "apply last-wins", behavior: "repeated specs deliver the last set typed, neither the intersection nor the union", layer: "unit" }
      it "delivers the last set typed, not the intersection and not the union" do
        path = sink(run_payload(ci_run_id: "a"), run_payload(ci_run_id: "b"),
                    run_payload(ci_run_id: "c"), run_payload(ci_run_id: "d"))

        expect(cli.run(["--list", "--lines", "1,2", "--lines", "4", path])).to eq(0)
        expect(out.scan(/^line (\d+):/).flatten).to eq(%w[4])
      end

      # The repeat overrides rather than accumulating, so a later spec widens
      # just as readily as it narrows — the earlier one is gone either way.
      # @intent: { entity: "specguard-ingest flag combination", action: "apply last-wins", behavior: "a later spec widens what an earlier one narrowed", layer: "unit" }
      it "lets a later spec widen what an earlier one narrowed" do
        path = sink(run_payload, run_payload, run_payload)

        expect(cli.run(["--list", "--lines", "2", "--lines", "1-3", path])).to eq(0)
        expect(out.scan(/^line (\d+):/).flatten).to eq(%w[1 2 3])
      end

      # Same convention on the flag that already had it before this one
      # existed, asserted here so the two selectors are pinned as a pair.
      # @intent: { entity: "specguard-ingest flag combination", action: "apply last-wins", behavior: "the same last-wins rule applies to a repeated resume flag", layer: "unit" }
      it "applies the same last-wins rule to a repeated --from-line" do
        path = sink(run_payload, run_payload, run_payload)

        expect(cli.run(["--list", "--from-line", "2", "--from-line", "3", path])).to eq(0)
        expect(out.scan(/^line (\d+):/).flatten).to eq(%w[3])
      end

      # A repeat is still not a way around the cross-flag refusal: the last
      # `--lines` is a `--lines`, and `--from-line` is still there beside it.
      # @intent: { entity: "specguard-ingest flag combination", action: "apply last-wins", behavior: "the pair is still refused when the repeat is the one that lands", layer: "unit" }
      it "still refuses the pair when the repeat is the one that lands" do
        path = sink(run_payload, run_payload)

        expect(cli.run(["--from-line", "1", "--lines", "1", "--lines", "2", path])).to eq(2)
      end
    end

    # The `--from-line twelve` rationale, applied to a grammar with more ways to
    # be wrong: a spec that half-parsed would deliver the wrong runs, which is
    # worse than not running. Every one of these is a 2 that names what was
    # wrong, and none of them falls back to the whole file.
    context "when the spec itself is misused" do
      let(:endpoint) { "https://specguard.example.com" }

      {
        "0" => 'specguard-ingest: error: --lines: line numbers start at 1, got "0"',
        "3,0" => 'specguard-ingest: error: --lines: line numbers start at 1, got "0"',
        "5-2" => 'specguard-ingest: error: --lines: "5-2" ends before it starts',
        "abc" => 'specguard-ingest: error: --lines: "abc" is not a line number or a N-M range',
        "3,abc" => 'specguard-ingest: error: --lines: "abc" is not a line number or a N-M range',
        "12-" => 'specguard-ingest: error: --lines: "12-" is not a line number or a N-M range',
        "1-2-3" => 'specguard-ingest: error: --lines: "1-2-3" is not a line number or a N-M range',
        "3.5" => 'specguard-ingest: error: --lines: "3.5" is not a line number or a N-M range',
        "" => 'specguard-ingest: error: --lines needs at least one line number, got ""',
        "3,,5" => 'specguard-ingest: error: --lines has an empty entry in "3,,5"',
        "3," => 'specguard-ingest: error: --lines has an empty entry in "3,"'
      }.each do |spec, message|
        # @intent: { entity: "specguard-ingest --lines", action: "refuse unparseable specs", behavior: "an unparseable line spec exits two rather than delivering anything", layer: "unit" }
        it "exits 2 on --lines #{spec.inspect} rather than delivering anything" do
          expect(cli.run(["--lines", spec, "file.jsonl"])).to eq(2)
          expect(err).to eq("#{message}\n")
          expect(out).to be_empty
        end
      end

      # The failure mode that matters most: a rejected spec must never become
      # "no selector", which is the whole file. Asserted against a real socket
      # so "nothing was sent" is what arrived.
      # @intent: { entity: "specguard-ingest --lines", action: "refuse unparseable specs", behavior: "nothing at all is sent for a spec that could not be parsed", layer: "unit" }
      it "sends nothing at all for a spec it could not parse" do
        StubIngestEndpoint.run do |server|
          code = described_class.new(stdout: stdout, stderr: stderr,
                                     env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                               .run(["--lines", "abc", sink(run_payload, run_payload)])

          expect(code).to eq(2)
          expect(server.requests).to be_empty
        end
      end

      # A spec is rejected before the file is even looked at, so the message is
      # about the flag rather than about a path that was never the point.
      # @intent: { entity: "specguard-ingest --lines", action: "refuse unparseable specs", behavior: "the bad spec is named rather than a file that was never opened", layer: "unit" }
      it "names the bad spec rather than a file it never opened" do
        expect(cli.run(["--lines", "abc", File.join(@dir, "gone.jsonl")])).to eq(2)
        expect(err).not_to include("no such file")
      end

      # Whitespace around an entry is a typing convenience, not a grammar: it is
      # stripped between entries and rejected inside one, so `3, 7` works and
      # `5 - 7` is the typo it looks like rather than a silently repaired range.
      # @intent: { entity: "specguard-ingest --lines", action: "refuse unparseable specs", behavior: "whitespace between entries is allowed and whitespace inside one is refused", layer: "unit" }
      it "allows whitespace between entries and refuses it inside one" do
        path = sink(run_payload(ci_run_id: "a"), run_payload(ci_run_id: "b"), run_payload(ci_run_id: "c"))
        spaced = described_class.new(stdout: stdout, stderr: stderr, env: {})

        expect(spaced.run(["--list", "--lines", " 1 , 3 ", path])).to eq(0)
        expect(out.scan(/^line (\d+):/).flatten).to eq(%w[1 3])
        expect(cli.run(["--lines", "1 - 3", "file.jsonl"])).to eq(2)
      end
    end
  end

  # The command's own README paragraph says a laptop's file is a file of
  # ordinary local runs, that all of them will be sent, and to "check the file
  # before you replay one you did not write" — and until `--list` there was no
  # way to check it. `--from-line` does not close the loop: the report that
  # names the line number runs *after* every line has been delivered, so the
  # documented route to the number requires first committing the hazard.
  #
  # Reading the file by hand is not the alternative either. One line is one
  # whole run, and at 20,000 examples that is megabytes of JSON on a single
  # physical line.
  describe "--list, previewing a file before sending it" do
    # Criterion 1, and the half of it that matters: "delivers nothing" asserted
    # against a real socket that recorded everything that arrived, not against
    # a mock expectation on a method this test chose to watch. The endpoint is
    # configured and reachable here on purpose — nothing was sent because
    # listing does not send, not because sending was impossible.
    # @intent: { entity: "specguard-ingest --list", action: "preview a file", behavior: "listing prints a row per line and sends nothing even with a live endpoint configured", layer: "unit" }
    it "prints a row per line and sends nothing, even with a live endpoint configured" do
      StubIngestEndpoint.run do |server|
        path = sink(run_payload(ci_run_id: "17442"), run_payload(ci_run_id: nil, commit_sha: "abc123"))
        code = described_class.new(stdout: stdout, stderr: stderr,
                                   env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                             .run(["--list", path])

        expect(code).to eq(0)
        expect(server.requests).to be_empty
        expect(out).to eq(<<~OUT)
          line 1: branch main, commit_sha 0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2, ci_run_id 17442, 1 example, 1.25s
          line 2: branch main, commit_sha abc123, no ci_run_id, 1 example, 1.25s
          specguard-ingest: listed 2 lines from #{path}; nothing was delivered
        OUT
      end
    end

    # ⭐ Criterion 2, and the load-bearing one. `#run` asks `build_transport`
    # before it opens the file, deliberately — but the file that most needs
    # checking is the one the formatter wrote BECAUSE no API key was set
    # (`return append(data) if blank?(configuration.api_key)`). A listing that
    # demanded credentials would be unavailable in exactly the situation that
    # produces the hazard it exists to prevent, so `--list` short-circuits
    # ahead of `build_transport` and this example is what holds it there.
    # @intent: { entity: "specguard-ingest --list", action: "run unconfigured", behavior: "listing works with neither endpoint nor api key set", layer: "unit" }
    it "lists with neither SPECGUARD_ENDPOINT nor SPECGUARD_API_KEY set" do
      path = sink(run_payload(ci_run_id: nil))
      code = described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--list", path])

      expect(code).to eq(0)
      expect(out).to include("line 1: branch main")
      expect(err).to be_empty
    end

    # The same invocation without `--list` is the control: it exits 2 naming
    # the endpoint. The pair shows the credential check is genuinely skipped
    # for listing rather than happening to pass.
    # @intent: { entity: "specguard-ingest --list", action: "run unconfigured", behavior: "listing is the only mode that runs unconfigured, delivering the same file exits two", layer: "unit" }
    it "is the only mode that runs unconfigured — delivering the same file exits 2" do
      path = sink(run_payload)
      listed = described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--list", path])
      delivered = described_class.new(stdout: StringIO.new, stderr: StringIO.new, env: {}).run([path])

      expect([listed, delivered]).to eq([0, 2])
    end

    # The decision-relevant field, per the README: a line WITHOUT a `ci_run_id`
    # has nothing for `RunRecorder` to fold onto and becomes a second run, and
    # a keyless local file is made entirely of those. Its absence is stated,
    # never left as a gap in the row for the reader to notice.
    # @intent: { entity: "specguard-ingest --list", action: "render rows", behavior: "a row names the absence of a ci run id rather than leaving a gap", layer: "unit" }
    it "names the absence of a ci_run_id rather than leaving a gap" do
      described_class.new(stdout: stdout, stderr: stderr, env: {})
                     .run(["--list", sink(run_payload(ci_run_id: nil))])

      expect(out).to include("no ci_run_id")
    end

    # @intent: { entity: "specguard-ingest --list", action: "render rows", behavior: "the row counts the examples the run carries", layer: "unit" }
    it "counts the examples the run carries" do
      payload = run_payload
      payload["specs"] = Array.new(3) { payload["specs"].first }
      described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--list", sink(payload)])

      expect(out).to include("3 examples, 1.25s")
    end

    # `#scalar`, for the same reason `#deliver_line` uses it on `ci_run_id`:
    # the envelope is free-form, and rendering `{"a"=>1}` as a branch would be
    # this tool inventing structure the line does not have.
    # @intent: { entity: "specguard-ingest --list", action: "render rows", behavior: "a non-scalar field is reported absent rather than rendering its structure", layer: "unit" }
    it "reports a non-scalar field as absent rather than rendering its structure" do
      described_class.new(stdout: stdout, stderr: stderr, env: {})
                     .run(["--list", sink({ "branch" => { "a" => 1 }, "ci_run_id" => %w[x] })])

      expect(out).to include("line 1: no branch, no commit_sha, no ci_run_id, no specs, no duration_seconds")
      expect(out).not_to include("=>")
    end

    # Criterion 3. Listing exists to be read before `--from-line`, so the
    # numbers it prints must be the numbers that flag takes — the file's own.
    # @intent: { entity: "specguard-ingest --list", action: "compose selectors", behavior: "listing composes with the resume flag keeping the file own numbering", layer: "unit" }
    it "composes with --from-line, keeping the file's own numbering" do
      path = sink(run_payload(ci_run_id: "a"), run_payload(ci_run_id: "b"), run_payload(ci_run_id: "c"))
      code = described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--list", "--from-line", "3", path])

      expect(code).to eq(0)
      expect(out).to include("line 3: branch main")
      expect(out).not_to include("line 1:")
      expect(out).to include("listed 1 line from #{path}; 2 earlier lines skipped by --from-line; " \
                             "nothing was delivered")
    end

    # @intent: { entity: "specguard-ingest --list", action: "compose selectors", behavior: "the listing counts the blank lines it skipped rather than dropping them", layer: "unit" }
    it "counts the blank lines it skipped rather than dropping them from the listing" do
      path = File.join(@dir, "gappy.jsonl")
      File.write(path, "#{JSON.generate(run_payload)}\n\n#{JSON.generate(run_payload)}\n")
      described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--list", path])

      expect(out).to include("line 1: branch main")
      expect(out).to include("line 3: branch main")
      expect(out).to include("listed 2 lines from #{path}; 1 blank line skipped; nothing was delivered")
    end

    # Criterion 4, reusing `#read_source`'s existing discipline rather than
    # re-implementing it: a line that is not valid UTF-8 is kept rather than
    # dropped, so `#parse_payload` can name it — and the rest of the file is
    # still listed.
    # @intent: { entity: "specguard-ingest --list", action: "compose selectors", behavior: "an unparseable line is listed as unparseable and the listing keeps going", layer: "unit" }
    it "lists an unparseable line as unparseable and keeps going" do
      path = File.join(@dir, "binary.jsonl")
      File.open(path, "wb") do |file|
        file.write("#{JSON.generate(run_payload)}\n")
        file.write([0xC3, 0x28, 0xFF, 0x0A].pack("C*"))
        file.write("{truncated\n")
        file.write("#{JSON.generate(run_payload(ci_run_id: 'last'))}\n")
      end

      code = described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--list", path])

      expect(code).to eq(0)
      expect(out).to include("line 2: unparseable — the line is not valid UTF-8, so it cannot be a run")
      expect(out).to include("line 3: unparseable — could not parse the line as JSON:")
      expect(out).to include("line 4: branch main, commit_sha 0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2, " \
                             "ci_run_id last")
      expect(err).to be_empty
    end

    # ⭐ Criterion 5. Listing delivers nothing, so it can never carry a verdict
    # about anybody's run — `EXIT_REFUSED` stays produced in exactly one place,
    # `#exit_code`, which listing does not reach. Both files below are ones the
    # DELIVERY path exits non-zero on: the first would be a 1 (the endpoint
    # refuses it), the second a 2 (a line will not parse). Listed, both are 0.
    # @intent: { entity: "specguard-ingest --list", action: "keep the codes apart", behavior: "listing never reaches exit one, a file delivery would refuse still lists as zero", layer: "unit" }
    it "never reaches exit 1 — a file that delivery would refuse still lists as 0" do
      StubIngestEndpoint.run(status: 400, body: '{"message":"no"}') do |server|
        path = sink(run_payload)
        configured = env.merge("SPECGUARD_ENDPOINT" => server.endpoint)

        listed = described_class.new(stdout: stdout, stderr: stderr, env: configured).run(["--list", path])
        delivered = described_class.new(stdout: StringIO.new, stderr: StringIO.new, env: configured).run([path])

        expect([listed, delivered]).to eq([0, 1])
      end
    end

    # @intent: { entity: "specguard-ingest --list", action: "keep the codes apart", behavior: "a file whose lines delivery would exit two for still lists as zero", layer: "unit" }
    it "exits 0 on a file whose lines delivery would exit 2 for" do
      expect(described_class.new(stdout: stdout, stderr: stderr, env: {})
                            .run(["--list", sink("{not json", "null")])).to eq(0)
      expect(out).to include("line 1: unparseable")
      expect(out).to include("line 2: unparseable — the line is NilClass JSON, and a run is an object")
    end

    # @intent: { entity: "specguard-ingest --list", action: "keep the codes apart", behavior: "a file that does not exist exits two under list without asking for credentials first", layer: "unit" }
    it "exits 2 on a file that does not exist, without asking for credentials first" do
      code = described_class.new(stdout: stdout, stderr: stderr, env: {})
                            .run(["--list", File.join(@dir, "gone.jsonl")])

      expect(code).to eq(2)
      expect(err).to eq("specguard-ingest: error: no such file: #{File.join(@dir, 'gone.jsonl')}\n")
      expect(out).to be_empty
    end

    # @intent: { entity: "specguard-ingest --list", action: "keep the codes apart", behavior: "a directory handed to list exits two", layer: "unit" }
    it "exits 2 on a directory" do
      expect(described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--list", @dir])).to eq(2)
      expect(err).to eq("specguard-ingest: error: not a file: #{@dir}\n")
    end

    # `--liist` is close enough to `--list` that OptionParser appends its own
    # "Did you mean?" line, which is welcome and is why this asserts the retyped
    # prefix rather than the whole of stderr. The property under test is the
    # code: a typo'd flag must not borrow the 1 that means "the endpoint refused
    # your run", and in listing mode nothing was ever offered to an endpoint.
    # @intent: { entity: "specguard-ingest --list", action: "keep the codes apart", behavior: "a bad flag beside list exits two", layer: "unit" }
    it "exits 2 on a bad flag alongside --list" do
      code = described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--list", "--liist", "f.jsonl"])

      expect(code).to eq(2)
      expect(err).to start_with("specguard-ingest: error: invalid option: --liist\n")
    end

    # @intent: { entity: "specguard-ingest --list", action: "keep the codes apart", behavior: "list with no file given exits two", layer: "unit" }
    it "exits 2 on --list with no file given" do
      expect(described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--list"])).to eq(2)
      expect(err).to eq("specguard-ingest: error: no file given — #{described_class::BANNER}\n")
    end

    # ⭐ The exit-code table is the other half of what `--help` promises, and it
    # is the half that went stale: it enumerates causes of a `2` — "no endpoint
    # or API key", "an unparseable line" — that listing is defined not to have,
    # and that the examples above prove it does not. Left unqualified, one
    # --help screen told a reader both that listing needs no credentials and
    # that missing credentials are a 2. Asserting the carve-out ALONGSIDE the
    # behaviour it describes is what stops the row drifting out of step again:
    # this fails if the table stops saying it, and equally if listing ever
    # starts exiting 2 for either cause.
    # @intent: { entity: "specguard-ingest --list", action: "keep the codes apart", behavior: "the help documents exactly the misuse codes listing can reach, and reaches only those", layer: "unit" }
    it "documents which 2s listing can reach, and reaches only those" do
      cli.run(["--help"])
      table = out.gsub(/\s+/, " ")

      expect(table).to include("With --list the only reachable 2s are a bad flag and a file that cannot be read")
      expect(table).to include("listing needs no credentials")
      expect(table).to include("an unparseable line becomes a row in the listing rather than an exit code")

      unconfigured = described_class.new(stdout: StringIO.new, stderr: StringIO.new, env: {})
                                    .run(["--list", sink(run_payload)])
      unparseable = described_class.new(stdout: StringIO.new, stderr: StringIO.new, env: {})
                                   .run(["--list", sink("{not json")])

      expect([unconfigured, unparseable]).to eq([0, 0])
    end

    # A listing that printed nothing and exited 0 would read as "your file is
    # clear" — the same silent-success failure the empty delivery guards.
    # @intent: { entity: "specguard-ingest --list", action: "keep the codes apart", behavior: "an empty listing says so on stderr rather than printing nothing", layer: "unit" }
    it "says so on stderr when there was nothing to list, rather than printing nothing" do
      path = File.join(@dir, "empty.jsonl")
      File.write(path, "")

      expect(described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--list", path])).to eq(0)
      expect(err).to eq("specguard-ingest: warning: #{path} holds no runs to list\n")
      expect(out).to be_empty
    end
  end

  # ⭐ SPGD-669. A 400 is the only PERMANENT verdict this command has — a refused
  # line is refused every time it is offered — so the only way to land the run is
  # to learn which specs the platform objected to. It names every one of them,
  # one error per bad spec; `Transport::Result#reason` renders three of them,
  # truncated to 300 characters, because it is built for the one stderr line an
  # in-run CI warning is allowed. `--json` is the second channel that cap's own
  # grounds hand over.
  #
  # Every example here is about the flag being a RENDERER: the same lines, the
  # same statuses, the same counts and the same exit code, written out twice.
  describe "--json, the second renderer" do
    # 500 offending specs — the shape a systemic client bug takes on a large
    # suite, and `Ingest::Payload` appends one error per bad spec. Kept short
    # enough that three of them join to under `MAX_REASONS_LENGTH`, so the text
    # line below is the cap's `take(3)` and nothing else.
    def refusal_details(count = 500)
      Array.new(count) { |i| "specs[#{i}] spec/u_spec.rb:#{i}: duration must be non-negative" }
    end

    def refusal_body(details)
      JSON.generate("message" => details.first, "details" => details)
    end

    def document = JSON.parse(out)

    def deliver(argv, responses: nil, status: 202, body: '{"test_run_id":"tr_7"}', stdout: nil, stderr: nil)
      StubIngestEndpoint.run(status: status, body: body, responses: responses) do |server|
        described_class.new(stdout: stdout || self.stdout, stderr: stderr || self.stderr,
                            env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run(argv)
      end
    end

    # ⭐ Criterion 1, both halves in one example so they cannot drift apart: the
    # document carries ALL 500 of the platform's reasons, verbatim and in order,
    # and the same run without the flag prints the same capped line it printed
    # before this renderer existed — three reasons and a count, on one line.
    # @intent: { entity: "specguard-ingest --json", action: "render reasons", behavior: "the document lists every reason the platform sent while the text line shows three and a count", layer: "unit" }
    it "lists every reason the platform sent, while the text line still shows three and a count" do
      details = refusal_details
      path = sink(run_payload)

      code = deliver(["--json", path], status: 400, body: refusal_body(details))
      entry = document["lines"].first

      expect(code).to eq(1)
      expect(entry["reasons"].length).to eq(500)
      expect(entry["reasons"]).to eq(details)
      expect(entry["code"]).to eq(400)
      expect(entry["status"]).to eq("refused")

      plain = StringIO.new
      expect(deliver([path], status: 400, body: refusal_body(details), stdout: plain)).to eq(1)
      expect(plain.string).to eq(<<~OUT)
        line 1: refused — HTTP 400 — the endpoint rejected the payload — #{details.take(3).join('; ')} and 497 more
        specguard-ingest: delivered 0 of 1 run from #{path}; 1 refused
      OUT
    end

    # The cap is a cap on a LINE. Asserted as the two channels differing on the
    # same refusal, so a change that started truncating the document — or one
    # that lifted the cap on the warning the formatter still has to fit on one
    # stderr line — fails here.
    # @intent: { entity: "specguard-ingest --json", action: "render reasons", behavior: "the same refusal renders at two different lengths between text and document on purpose", layer: "unit" }
    it "renders the same refusal at two different lengths, on purpose" do
      details = refusal_details(40)
      path = sink(run_payload)

      deliver(["--json", path], status: 400, body: refusal_body(details))
      plain = StringIO.new
      deliver([path], status: 400, body: refusal_body(details), stdout: plain)

      expect(document["lines"].first["reasons"].length).to eq(40)
      expect(plain.string).to include("and 37 more")
      expect(plain.string).not_to include(details.last)
    end

    # ⭐ Criterion 3. The flag touches `#report` and `#list`, both of which sit on
    # the path to the return value, so parity is asserted at every status rather
    # than argued for — including the case the contract is really about, where a
    # refusal and an undelivered line share one file and 2 has to win.
    #
    # A fresh server per run, deliberately: `StubIngestEndpoint`'s `responses`
    # list is indexed by request across the whole server, so replaying one argv
    # twice through one server would answer the second run from the wrong end of
    # the list.
    {
      "every line accepted" => [0, [{}, {}]],
      "a line the endpoint refused" => [1, [{}, { status: 400, body: '{"message":"spec 1: outcome is required"}' }]],
      "a line that never arrived" => [2, [{}, { status: 500, body: '{"message":"upstream boom"}' }]],
      "a refusal and an undelivered line together" =>
        [2, [{ status: 400, body: '{"message":"no"}' }, { status: 500, body: '{"message":"boom"}' }]]
    }.each do |name, (expected, responses)|
      # @intent: { entity: "specguard-ingest --json", action: "keep the exit codes", behavior: "each exit-code class comes out identically with and without the json flag", layer: "unit" }
      it "exits #{expected} with and without the flag on #{name}" do
        path = sink(run_payload(ci_run_id: "a"), run_payload(ci_run_id: "b"))

        plain = deliver([path], responses: responses, stdout: StringIO.new, stderr: StringIO.new)
        json = deliver(["--json", path], responses: responses, stdout: StringIO.new, stderr: StringIO.new)

        expect(json).to eq(plain)
        expect(json).to eq(expected)
      end
    end

    # The fourth status has no HTTP response behind it, so it gets its own
    # example rather than a `responses` entry — and it is the one that proves the
    # flag does not rescue anything the default path does not.
    # @intent: { entity: "specguard-ingest --json", action: "keep the exit codes", behavior: "a line that is not a run at all exits two either way", layer: "unit" }
    it "exits 2 either way on a line that is not a run at all" do
      path = sink(run_payload, "{not json")

      expect(deliver([path], stdout: StringIO.new)).to eq(2)
      expect(deliver(["--json", path], stdout: StringIO.new)).to eq(2)
    end

    # Criterion 7, on the side a consumer meets first: an accepted line has
    # nothing to say and says it as `[]`.
    # @intent: { entity: "specguard-ingest --json", action: "render rows", behavior: "an accepted line reports its code with an empty reasons list", layer: "unit" }
    it "reports an accepted line with its code and an empty reasons list" do
      expect(deliver(["--json", sink(run_payload)])).to eq(0)

      expect(document["lines"]).to eq(
        [{ "number" => 1, "status" => "accepted", "code" => 202, "reasons" => [],
           "test_run_id" => "tr_7", "ci_run_id" => "17442" }]
      )
    end

    # Criterion 7's other half. `Transport#refusal_reasons` degrades to nil for
    # every body it cannot read — an empty one, HTML from a proxy, a JSON scalar
    # — and `null` there would hand every consumer a type check.
    # @intent: { entity: "specguard-ingest --json", action: "render rows", behavior: "a refusal whose body said nothing readable reports an empty list, never null", layer: "unit" }
    it "reports a refusal whose body said nothing readable as an empty list, never null" do
      expect(deliver(["--json", sink(run_payload)], status: 400, body: "<html>no</html>")).to eq(1)
      entry = document["lines"].first

      expect(entry["status"]).to eq("refused")
      expect(entry["code"]).to eq(400)
      expect(entry["reasons"]).to eq([])
    end

    # ⭐ Criterion 8. A 502 is a proxy answering for a platform that never saw the
    # payload, and its body is HTML rather than the shape this gem reads. It is
    # `undelivered` — not `refused`, because nothing was judged, and not
    # `:failed`, because a response genuinely arrived — and the document is still
    # a document.
    # @intent: { entity: "specguard-ingest --json", action: "render rows", behavior: "a gateway error answering in HTML renders as undelivered with a valid document and no crash", layer: "unit" }
    it "renders a 502 answering with HTML as undelivered, with a valid document and no crash" do
      code = deliver(["--json", sink(run_payload)], status: 502,
                                                    body: "<html><body>502 Bad Gateway</body></html>")
      entry = document["lines"].first

      expect(code).to eq(2)
      expect(entry["status"]).to eq("undelivered")
      expect(entry["code"]).to eq(502)
      expect(entry["reasons"]).to eq([])
      expect(document["summary"]["undelivered"]).to eq(1)
      expect(err).to be_empty
    end

    # A delivery that never got an answer has no code, and the exception's
    # rendering is the whole of what there is to say — so it lands in `reasons`
    # rather than being dropped for want of a field of its own. `code: null` next
    # to a non-empty `reasons` is what tells a consumer this from a refusal.
    # @intent: { entity: "specguard-ingest --json", action: "render rows", behavior: "a socket failure reports no code with the error in the reasons", layer: "unit" }
    it "reports a socket failure with no code and the error in reasons" do
      code = described_class.new(stdout: stdout, stderr: stderr,
                                env: env.merge("SPECGUARD_ENDPOINT" => dead_endpoint,
                                               "SPECGUARD_TIMEOUT" => "2")).run(["--json", sink(run_payload)])
      entry = document["lines"].first

      expect(code).to eq(2)
      expect(entry["status"]).to eq("undelivered")
      expect(entry["code"]).to be_nil
      expect(entry["reasons"].first).to start_with("Errno::ECONNREFUSED")
    end

    # A line that was never a run has no code and no ids either, and its parse
    # problem is the only thing there is to say about it — collapsed into the same
    # list, exactly as `JSONReporter#errors` collapses lint's `problem` into
    # `errors`, so one code path reads every reason a line did not land.
    # @intent: { entity: "specguard-ingest --json", action: "render rows", behavior: "an unparseable line problem collapses into the same reasons list", layer: "unit" }
    it "collapses an unparseable line's problem into the same reasons list" do
      expect(deliver(["--json", sink(run_payload, "{not json")])).to eq(2)
      entry = document["lines"].last

      expect(entry["status"]).to eq("unparseable")
      expect(entry["code"]).to be_nil
      expect(entry["reasons"].length).to eq(1)
      expect(entry["reasons"].first).to start_with("could not parse the line as JSON:")
    end

    # @intent: { entity: "specguard-ingest --json", action: "render rows", behavior: "every reasons list is a list of strings whatever the line did", layer: "unit" }
    it "reports every reasons list as a list of strings, whatever the line did" do
      responses = [{}, { status: 400, body: refusal_body(refusal_details(4)) }, { status: 500, body: "" }]
      expect(deliver(["--json", sink(run_payload, run_payload, run_payload, "{not json")],
                     responses: responses)).to eq(2)

      expect(document["lines"].map { |entry| entry["reasons"] }).to all(be_an(Array).and(all(be_a(String))))
      expect(document["lines"].map { |entry| entry["status"] })
        .to eq(%w[accepted refused undelivered unparseable])
    end

    # Whitespace inside a reason is left alone here, deliberately: collapsing it
    # is `Transport::Result#one_line`'s job because a CI log has one line to
    # spend, and a JSON string has no such budget. What must hold either way is
    # that the document parses.
    # @intent: { entity: "specguard-ingest --json", action: "render rows", behavior: "a multi-line reason stays intact and the document still parses", layer: "unit" }
    it "keeps a multi-line reason intact and still emits parseable JSON" do
      body = JSON.generate("details" => ["specs[0] spec/u_spec.rb:1:\n  duration must be non-negative"])

      expect(deliver(["--json", sink(run_payload)], status: 400, body: body)).to eq(1)
      expect { document }.not_to raise_error
      expect(document["lines"].first["reasons"].first).to include("\n")
    end

    # ⭐ Criterion 9. Two renderers of one result list that can disagree about how
    # much of a file was delivered are worse than prose alone: the disagreement is
    # unfalsifiable from outside the process. So the counts are computed once and
    # handed to whichever renderer runs, and this is the example that would fail
    # if either grew its own tally.
    # @intent: { entity: "specguard-ingest --json", action: "stay consistent", behavior: "the document agrees with the text summary about every count on one mixed file", layer: "unit" }
    it "agrees with the text summary about every count, on one mixed file" do
      responses = [{}, { status: 400, body: '{"message":"no"}' }, { status: 500, body: '{"message":"boom"}' }]
      path = sink(run_payload, run_payload, run_payload, "{not json", "", run_payload)

      expect(deliver(["--lines", "1-4", "--json", path], responses: responses)).to eq(2)
      summary = document["summary"]

      plain = StringIO.new
      deliver(["--lines", "1-4", path], responses: responses, stdout: plain)

      expect(plain.string).to include("specguard-ingest: delivered 1 of 4 runs from #{path}; 1 refused; " \
                                      "1 could not be delivered; 1 could not be parsed; " \
                                      "2 lines not selected by --lines")
      expect(summary).to eq(
        "lines" => 4, "attempted" => 3, "accepted" => 1, "refused" => 1, "undelivered" => 1,
        "unparseable" => 1, "blank" => 0, "skipped" => 2, "selector" => "--lines"
      )
    end

    # @intent: { entity: "specguard-ingest --json", action: "stay consistent", behavior: "the summary names the resume flag when that is the selector that held lines back", layer: "unit" }
    it "names --from-line as the selector when that is the flag that held lines back" do
      expect(deliver(["--json", "--from-line", "3", sink(run_payload, run_payload, run_payload)])).to eq(0)

      expect(document["summary"]).to include("selector" => "--from-line", "skipped" => 2, "lines" => 1)
      expect(document["lines"].first["number"]).to eq(3)
    end

    # `--from-line` defaults to 1 when it was not given at all, so a document that
    # named it unconditionally would report a selector the user never typed.
    # @intent: { entity: "specguard-ingest --json", action: "stay consistent", behavior: "no selector is named when nothing held anything back", layer: "unit" }
    it "names no selector when nothing held anything back" do
      expect(deliver(["--json", sink(run_payload)])).to eq(0)

      expect(document["summary"]["selector"]).to be_nil
      expect(document["summary"]["skipped"]).to eq(0)
    end

    # @intent: { entity: "specguard-ingest --json", action: "stay consistent", behavior: "the document counts the blank lines it skipped rather than dropping them", layer: "unit" }
    it "counts the blank lines it skipped rather than dropping them from the document" do
      path = File.join(@dir, "gappy.jsonl")
      File.write(path, "#{JSON.generate(run_payload)}\n\n\n#{JSON.generate(run_payload)}\n")

      expect(deliver(["--json", path])).to eq(0)

      expect(document["summary"]).to include("lines" => 2, "blank" => 2)
      expect(document["lines"].map { |entry| entry["number"] }).to eq([1, 4])
    end

    # Folding, as data rather than as a sentence — one grouping rendered twice, so
    # the observation cannot disagree with itself.
    # @intent: { entity: "specguard-ingest --json", action: "report folding", behavior: "an observed folding reports the lines, the run identity and the run id", layer: "unit" }
    it "reports an observed folding as the lines, the run identity and the run id" do
      path = sink(run_payload(ci_run_id: "17442"), run_payload(ci_run_id: "17442"), run_payload(ci_run_id: "x"))
      expect(deliver(["--json", path])).to eq(0)

      expect(document["foldings"]).to eq(
        [{ "ci_run_id" => "17442", "test_run_id" => "tr_7", "lines" => [1, 2] }]
      )
    end

    # @intent: { entity: "specguard-ingest --json", action: "report folding", behavior: "no folding is claimed where none was observed", layer: "unit" }
    it "claims no folding where none was observed" do
      expect(deliver(["--json", sink(run_payload(ci_run_id: "a"), run_payload(ci_run_id: "b"))])).to eq(0)

      expect(document["foldings"]).to eq([])
    end

    # The document does not claim lint's schema id or its `mode`. That document
    # mirrors `validate-intent --json --source` key for key because the gem
    # consumes it; this one is about deliveries, and naming a schema it has
    # nothing to do with would assert a conformance it cannot have.
    # @intent: { entity: "specguard-ingest --json", action: "declare itself", behavior: "the document names the tool that wrote it rather than a schema it does not implement", layer: "unit" }
    it "names the tool that wrote it rather than a schema it does not implement" do
      expect(deliver(["--json", sink(run_payload)])).to eq(0)

      expect(document).to include("tool" => "specguard-ingest", "mode" => "deliver")
      expect(document).not_to have_key("schema")
      expect(document.keys).to eq(%w[tool mode file summary lines foldings])
    end

    # The exit status is the one carrier of this command's verdict, and 0/1/2 do
    # not collapse to a boolean: restating it in the document would be a second
    # copy free to drift from the first.
    # @intent: { entity: "specguard-ingest --json", action: "declare itself", behavior: "the document carries no ok and no exit code field", layer: "unit" }
    it "carries no ok and no exit_code" do
      expect(deliver(["--json", sink(run_payload)], status: 400)).to eq(1)

      expect(document).not_to have_key("ok")
      expect(document).not_to have_key("exit_code")
    end

    describe "under --list" do
      # ⭐ Criterion 4. `#run` short-circuits to `#list` AHEAD of
      # `build_transport`, and the file most worth previewing is the one the
      # formatter wrote BECAUSE no API key was set. A renderer must not be able
      # to reintroduce the credential requirement that ordering exists to avoid.
      # @intent: { entity: "specguard-ingest --json --list", action: "run unconfigured", behavior: "the json listing runs with neither endpoint nor key set", layer: "unit" }
      it "lists with neither SPECGUARD_ENDPOINT nor SPECGUARD_API_KEY set" do
        path = sink(run_payload(ci_run_id: nil))
        code = described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--list", "--json", path])

        expect(code).to eq(0)
        expect(document["lines"].first).to include("branch" => "main", "ci_run_id" => nil)
        expect(err).to be_empty
      end

      # == Co-maintained with README's listed-line table
      #
      # This `eq` is over the whole hash, so it is the executable enumeration of
      # the listed row's key set — and the README's "Every listed line has the
      # same eight keys" table is the prose half of the same claim, with nothing
      # in the suite reading it. The paragraph it replaced named 6 of these 8
      # (`reasons` and `number` were missing) and shipped green. A key added or
      # removed here fails this example: update that table in the same commit.
      # @intent: { entity: "specguard-ingest --json --list", action: "render rows", behavior: "the rows carry the envelope facts as values rather than prose", layer: "unit" }
      it "carries the envelope facts the row prints, as values rather than prose" do
        path = sink(run_payload(ci_run_id: "17442"))
        described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--list", "--json", path])

        expect(document["lines"]).to eq(
          [{ "number" => 1, "status" => "listed", "reasons" => [], "branch" => "main",
             "commit_sha" => "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2", "ci_run_id" => "17442",
             "examples" => 1, "duration_seconds" => 1.25 }]
        )
      end

      # `no branch` and `no specs` become `null`, and for the reason the row says
      # them at all: the envelope is free-form, and rendering `{"a"=>1}` as a
      # branch would be this tool inventing structure the line does not have. `0
      # examples` and "the line does not say" stay different facts — 0 against
      # null, where the prose has `0 examples` against `no specs`.
      # @intent: { entity: "specguard-ingest --json --list", action: "render rows", behavior: "a fact the line does not carry reports null and an empty one reports as itself", layer: "unit" }
      it "reports a fact the line does not carry as null, and an empty one as itself" do
        path = sink({ "branch" => { "a" => 1 }, "ci_run_id" => %w[x] }, { "specs" => [], "branch" => "main" })
        described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--list", "--json", path])

        expect(document["lines"].first).to include(
          "branch" => nil, "commit_sha" => nil, "ci_run_id" => nil, "examples" => nil,
          "duration_seconds" => nil
        )
        expect(document["lines"].last).to include("examples" => 0, "branch" => "main")
      end

      # ⭐ Criterion 5. `--list` is the documented route to the numbers, so a
      # preview that disagreed with the delivery would hand the user a set they
      # did not send. Asserted as the two agreeing on the same file and the same
      # spec rather than as two expectations that happen to match.
      # @intent: { entity: "specguard-ingest --json --list", action: "render rows", behavior: "the preview shows exactly the lines the same spec delivers, by the same numbers", layer: "unit" }
      it "previews exactly the lines the same spec delivers, by the same numbers" do
        path = sink(*%w[a b c d e f g].map { |id| run_payload(ci_run_id: id) })

        code = described_class.new(stdout: stdout, stderr: stderr, env: {})
                              .run(["--list", "--json", "--lines", "3,7", path])
        listed = document["lines"].map { |entry| entry["number"] }

        expect(code).to eq(0)
        expect(listed).to eq([3, 7])
        expect(document["summary"]).to include("lines" => 2, "skipped" => 5, "selector" => "--lines")

        delivered = StringIO.new
        expect(deliver(["--json", "--lines", "3,7", path], stdout: delivered)).to eq(0)
        expect(JSON.parse(delivered.string)["lines"].map { |entry| entry["number"] }).to eq(listed)
      end

      # The other half of criterion 5: the listing's document has to SAY nothing
      # was delivered, the way the text listing's summary says it in words. Every
      # delivery status is 0 and `attempted` is 0 — which is a statement, not an
      # absence.
      # @intent: { entity: "specguard-ingest --json --list", action: "render rows", behavior: "the json listing says nothing was delivered even with a live endpoint configured", layer: "unit" }
      it "says nothing was delivered, even with a live endpoint configured" do
        StubIngestEndpoint.run do |server|
          path = sink(run_payload, "{not json")
          code = described_class.new(stdout: stdout, stderr: stderr,
                                     env: env.merge("SPECGUARD_ENDPOINT" => server.endpoint))
                               .run(["--list", "--json", path])

          expect(code).to eq(0)
          expect(server.requests).to be_empty
          expect(document["mode"]).to eq("list")
          expect(document["summary"]).to eq(
            "lines" => 2, "attempted" => 0, "accepted" => 0, "refused" => 0, "undelivered" => 0,
            "unparseable" => 1, "blank" => 0, "skipped" => 0, "selector" => nil
          )
          expect(document["foldings"]).to eq([])
        end
      end

      # Listing delivers nothing, so it can never carry a verdict about anybody's
      # run — `EXIT_REFUSED` stays produced in exactly one place, which listing
      # does not reach. Both files below are ones the delivery path exits non-zero
      # on; listed under `--json`, both are 0.
      # @intent: { entity: "specguard-ingest --json --list", action: "keep the codes apart", behavior: "the json listing never reaches exit one and exits zero where delivery would exit two", layer: "unit" }
      it "never reaches exit 1, and exits 0 on a file delivery would exit 2 for" do
        StubIngestEndpoint.run(status: 400, body: '{"message":"no"}') do |server|
          configured = env.merge("SPECGUARD_ENDPOINT" => server.endpoint)
          path = sink(run_payload)

          listed = described_class.new(stdout: StringIO.new, stderr: StringIO.new, env: configured)
                                 .run(["--list", "--json", path])
          delivered = described_class.new(stdout: StringIO.new, stderr: StringIO.new, env: configured)
                                    .run(["--json", path])

          expect([listed, delivered]).to eq([0, 1])
        end
      end

      # @intent: { entity: "specguard-ingest --json --list", action: "keep the codes apart", behavior: "an unparseable line is listed as unparseable and the listing keeps going", layer: "unit" }
      it "lists an unparseable line as unparseable and keeps going" do
        path = File.join(@dir, "binary.jsonl")
        File.open(path, "wb") do |file|
          file.write("#{JSON.generate(run_payload)}\n")
          file.write([0xC3, 0x28, 0xFF, 0x0A].pack("C*"))
          file.write("#{JSON.generate(run_payload(ci_run_id: 'last'))}\n")
        end

        expect(described_class.new(stdout: stdout, stderr: stderr, env: {}).run(["--list", "--json", path])).to eq(0)

        expect(document["lines"].map { |entry| entry["status"] }).to eq(%w[listed unparseable listed])
        expect(document["lines"][1]["reasons"])
          .to eq(["the line is not valid UTF-8, so it cannot be a run"])
        expect(err).to be_empty
      end
    end

    # ⭐ Criterion 6. A run that never got as far as reading <file> has nothing to
    # be a document about, and `{"lines": []}` for one is exactly how a run that
    # was never attempted gets mistaken for a file with nothing in it. So stdout
    # stays EMPTY and the prose stays on stderr — which is also what keeps a
    # `jq`-consuming CI step's failure legible as the misuse it is.
    describe "a run that never got to the file" do
      let(:endpoint) { "https://specguard.example.com" }

      {
        "no endpoint configured" => [%w[--json], {}],
        "no API key configured" => [%w[--json], { "SPECGUARD_ENDPOINT" => "https://specguard.example.com" }],
        "--from-line given with --lines" => [["--json", "--from-line", "2", "--lines", "3"], nil],
        "--from-line given with --lines under --list" =>
          [["--list", "--json", "--from-line", "2", "--lines", "3"], {}]
      }.each do |name, (flags, environment)|
        # @intent: { entity: "specguard-ingest --json", action: "fail without a document", behavior: "a run that never reached the file writes nothing on stdout and exits two", layer: "unit" }
        it "writes nothing on stdout and exits 2 on #{name}" do
          path = sink(run_payload, run_payload, run_payload)
          code = described_class.new(stdout: stdout, stderr: stderr, env: environment || env).run([*flags, path])

          expect(code).to eq(2)
          expect(out).to be_empty
          expect(err).to start_with("specguard-ingest: error: ")
        end
      end

      # Both modes, because they reach the same {#read_source} by different
      # routes: delivery through `build_transport` first, listing deliberately
      # ahead of it.
      # @intent: { entity: "specguard-ingest --json", action: "fail without a document", behavior: "an unreadable file writes nothing on stdout and exits two", layer: "unit" }
      it "writes nothing on stdout and exits 2 on a file it cannot read" do
        gone = File.join(@dir, "gone.jsonl")
        listing = described_class.new(stdout: stdout, stderr: stderr, env: {})

        expect(cli.run(["--json", gone])).to eq(2)
        expect(listing.run(["--list", "--json", gone])).to eq(2)

        expect(out).to be_empty
        expect(err).to eq("specguard-ingest: error: no such file: #{gone}\n" * 2)
      end

      # @intent: { entity: "specguard-ingest --json", action: "fail without a document", behavior: "a bad flag beside the json flag writes nothing on stdout and exits two", layer: "unit" }
      it "writes nothing on stdout and exits 2 on a bad flag alongside it" do
        expect(cli.run(["--json", "--replaay", "f.jsonl"])).to eq(2)

        expect(out).to be_empty
        expect(err).to eq("specguard-ingest: error: invalid option: --replaay\n")
      end

      # The internal-error backstop is what makes `1` mean one thing, and the
      # renderer must not stand between a bug in this tool and that 2.
      # @intent: { entity: "specguard-ingest --json", action: "fail without a document", behavior: "an unexpected internal failure reports as a two printing no document", layer: "unit" }
      it "reports an unexpected internal failure as a 2, printing no document" do
        allow(SpecGuard::RSpec::Transport).to receive(:new).and_raise(NotImplementedError, "boom")

        expect(cli.run(["--json", sink(run_payload)])).to eq(2)
        expect(out).to be_empty
        expect(err).to eq("specguard-ingest: internal error: NotImplementedError: boom\n")
      end
    end

    # A file the tool DID read is a different case from one it never opened: the
    # document is a true statement about an empty selection, and the warning that
    # says WHY it was empty is a diagnostic about this tool, so it stays on stderr
    # in both renderers.
    describe "a file with nothing in it" do
      # @intent: { entity: "specguard-ingest --json", action: "fail without a document", behavior: "a delivery still writes its document with any warning on stderr", layer: "unit" }
      it "still writes a document for a delivery, with the warning on stderr" do
        path = File.join(@dir, "empty.jsonl")
        File.write(path, "")

        expect(deliver(["--json", path])).to eq(0)

        expect(document["lines"]).to eq([])
        expect(document["summary"]).to include("lines" => 0, "attempted" => 0, "accepted" => 0)
        expect(err).to eq("specguard-ingest: warning: #{path} holds no runs to deliver\n")
      end

      # @intent: { entity: "specguard-ingest --json", action: "fail without a document", behavior: "an empty listing still writes its document naming why it was empty on stderr", layer: "unit" }
      it "still writes a document for a listing, naming why it was empty on stderr" do
        path = sink(run_payload, run_payload)
        code = described_class.new(stdout: stdout, stderr: stderr, env: {})
                              .run(["--list", "--json", "--lines", "9-11", path])

        expect(code).to eq(0)
        expect(document["lines"]).to eq([])
        expect(document["summary"]).to include("lines" => 0, "skipped" => 2, "selector" => "--lines")
        expect(err).to eq("specguard-ingest: warning: #{path} holds no runs to list " \
                          "(2 lines not selected by --lines)\n")
      end
    end

    # @intent: { entity: "specguard-ingest help", action: "document the json flag", behavior: "the json flag is documented in the help beside the flag that enables it", layer: "unit" }
    it "is documented in the help, alongside the flag that enables it" do
      cli.run(["--help"])
      screen = out.gsub(/\s+/, " ")

      expect(screen).to include("Emit one JSON document on stdout instead of the human report")
      expect(screen).to include("--json replaces the human report with one JSON document on stdout, in both modes")
      expect(screen).to include("the FULL list of reasons a refusal named")
      expect(screen).to include("a run that never got as far as reading <file> writes no document at all")
    end
  end

  describe "--help and --version" do
    let(:endpoint) { "https://specguard.example.com" }

    # @intent: { entity: "specguard-ingest help", action: "print usage", behavior: "the help flag exits zero and prints the usage", layer: "unit" }
    it "exits 0 and prints the usage" do
      expect(cli.run(["--help"])).to eq(0)
      expect(out).to include(described_class::BANNER)
    end

    # The second constraint the ticket found, discharged where a user meets it.
    # The sink mixes failed deliveries with ordinary keyless local runs and
    # nothing on the line tells them apart, so a developer must be able to learn
    # BEFORE running this that their laptop's whole history will be sent.
    # @intent: { entity: "specguard-ingest help", action: "warn about delivery", behavior: "the help warns that every line is delivered, failures or not", layer: "unit" }
    it "warns in the help that every line is delivered, failures or not" do
      cli.run(["--help"])

      expect(out).to include("EVERY line in <file> is delivered")
      expect(out).to include("when no API key was configured at all")
    end

    # The hazard above was stated with no remedy for as long as there was none.
    # `--help` is where a user meets both, so it must name the thing that lets
    # them act on the warning — and say that it costs no credentials, since the
    # file worth checking is the keyless one.
    # @intent: { entity: "specguard-ingest help", action: "warn about delivery", behavior: "the remedy is named next to the hazard, with the note that listing needs no key", layer: "unit" }
    it "names the remedy next to the hazard, and that listing needs no key" do
      cli.run(["--help"])

      expect(out).to include("--list prints one row per line")
      expect(out).to include("no SPECGUARD_ENDPOINT and no SPECGUARD_API_KEY")
      expect(out).to include("List the runs in <file> without delivering any of them")
    end

    # @intent: { entity: "specguard-ingest help", action: "print the version", behavior: "the version flag prints the gem version", layer: "unit" }
    it "prints the gem version" do
      expect(cli.run(["--version"])).to eq(0)
      expect(out).to eq("specguard-ruby #{SpecGuard::VERSION}\n")
    end

    # Two selectors that cannot be given together is exactly the kind of rule a
    # user meets as an error message and never as documentation, unless the
    # help says it. Asserted alongside the behaviour that enforces it, for the
    # reason the exit-code table is: this fails if the help stops saying it, and
    # equally if the pair ever stops being refused.
    # @intent: { entity: "specguard-ingest help", action: "document selectors", behavior: "the help documents the lines flag and the rule that it does not combine with the resume flag", layer: "unit" }
    it "documents --lines and the rule that it does not combine with --from-line" do
      cli.run(["--help"])
      screen = out.gsub(/\s+/, " ")

      expect(screen).to include("--lines to send an arbitrary set of them — 3,7,12-15")
      expect(screen).to include("Both narrow the same file, so give one or the other and never both")
      expect(screen).to include("Deliver only the lines SPEC names")
      expect(screen).to include("Not combinable with --from-line")

      paired = described_class.new(stdout: StringIO.new, stderr: StringIO.new, env: {})
                              .run(["--lines", "1", "--from-line", "1", sink(run_payload)])

      expect(paired).to eq(2)
    end
  end

  # #run returns 0, 1 or 2 and never raises — the property `bin/specguard-ingest`
  # depends on, since it turns the return value straight into an exit status.
  describe "the backstop that keeps 1 meaning one thing" do
    # @intent: { entity: "specguard-ingest", action: "contain internal errors", behavior: "an unexpected internal failure reports as a two in those words", layer: "unit" }
    it "reports an unexpected internal failure as a 2, in those words" do
      allow(SpecGuard::RSpec::Transport).to receive(:new).and_raise(NotImplementedError, "boom")

      code = described_class.new(stdout: stdout, stderr: stderr,
                                 env: { "SPECGUARD_ENDPOINT" => "https://specguard.example.com",
                                        "SPECGUARD_API_KEY" => "sgk_abc" }).run([sink(run_payload)])

      expect(code).to eq(2)
      expect(err).to eq("specguard-ingest: internal error: NotImplementedError: boom\n")
    end

    # @intent: { entity: "specguard-ingest", action: "contain internal errors", behavior: "every argv shape above answers only zero, one or two", layer: "unit" }
    it "answers only 0, 1 or 2 across every shape above" do
      expect([described_class::EXIT_OK, described_class::EXIT_REFUSED, described_class::EXIT_MISUSE])
        .to eq([0, 1, 2])
    end
  end

  # SPGD-1288. The linter's EPIPE carve-out, transferred: a truncating
  # consumer — `| head`, a CI log tailer that stopped reading — closes the
  # read end of the pipe while the report is still being written, and the
  # next stdout write raises Errno::EPIPE, which used to reach the backstop
  # and fabricate a 2 with an `internal error:` line. On `--list` that was
  # a 0 → 2 flip on a clean listing; on the delivery path the exit code
  # alone cannot show the defect — 2 is the legitimate `:undelivered` code
  # there — so the pin is the stderr line. Real process, real pipe: a
  # StringIO stdout cannot raise EPIPE, so no library-level example can
  # express this.
  describe "a truncating pipe" do
    def ingest_exe
      File.expand_path("../../../bin/specguard-ingest", __dir__)
    end

    # 2000 whole-run lines at ~100 listed bytes each clear the kernel's
    # 64 KiB pipe buffer with margin. Below the buffer the writer never
    # blocks on a closed pipe, no EPIPE is raised, and a truncation example
    # would pass on the unfixed tree while pinning nothing.
    def big_sink(line_count = 2000)
      path = File.join(@dir, "big_test_results.jsonl")
      content = Array.new(line_count) { |i| JSON.generate(run_payload(ci_run_id: i.to_s)) }.join("\n")
      File.write(path, content << "\n")
      path
    end

    # Spawns the real executable with stdout on a real pipe, hands the read
    # end to the block — which plays the consumer: reads what it wants,
    # hangs up when it wants — and returns the exit status the shell would
    # see, with stderr drained to EOF.
    def ingest_behind_pipe(process_env, *args)
      _stdin, stdout, stderr, wait_thr = Open3.popen3(process_env, RbConfig.ruby, ingest_exe, *args)
      yield stdout
      stdout.close unless stdout.closed?
      err = stderr.read
      [wait_thr.value.exitstatus, err]
    end

    # The discard endpoint: nothing listens on port 9, so every line is
    # instantly `:undelivered` — the delivery path's real 2 — with no server
    # to stand up and no network touched.
    DISCARD_ENDPOINT = { "SPECGUARD_ENDPOINT" => "http://127.0.0.1:9/ingest",
                         "SPECGUARD_API_KEY" => "sgk_abc123" }.freeze

    # @intent: { entity: "specguard-ingest", action: "keep the verdict behind a truncating pipe", behavior: "a listing piped into a consumer that stops reading early still exits zero with no internal error", layer: "integration" }
    it "lists clean when the consumer stops reading early" do
      code, err = ingest_behind_pipe({}, "--list", big_sink) do |stdout|
        5.times { stdout.gets } # the consumer has its lines and stops reading
      end

      expect(code).to eq(0)
      expect(err).not_to include("internal error")
    end

    # @intent: { entity: "specguard-ingest", action: "keep the verdict behind a truncating pipe", behavior: "a truncated delivery report exits with its legitimate undelivered verdict and no internal error on stderr", layer: "integration" }
    it "reports the legitimate delivery verdict when the delivery report is truncated" do
      code, err = ingest_behind_pipe(DISCARD_ENDPOINT, big_sink) do |stdout|
        5.times { stdout.gets } # the report starts only after every delivery; take some, stop reading
      end

      # 2 is this path's real answer — every line went undelivered — so the
      # exit code alone cannot distinguish the fixed tree from the broken
      # one here; the pin is that stderr carries no internal error line.
      expect(code).to eq(2)
      expect(err).not_to include("internal error")
    end

    # The control that makes the examples above mean "pipe closure" and not
    # "large output": a consumer that drains everything gets the baseline
    # code on the same sink. The size assertion is the fixture's own
    # precondition — if the sink ever stops clearing the kernel's 64 KiB
    # pipe buffer, the truncation examples would pass on the unfixed tree
    # and pin nothing.
    # @intent: { entity: "specguard-ingest", action: "keep the verdict behind a truncating pipe", behavior: "a consumer that drains the whole listing gets the baseline code, whose output clears the kernel pipe buffer", layer: "integration" }
    it "keeps the baseline code when the consumer drains the whole pipe" do
      out, _err, status = Open3.capture3(DISCARD_ENDPOINT, RbConfig.ruby, ingest_exe,
                                         "--list", big_sink)

      expect(out.bytesize).to be > 64 * 1024
      expect(status.exitstatus).to eq(0)
    end
  end

  def cli_for(endpoint)
    described_class.new(stdout: stdout, stderr: stderr,
                        env: { "SPECGUARD_ENDPOINT" => endpoint, "SPECGUARD_API_KEY" => "sgk_abc123" })
  end
end
