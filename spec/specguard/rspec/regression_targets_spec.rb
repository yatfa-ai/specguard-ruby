# frozen_string_literal: true

require "json"
require "digest"
require "stringio"
require "tmpdir"

require "specguard/rspec/ingest_cli"

require_relative "../../support/stub_ingest_endpoint"
require_relative "../../support/validator_stub"

# The four edge-case lines in the valid fixture, plus the bare-word rule.
#
# These are the cases a `gsub`-then-`JSON.parse` normalizer gets WRONG. They are
# pinned individually — rather than only via the corpus counts — so a regression
# names the specific behavior it broke instead of just moving a total from 7
# to 6.
#
# The second group in this file (`the default output path`) pins something
# else entirely, and shares the file for the reason both groups exist: they are
# regression targets, held to the byte, for behaviour that has already been
# ratified elsewhere and must not move by accident.
RSpec.describe "permissive-syntax regression targets" do
  def intent_from(line)
    findings = SpecGuard::RSpec::Scanner.scan_text(line, file: "example_spec.rb")
    expect(findings.length).to eq(1)
    expect(findings.first.problem).to be_nil
    findings.first.intent
  end

  # order_spec.rb:32 — the `\'` must be unescaped into a plain `'` rather than
  # ending the string early. `\'` is meaningless in JSON, so re-emitting it
  # verbatim would produce an invalid escape.
  # @intent: { entity: "PayloadNormalizer", action: "unescape quoted apostrophes", behavior: "the escaped apostrophe in the order fixture line thirty-two unescapes to a plain one instead of ending the string early", layer: "unit" }
  it "unescapes \\' inside a single-quoted value (:32)" do
    line = %q{  # @intent: { entity: 'Order', action: 'checkout', behavior: 'reports the card\'s expiry date in the decline notice', layer: 'request' }}

    expect(intent_from(line)["behavior"]).to eq("reports the card's expiry date in the decline notice")
  end

  # order_spec.rb:41 — PROTOCOL.md §1 allows same-line placement. Neither the
  # `}` nor the `'` inside the quoted value may terminate the payload early.
  # @intent: { entity: "AnnotationScanner", action: "extract same-line annotations", behavior: "the annotation placed after code on order fixture line forty-one extracts whole, with neither the brace nor apostrophe terminating it", layer: "unit" }
  it "extracts an annotation placed after code on the same line (:41)" do
    line = %q{  it "surfaces the decline reason" do # @intent: { entity: "Order", action: "checkout", behavior: "renders the gateway's decline reason in the {error} slot", layer: "request" }}

    expect(intent_from(line)["behavior"]).to eq("renders the gateway's decline reason in the {error} slot")
  end

  # order_spec.rb:49 — the case plain brace-counting gets wrong. The `{` in the
  # sentence is never balanced, so a depth counter that is not string-aware
  # runs off the end of the line and reports a spurious problem.
  #
  # NOTE the `%q(...)` delimiter: this line cannot be written with `%q{...}`
  # precisely because the brace it is testing is unbalanced.
  # @intent: { entity: "AnnotationScanner", action: "ignore unbalanced braces in values", behavior: "the unbalanced brace inside the quoted value on line forty-nine is ignored by the string-aware scan that plain brace counting would get wrong", layer: "unit" }
  it "ignores an unbalanced { inside a quoted value (:49)" do
    line = %q(  # @intent: { entity: "Order", action: "checkout", behavior: "returns 400 when the JSON body is truncated after the opening {", layer: "request" })

    expect(intent_from(line)["behavior"]).to eq("returns 400 when the JSON body is truncated after the opening {")
  end

  # order_spec.rb:57 — capture stops at the *matching* brace, so trailing prose
  # (braces and all) is not swallowed into the payload.
  # @intent: { entity: "AnnotationScanner", action: "stop at the matching brace", behavior: "capture ends at the brace that matches the opener, leaving trailing prose with its own braces out of the payload", layer: "unit" }
  it "stops at the matching brace and ignores trailing prose containing braces (:57)" do
    line = %q{  # @intent: { entity: "Order", action: "refund", behavior: "restores stock levels when a paid order is refunded", layer: "unit" } — see ADR-14 {§3} for why this is unit, not request.}

    expect(intent_from(line)).to eq(
      "entity" => "Order",
      "action" => "refund",
      "behavior" => "restores stock levels when a paid order is refunded",
      "layer" => "unit"
    )
  end

  # The protocol relaxes keys and quote style, never *value* quoting. A bare
  # word in value position must survive normalization unquoted so it still
  # fails — quoting it here would silently turn an invalid annotation valid.
  describe "the bare-word rule" do
    # @intent: { entity: "PayloadNormalizer", action: "apply the bare-word rule", behavior: "a bare word in key position gains quotes during normalization", layer: "unit" }
    it "quotes a bare word in key position" do
      expect(SpecGuard::RSpec::PayloadNormalizer.normalize('{entity: "Order"}')).to eq('{"entity": "Order"}')
    end

    # @intent: { entity: "PayloadNormalizer", action: "apply the bare-word rule", behavior: "a bare word in value position stays unquoted, since the protocol relaxes keys and quote style but never value quoting", layer: "unit" }
    it "leaves a bare word in value position unquoted" do
      expect(SpecGuard::RSpec::PayloadNormalizer.normalize("{layer: request}")).to eq('{"layer": request}')
    end

    # @intent: { entity: "PayloadNormalizer", action: "apply the bare-word rule", behavior: "an unquoted value therefore surfaces as a parse finding rather than being silently accepted as valid", layer: "unit" }
    it "so an unquoted value is reported as a parse problem, not accepted" do
      findings = SpecGuard::RSpec::Scanner.scan_text("# @intent: {layer: request}", file: "example_spec.rb")

      expect(findings.first.intent).to be_nil
      expect(findings.first.kind).to eq(SpecGuard::RSpec::Finding::KIND_PARSE)
      expect(findings.first.problem).to start_with("could not parse annotation:")
    end
  end

  # The payload is text from a comment in someone's spec file — i.e. it is
  # attacker-controllable. It must only ever reach JSON.parse, never eval.
  # @intent: { entity: "Scanner", action: "never evaluate payloads", behavior: "interpolation syntax planted in a payload reaches only the JSON parser and comes back as literal text, never as executed code", layer: "unit" }
  it "never evaluates the payload" do
    line = %q{# @intent: { entity: "#{raise 'code executed'}", action: 'x', behavior: 'y', layer: 'unit' }}

    expect { SpecGuard::RSpec::Scanner.scan_text(line, file: "evil_spec.rb") }.not_to raise_error
    expect(intent_from(line)["entity"]).to eq('#{raise \'code executed\'}')
  end
end

# SPGD-305's HARD CONSTRAINT, pinned rather than trusted: without `--json`,
# stdout, stderr and the exit code are byte-identical to what `70ea201` — the
# commit before the second renderer existed — produced.
#
# Why a byte lock and not "the flag defaults to false, so it is inert"
# ====================================================================
# Adding `--json` did not only add a branch. It moved the leading
# `checked N spec file(s)` line inside a conditional in `CLI#report_selection`,
# and it replaced `CLI#report_results`'s body with a partition shared by two
# renderers. Both edits are on the default path, and both are the kind that
# drifts by a space or a newline without any example noticing: the existing
# suite asserts with `include`, which is blind to a line's position, to a line
# appearing twice, and to anything gained around it.
#
# The lock is also not only this file's business.
# `spec/specguard/rspec/validator_backend_spec.rb` replays a recorded
# `validate-intent --source --json` report through this CLI over the same two
# relative paths and compares the whole of stdout — `expect(go_stdout).to
# eq(ruby_stdout)`, no extraction and no normalisation — plus stderr apart from
# the one line naming the validator, plus the exit code. The `checked …` lines
# below are INSIDE that comparison rather than stripped from it, so a drift in
# either one diffs there too. This file locks the same strings without needing a
# report to compare against, which is what makes it the half that still fails if
# the recordings are ever regenerated from a drifted binary.
#
# The three runs cover every shape the default renderer can print: the summary
# line alone, a FAIL block with schema reasons AND one with a `problem`, and the
# unread-file clause with its line-less FAIL. Paths are RELATIVE, so the
# expected bytes are stable; the first example fails loudly if the suite is not
# running from the gem root, without which the rest would be comparing piles of
# read failures.
RSpec.describe "the default output path, byte for byte" do
  # SPGD-867: the default path is the BINARY's now (the replay stub stands in
  # offline — spec/support/validator_stub.rb), so the provenance line pinned
  # below is the binary's, composed from the stub the way Runner#provenance
  # composes it from the real thing.
  before do
    @stub = ValidatorStub.install_stubbable
    allow(SpecGuard::RSpec::ValidatorBackend::Installer).to receive(:obtain).and_return(@stub)
  end

  def run(*paths)
    stdout = StringIO.new
    stderr = StringIO.new
    code = SpecGuard::RSpec::CLI.new(stdout: stdout, stderr: stderr, env: {}).run(paths)
    [stdout.string, stderr.string, code]
  end

  # The one line every run writes to stderr since SPGD-247. It is part of the
  # default path and so it is pinned here too, not normalised away.
  def provenance
    digest = Digest::SHA256.file(SpecGuard::RSpec::SCHEMA_PATH).hexdigest
    "specguard-lint: validated by validate-intent 0.1.4 (go1.22.12 #{RUBY_PLATFORM}) " \
      "schema sha256:#{digest} at #{@stub} (SPECGUARD_VALIDATE_INTENT) " \
      "— it reports enforcing the schema this gem vendors, loaded from <embedded schema>\n"
  end

  # @intent: { entity: "specguard-lint default output", action: "pin the working directory", behavior: "the byte-locked runs execute from the gem root where their relative fixture paths resolve", layer: "unit" }
  it "is running where the relative fixture paths resolve" do
    expect(%w[spec/fixtures/order_spec.rb spec/fixtures/broken_intent_spec.rb])
      .to all(satisfy { |path| File.file?(path) })
  end

  # @intent: { entity: "specguard-lint default output", action: "pin the clean report", behavior: "a clean file prints exactly the ratified stdout bytes, provenance line and summary included", layer: "unit" }
  it "prints exactly this for a clean file" do
    stdout, stderr, code = run("spec/fixtures/order_spec.rb")

    expect(stdout).to eq(<<~OUT)
      specguard-lint: checked 1 spec file
      specguard-lint: checked 7 @intent annotations, 0 malformed
    OUT
    expect(stderr).to eq(provenance)
    expect(code).to eq(0)
  end

  # @intent: { entity: "specguard-lint default output", action: "pin the malformed report", behavior: "the malformed corpus prints exactly the ratified FAIL blocks and summary bytes", layer: "unit" }
  it "prints exactly this for the malformed corpus" do
    stdout, stderr, code = run("spec/fixtures/order_spec.rb", "spec/fixtures/broken_intent_spec.rb")

    expect(stdout).to eq(<<~OUT)
      specguard-lint: checked 2 spec files
      FAIL  spec/fixtures/broken_intent_spec.rb:9
              -> <root>: missing required property 'entity'
              -> <root>: additional property 'entiity' is not allowed
      FAIL  spec/fixtures/broken_intent_spec.rb:15
              -> layer: value 'model' is not one of ['unit', 'integration', 'request', 'system']
      FAIL  spec/fixtures/broken_intent_spec.rb:21
              -> <root>: missing required property 'layer'
              -> behavior: string is 4 char(s), minLength is 15
      FAIL  spec/fixtures/broken_intent_spec.rb:28 — unterminated object literal (an annotation must fit on one line)
      FAIL  spec/fixtures/broken_intent_spec.rb:34 — no '{...}' object literal follows the @intent: token
      specguard-lint: checked 12 @intent annotations, 5 malformed
    OUT
    expect(stderr).to eq(provenance)
    expect(code).to eq(1)
  end

  # @intent: { entity: "specguard-lint default output", action: "pin the unread-file report", behavior: "a file that cannot be read prints exactly the ratified line-less FAIL and summary bytes", layer: "unit" }
  it "prints exactly this for a file it could not read" do
    stdout, stderr, code = run("spec/fixtures/gone_spec.rb")

    expect(stdout).to eq(<<~OUT)
      specguard-lint: checked 1 spec file
      FAIL  spec/fixtures/gone_spec.rb — could not read file: no file at this path
      specguard-lint: checked 0 @intent annotations, 0 malformed; 1 file could not be read
    OUT
    expect(stderr).to eq(provenance)
    expect(code).to eq(1)
  end
end

# SPGD-669's HARD CONSTRAINT, pinned rather than trusted: without `--json`,
# `specguard-ingest`'s stdout, stderr and exit code are byte-identical to what
# `b7d25cb` — the commit before this command had a second renderer — produced.
#
# Why a byte lock and not "the flag defaults to false, so it is inert"
# ===================================================================
# This is SPGD-305's argument, and it applies harder here because the renderer
# was retrofitted onto more of the default path than lint's was:
#
#   * `#report` and `#list` each grew a branch, and each moved its
#     nothing-to-do early return to make room for it.
#   * `#summary_line` stopped computing its own status counts and now takes them
#     as an argument, so that the document and the prose cannot disagree about
#     one file (criterion 9). The arithmetic moved.
#   * `#list_row` reads a `ListedLine` struct where it used to read a parsed
#     payload, and `#example_count`/`#listed_duration` folded into
#     `#listed_line`. `0 examples` versus `no specs`, and `1.25s` versus
#     `no duration_seconds`, are now decided one step further away from the
#     string that prints them.
#   * `#folding_observations` became `#folded_runs` plus
#     `#folding_observation`, so the grouping is shared and only the sentence is
#     local.
#
# Every one of those is on the path a run with no flags takes, and every one is
# the kind that drifts by a space, a semicolon or a pluralisation without any
# example noticing: `ingest_cli_spec.rb` asserts the whole of stdout in several
# places but with `include` in many more, and `include` is blind to a line's
# position, to a line appearing twice, and to anything gained around it.
#
# The runs below cover every shape the default renderer can print: all four
# per-line statuses, the identity clause, the summary with all four of its
# outcome clauses AND both of its held-back clauses AND its named-absent clause,
# a folding observation, the listing's rows and its own summary, and the two
# stderr warnings. `--from-line` and `--lines` each get a run because they print
# a *different* skipped clause and criterion 2 names them separately. The
# named-absent clause gets runs of its own on both the delivery and the listing
# path, and on stderr, because it is the one clause that names numbers rather
# than counting lines — a wholly unanswered spec and a half-answered range are
# the same event and are pinned as such.
#
# The sink's path is interpolated rather than fixed: it is a temp file by
# necessity (the command reads a real file), and the path is the one part of
# these strings that is not this command's own format.
RSpec.describe "the specguard-ingest default output path, byte for byte" do
  # Four short reasons, so `Transport::Result#reason`'s `take(3)` shows three and
  # counts one — the cap SPGD-669 did NOT touch, pinned on the line it exists for.
  #
  # These are `let`s rather than constants because a constant assigned in a block
  # body lands on `Object`, not on the example group: `ACCEPTED` and `KEY` are
  # names another spec file would plausibly want, and a redefinition costs only a
  # warning while silently replacing the value. A byte lock whose fixture can be
  # swapped from outside itself still passes — against the wrong bytes — which is
  # exactly the drift this group exists to catch.
  let(:details) { Array.new(4) { |i| "specs[#{i}] spec/u_spec.rb:#{i}: duration must be non-negative" }.freeze }
  let(:refusal) { { status: 400, body: JSON.generate("message" => details.first, "details" => details) } }
  let(:boom) { { status: 500, body: '{"message":"upstream boom"}' } }
  let(:accepted) { { status: 202 } }
  let(:key_env) { { "SPECGUARD_API_KEY" => "sgk_abc123", "SPECGUARD_TIMEOUT" => "5" } }

  around do |example|
    Dir.mktmpdir do |dir|
      @dir = dir
      example.run
    end
  end

  # One file with every shape in it: two lines that fold onto one run, a blank
  # line that still advances the numbering, a line that parses to something that
  # is not a run, one the endpoint refuses and one it never stores.
  def sink
    @sink ||= begin
      path = File.join(@dir, "test_results.jsonl")
      File.write(path, "#{[JSON.generate(payload), '', JSON.generate(payload), 'null',
                           JSON.generate(payload(ci_run_id: 'zz')),
                           JSON.generate(payload(ci_run_id: 'yy'))].join("\n")}\n")
      path
    end
  end

  def payload(ci_run_id: "17442")
    { "commit_sha" => "0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2", "branch" => "main",
      "ci_run_id" => ci_run_id, "shard_id" => "1", "duration_seconds" => 1.25,
      "specs" => [{ "id" => "./spec/orders_spec.rb[1:1]", "spec_file_path" => "spec/orders_spec.rb" }] }
  end

  # `responses` nil means no server is started at all, which is what a `--list`
  # run must be able to do: it needs no endpoint and no API key.
  def run(argv, responses: nil)
    stdout = StringIO.new
    stderr = StringIO.new
    env = responses ? key_env.dup : {}

    code =
      if responses
        StubIngestEndpoint.run(body: '{"test_run_id":"tr_7"}', responses: responses) do |server|
          build_cli(stdout, stderr, env.merge("SPECGUARD_ENDPOINT" => server.endpoint)).run(argv)
        end
      else
        build_cli(stdout, stderr, env).run(argv)
      end

    [stdout.string, stderr.string, code]
  end

  def build_cli(stdout, stderr, env)
    SpecGuard::RSpec::IngestCLI.new(stdout: stdout, stderr: stderr, env: env)
  end

  # @intent: { entity: "specguard-ingest default output", action: "pin the mixed delivery report", behavior: "a delivery hitting every status at once prints exactly the ratified per-run verdict bytes", layer: "unit" }
  it "prints exactly this for a delivery of every status at once" do
    stdout, stderr, code = run([sink], responses: [accepted, accepted, refusal, boom])

    expect(stdout).to eq(<<~OUT)
      line 1: accepted — HTTP 202, test_run_id tr_7, ci_run_id 17442
      line 3: accepted — HTTP 202, test_run_id tr_7, ci_run_id 17442
      line 4: unparseable — the line is NilClass JSON, and a run is an object
      line 5: refused — HTTP 400 — the endpoint rejected the payload — #{details.take(3).join('; ')} and 1 more
      line 6: not delivered — HTTP 500 — upstream boom
      specguard-ingest: delivered 2 of 5 runs from #{sink}; 1 refused; 1 could not be delivered; 1 could not be parsed; 1 blank line skipped
      specguard-ingest: lines 1, 3 carried ci_run_id 17442 and each came back with test_run_id tr_7 — the endpoint folded them onto one run
    OUT
    expect(stderr).to be_empty
    expect(code).to eq(2)
  end

  # @intent: { entity: "specguard-ingest default output", action: "pin the listing report", behavior: "a listing prints exactly the ratified table bytes with no endpoint needed", layer: "unit" }
  it "prints exactly this for a listing" do
    stdout, stderr, code = run(["--list", sink])

    expect(stdout).to eq(<<~OUT)
      line 1: branch main, commit_sha 0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2, ci_run_id 17442, 1 example, 1.25s
      line 3: branch main, commit_sha 0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2, ci_run_id 17442, 1 example, 1.25s
      line 4: unparseable — the line is NilClass JSON, and a run is an object
      line 5: branch main, commit_sha 0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2, ci_run_id zz, 1 example, 1.25s
      line 6: branch main, commit_sha 0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2, ci_run_id yy, 1 example, 1.25s
      specguard-ingest: listed 5 lines from #{sink}; 1 blank line skipped; nothing was delivered
    OUT
    expect(stderr).to be_empty
    expect(code).to eq(0)
  end

  # @intent: { entity: "specguard-ingest default output", action: "pin the from-line report", behavior: "selecting delivery from a line prints exactly the ratified warning bytes that name the skipped count", layer: "unit" }
  it "prints exactly this for --from-line" do
    stdout, stderr, code = run(["--from-line", "3", sink], responses: [accepted, refusal, boom])

    expect(stdout).to eq(<<~OUT)
      line 3: accepted — HTTP 202, test_run_id tr_7, ci_run_id 17442
      line 4: unparseable — the line is NilClass JSON, and a run is an object
      line 5: refused — HTTP 400 — the endpoint rejected the payload — #{details.take(3).join('; ')} and 1 more
      line 6: not delivered — HTTP 500 — upstream boom
      specguard-ingest: delivered 1 of 4 runs from #{sink}; 1 refused; 1 could not be delivered; 1 could not be parsed; 2 earlier lines skipped by --from-line
    OUT
    expect(stderr).to be_empty
    expect(code).to eq(2)
  end

  # @intent: { entity: "specguard-ingest default output", action: "pin the lines report", behavior: "selecting delivery by line range prints exactly the ratified warning bytes", layer: "unit" }
  it "prints exactly this for --lines" do
    stdout, stderr, code = run(["--lines", "1,3", sink], responses: [accepted, accepted])

    expect(stdout).to eq(<<~OUT)
      line 1: accepted — HTTP 202, test_run_id tr_7, ci_run_id 17442
      line 3: accepted — HTTP 202, test_run_id tr_7, ci_run_id 17442
      specguard-ingest: delivered 2 of 2 runs from #{sink}; 4 lines not selected by --lines
      specguard-ingest: lines 1, 3 carried ci_run_id 17442 and each came back with test_run_id tr_7 — the endpoint folded them onto one run
    OUT
    expect(stderr).to be_empty
    expect(code).to eq(0)
  end

  # @intent: { entity: "specguard-ingest default output", action: "pin the selector report", behavior: "a list run with a line selector prints exactly the ratified warning bytes naming the lines not selected", layer: "unit" }
  it "prints exactly this for --list with a selector" do
    stdout, stderr, code = run(["--list", "--lines", "3,5", sink])

    expect(stdout).to eq(<<~OUT)
      line 3: branch main, commit_sha 0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2, ci_run_id 17442, 1 example, 1.25s
      line 5: branch main, commit_sha 0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2, ci_run_id zz, 1 example, 1.25s
      specguard-ingest: listed 2 lines from #{sink}; 4 lines not selected by --lines; nothing was delivered
    OUT
    expect(stderr).to be_empty
    expect(code).to eq(0)
  end

  # Both nothing-to-do warnings, whose early returns are the two lines `--json`
  # had to move to make room for a document. Stdout stays EMPTY on the default
  # path: the warning is a diagnostic about this tool, and there is no report.
  #
  # Note the count — SIX, not "1 blank line; 5 not selected". The selector is
  # asked first in `#read_source`, so a blank line the spec does not name is held
  # back rather than counted as blank. That is the existing branch order, pinned
  # here because both clauses are built from the same `Source` the document now
  # also reads. The absent clause sits beside it rather than instead of it: the
  # held-back count is the file's own length read back, and only the second
  # clause says the typed number was never there to hold.
  # @intent: { entity: "specguard-ingest default output", action: "pin the empty-selection warning", behavior: "a selector naming nothing the file holds warns on stderr with the exact not-selected count and the exact named-absent clause while stdout stays empty", layer: "unit" }
  it "prints exactly this when a selector named nothing the file has" do
    stdout, stderr, code = run(["--list", "--lines", "99", sink])

    expect(stdout).to be_empty
    expect(stderr).to eq("specguard-ingest: warning: #{sink} holds no runs to list " \
                         "(6 lines not selected by --lines; " \
                         "--lines named 99, which the file does not have)\n")
    expect(code).to eq(0)
  end

  # @intent: { entity: "specguard-ingest default output", action: "pin the named-absent delivery report", behavior: "a delivery whose selector names lines past the end of the file prints exactly the ratified summary bytes naming those lines", layer: "unit" }
  it "prints exactly this for --lines naming past the end of the file" do
    stdout, stderr, code = run(["--lines", "1,9-11", sink], responses: [accepted])

    expect(stdout).to eq(<<~OUT)
      line 1: accepted — HTTP 202, test_run_id tr_7, ci_run_id 17442
      specguard-ingest: delivered 1 of 1 run from #{sink}; 5 lines not selected by --lines; --lines named 9-11, which the file does not have
    OUT
    expect(stderr).to be_empty
    expect(code).to eq(0)
  end

  # The half-answered range, which is the same event as the wholly unanswered
  # one: the portion past the end of the file was typed and delivered nothing.
  # The clause names that portion rather than the entry it was written in, so
  # the satisfied half is not reported as missing.
  # @intent: { entity: "specguard-ingest default output", action: "pin the named-absent listing report", behavior: "a listing whose range runs past the end of the file prints exactly the ratified summary bytes naming the unanswered portion", layer: "unit" }
  it "prints exactly this for --list with a range running past the end" do
    stdout, stderr, code = run(["--list", "--lines", "5-9", sink])

    expect(stdout).to eq(<<~OUT)
      line 5: branch main, commit_sha 0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2, ci_run_id zz, 1 example, 1.25s
      line 6: branch main, commit_sha 0d4a1f2c9b8e7d6a5f4c3b2a1908f7e6d5c4b3a2, ci_run_id yy, 1 example, 1.25s
      specguard-ingest: listed 2 lines from #{sink}; 4 lines not selected by --lines; --lines named 7-9, which the file does not have; nothing was delivered
    OUT
    expect(stderr).to be_empty
    expect(code).to eq(0)
  end

  # @intent: { entity: "specguard-ingest default output", action: "pin the empty-file warning", behavior: "delivering an empty sink file warns on stderr with the exact bytes and exits zero", layer: "unit" }
  it "prints exactly this for a delivery of an empty file" do
    path = File.join(@dir, "empty.jsonl")
    File.write(path, "")
    stdout, stderr, code = run([path], responses: [accepted])

    expect(stdout).to be_empty
    expect(stderr).to eq("specguard-ingest: warning: #{path} holds no runs to deliver\n")
    expect(code).to eq(0)
  end
end
