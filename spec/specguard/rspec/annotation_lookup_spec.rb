# frozen_string_literal: true

require "tmpdir"
require "specguard/client/annotation_lookup"
require_relative "../../support/validator_stub"

# The lookback rule (SPGD-12 §2), the downgrade policy, and the cost bound.
#
# Every "returns nil" example here is really an example about the *platform*:
# `Ingest::Payload` collects its errors globally and `valid?` requires the list
# to be empty, so an intent this class ships and the schema later rejects does
# not lose one annotation — it loses the whole run's telemetry, for every
# example in the suite. Downgrading to nil is what keeps that trade the right
# way round.
RSpec.describe SpecGuard::Client::AnnotationLookup do
  subject(:lookup) { described_class.new }

  # SPGD-867: validation is the binary's job and binary resolution is
  # default-on, so the default `lookup` resolves through the installer. The
  # suite must not download, so obtain is stubbed to the offline replay stub,
  # which also genuinely validates ad-hoc spec files (discovery from this gem +
  # json_schemer as a development-only dependency). See
  # spec/support/validator_stub.rb.
  before do
    allow(SpecGuard::Client::ValidatorBackend::Installer)
      .to receive(:obtain).and_return(ValidatorStub.install_stubbable)
  end

  attr_reader :tmpdir

  around do |example|
    Dir.mktmpdir do |dir|
      @tmpdir = dir
      example.run
    end
  end

  # A valid annotation, so that a nil result in these examples is always the
  # rule under test and never a typo in the fixture.
  #
  # A method rather than a constant: a bare `VALID = ...` inside an
  # `RSpec.describe` block assigns at the *lexical* scope, which is top level,
  # so it would define `::VALID` for the whole suite.
  def valid_annotation
    %q({ entity: "Order", action: "checkout", behavior: "returns 402 payment required on expired card", layer: "request" })
  end

  # The same annotation already parsed — what a Finding carries.
  def valid_intent
    { "entity" => "Order", "action" => "checkout",
      "behavior" => "returns 402 payment required on expired card", "layer" => "request" }
  end

  def write_spec(source, name: "sample_spec.rb")
    File.join(tmpdir, name).tap { |path| File.write(path, source) }
  end

  def intent_at(source, line, name: "sample_spec.rb")
    lookup.intent_for(file: write_spec(source, name: name), line: line)
  end

  describe "the lookback rule" do
    # @intent: { entity: "AnnotationLookup", action: "claim a comment annotation", behavior: "an annotation written as a whole comment line on the line above the example attaches to that example", layer: "unit" }
    it "attaches an annotation written on the line above the example" do
      intent = intent_at(<<~RUBY, 2)
        # @intent: #{valid_annotation}
        it "rejects checkout on an expired card" do
      RUBY

      expect(intent).to include("entity" => "Order", "action" => "checkout")
    end

    # @intent: { entity: "AnnotationLookup", action: "claim a trailing annotation", behavior: "an annotation written on the example own line attaches to that example", layer: "unit" }
    it "attaches an annotation written on the example's own line" do
      intent = intent_at(<<~RUBY, 1)
        it "rejects checkout" do # @intent: #{valid_annotation}
      RUBY

      expect(intent).to include("entity" => "Order")
    end

    # @intent: { entity: "AnnotationLookup", action: "mark unannotated examples", behavior: "an example with no annotation above or on its line reports unannotated", layer: "unit" }
    it "reports an example with no annotation anywhere as unannotated" do
      intent = intent_at(<<~RUBY, 2)
        # just a comment
        it "rejects checkout" do
      RUBY

      expect(intent).to be_nil
    end

    # One line of lookback, not "somewhere above". A wider window would attach
    # one example's intent to the next one down, which is worse than reporting
    # the truth that this example has none.
    # @intent: { entity: "AnnotationLookup", action: "bound the lookback", behavior: "the lookback reaches exactly one line, never two, so a comment two lines up is not claimed", layer: "unit" }
    it "does not reach back two lines" do
      intent = intent_at(<<~RUBY, 3)
        # @intent: #{valid_annotation}
        # an intervening comment
        it "rejects checkout" do
      RUBY

      expect(intent).to be_nil
    end

    # @intent: { entity: "AnnotationLookup", action: "bound the lookback", behavior: "an annotation below the example is never claimed by looking forward", layer: "unit" }
    it "does not reach forward to an annotation below the example" do
      intent = intent_at(<<~RUBY, 1)
        it "rejects checkout" do
        # @intent: #{valid_annotation}
      RUBY

      expect(intent).to be_nil
    end

    # The trailing form is written *on* the example, so it is the more specific
    # of the two when a file somehow carries both.
    # @intent: { entity: "AnnotationLookup", action: "prefer the own-line form", behavior: "when a line carries both a trailing annotation and a comment above, the trailing one wins", layer: "unit" }
    it "prefers the example's own line over the line above it" do
      intent = intent_at(<<~RUBY, 2)
        # @intent: { entity: "FromAbove", action: "checkout", behavior: "returns 402 payment required on expired card", layer: "request" }
        it "x" do # @intent: { entity: "SameLine", action: "checkout", behavior: "returns 402 payment required on expired card", layer: "request" }
      RUBY

      expect(intent["entity"]).to eq("SameLine")
    end

    # An example on line 1 has no line above it to look back onto. (That the
    # line-0 KIND_READ sentinel is never mistaken for one is a separate claim,
    # and unobservable here — it is pinned under "guards against a Finding shape
    # discovery does not currently produce" below.)
    # @intent: { entity: "AnnotationLookup", action: "bound the lookback", behavior: "an example on the first line of a file reads back as unannotated rather than erroring", layer: "unit" }
    it "does not look back past the first line of the file" do
      intent = intent_at(<<~RUBY, 1)
        it "rejects checkout" do
      RUBY

      expect(intent).to be_nil
    end

    # @intent: { entity: "AnnotationLookup", action: "tolerate unknown locations", behavior: "an example whose file or line is unknown answers unannotated rather than raising", layer: "unit" }
    it "reports an example whose file or line is unknown as unannotated" do
      expect(lookup.intent_for(file: nil, line: 2)).to be_nil
      expect(lookup.intent_for(file: write_spec("# @intent: #{valid_annotation}\nit 'x' do\n"), line: nil)).to be_nil
    end
  end

  # The asymmetry between the two forms, and the reason it exists.
  #
  # A comment-only line hosts no example, so its annotation has exactly one
  # possible claimant. A trailing annotation is on a line that already *is* an
  # example's, so lookback that ignored the difference would hand it to a second
  # example as well — and one-liner `it { ... }` specs make that pair adjacent in
  # ordinary, idiomatic RSpec rather than in some contrived fixture.
  #
  # Reporting the second example as unannotated is the honest answer. Reporting
  # it as annotated would store a purpose nobody declared and count it in the
  # platform's `annotated_specs_count` — a wrong annotation is worse than a
  # missing one, because a gap is visible and an invention is not.
  describe "who may claim a trailing annotation" do
    def one_liner_pair
      <<~RUBY
        it { is_expected.to eq(1) } # @intent: #{valid_annotation}
        it { is_expected.to be_positive }
      RUBY
    end

    # @intent: { entity: "AnnotationLookup", action: "scope trailing annotations", behavior: "a trailing annotation on a one-line example belongs to that example alone", layer: "unit" }
    it "gives it to the example it was written on" do
      expect(intent_at(one_liner_pair, 1)).to include("entity" => "Order")
    end

    # @intent: { entity: "AnnotationLookup", action: "scope trailing annotations", behavior: "a trailing annotation is not lent to the example on the next line", layer: "unit" }
    it "does not lend it to the example on the next line" do
      expect(intent_at(one_liner_pair, 2)).to be_nil
    end

    # Not only `it`: any line carrying code carries its annotation alone. An
    # author who annotated a `let` did not thereby annotate the example below it.
    # @intent: { entity: "AnnotationLookup", action: "scope trailing annotations", behavior: "an annotation riding any other line of code is not lent to the line below it", layer: "unit" }
    it "does not lend an annotation on any other line of code to the line below" do
      intent = intent_at(<<~RUBY, 2)
        let(:order) { build(:order) } # @intent: #{valid_annotation}
        it "rejects checkout" do
      RUBY

      expect(intent).to be_nil
    end

    # The comment form is claimable from below however deeply it is indented —
    # annotations sit with the examples they describe, not in column 1.
    # @intent: { entity: "AnnotationLookup", action: "scope trailing annotations", behavior: "an indented comment-form annotation still lends to the example directly below it", layer: "unit" }
    it "still lends an indented comment-form annotation to the line below" do
      intent = intent_at(<<~RUBY, 4)
        RSpec.describe "Order" do
          context "when signed in" do
            # @intent: #{valid_annotation}
            it "rejects checkout" do
      RUBY

      expect(intent).to include("entity" => "Order")
    end
  end

  # `each_intent` resumes scanning after each captured payload, so trailing
  # prose containing a second `@intent:` yields a second Finding on the same
  # line. Which one wins is pinned here rather than left to Hash-insertion
  # order, where it would be an accident that happens to work.
  describe "two annotations on one line" do
    # @intent: { entity: "AnnotationLookup", action: "pick between two tokens", behavior: "when one line carries two annotations, the first written is the one shipped", layer: "unit" }
    it "takes the first one written" do
      intent = intent_at(<<~RUBY, 2)
        # @intent: { entity: "First", action: "checkout", behavior: "returns 402 payment required on expired card", layer: "request" } — see also @intent: { entity: "Second", action: "checkout", behavior: "returns 402 payment required on expired card", layer: "request" }
        it "rejects checkout" do
      RUBY

      expect(intent["entity"]).to eq("First")
    end

    # The formatter's half of the false green. When the first token was
    # malformed, the unbounded payload search handed it the SECOND token's
    # literal, so this coordinate shipped a schema-valid intent nobody had
    # written for it — invented telemetry, indistinguishable on the platform
    # from a real declaration. Downgrading to nil costs one row's metadata;
    # the alternative costs the truth of `annotated_specs_count`.
    # @intent: { entity: "AnnotationLookup", action: "pick between two tokens", behavior: "a malformed first token ships no intent at all rather than falling through to the second", layer: "unit" }
    it "ships no intent at all when the first token is malformed" do
      intent = intent_at(<<~RUBY, 2)
        # @intent: (entity: Order) — superseded by @intent: { entity: "Second", action: "checkout", behavior: "returns 402 payment required on expired card", layer: "request" }
        it "rejects checkout" do
      RUBY

      expect(intent).to be_nil
    end
  end

  # Criterion 3. Each of these is an annotation the *linter* fails the build
  # over; the formatter's job is only to not make it everyone else's problem.
  describe "downgrading an annotation it cannot ship" do
    # @intent: { entity: "AnnotationLookup", action: "downgrade unshippable intents", behavior: "an unterminated object literal downgrades the example to unannotated instead of raising", layer: "unit" }
    it "downgrades an unterminated object literal" do
      intent = intent_at(<<~RUBY, 2)
        # @intent: { entity: "Order", action: "total",
        it "sums line items" do
      RUBY

      expect(intent).to be_nil
    end

    # @intent: { entity: "AnnotationLookup", action: "downgrade unshippable intents", behavior: "a token with no payload at all downgrades the example to unannotated", layer: "unit" }
    it "downgrades an @intent: token with no payload at all" do
      intent = intent_at(<<~RUBY, 2)
        # @intent:
        it "sums line items" do
      RUBY

      expect(intent).to be_nil
    end

    # @intent: { entity: "AnnotationLookup", action: "downgrade unshippable intents", behavior: "a payload that stays unparseable after normalization downgrades the example to unannotated", layer: "unit" }
    it "downgrades a payload that is not JSON even after normalization" do
      intent = intent_at(<<~RUBY, 2)
        # @intent: { entity: Order }
        it "sums line items" do
      RUBY

      expect(intent).to be_nil
    end

    # The case that makes this a policy and not a parser detail: this parses
    # cleanly into a Hash and would sail into the payload unchallenged.
    # `additionalProperties: false` is what rejects `entiity`, and it rejects it
    # on the platform's side, where the cost is the entire run.
    # @intent: { entity: "AnnotationLookup", action: "downgrade unshippable intents", behavior: "an intent the schema rejects downgrades the example to unannotated", layer: "unit" }
    it "downgrades an intent the schema rejects" do
      intent = intent_at(<<~RUBY, 2)
        # @intent: { entiity: "Order", action: "total", behavior: "sums line item prices after the discount", layer: "unit" }
        it "sums line items" do
      RUBY

      expect(intent).to be_nil
    end

    # @intent: { entity: "AnnotationLookup", action: "downgrade unshippable intents", behavior: "an intent missing a required key downgrades the example to unannotated", layer: "unit" }
    it "downgrades an intent missing a required key" do
      intent = intent_at(<<~RUBY, 2)
        # @intent: { entity: "Order", action: "total", behavior: "sums line item prices after the discount" }
        it "sums line items" do
      RUBY

      expect(intent).to be_nil
    end

    # A file that cannot be read produces one Finding at line 0. Nothing in it
    # was ever seen, so nothing in it is annotated.
    # @intent: { entity: "AnnotationLookup", action: "downgrade unreadable files", behavior: "every example from an unreadable file answers unannotated rather than raising", layer: "unit" }
    it "reports every example in an unreadable file as unannotated" do
      path = File.join(tmpdir, "gone_spec.rb")

      expect(lookup.intent_for(file: path, line: 1)).to be_nil
      expect(lookup.intent_for(file: path, line: 4)).to be_nil
    end

    # @intent: { entity: "AnnotationLookup", action: "downgrade unreadable files", behavior: "every example from a file that is not valid UTF-8 answers unannotated rather than raising", layer: "unit" }
    it "reports every example in a file that is not valid UTF-8 as unannotated" do
      path = File.join(tmpdir, "binary_spec.rb")
      # `\xC3` with no continuation byte. Assembled from binary fragments so the
      # invalid sequence is a property of the fixture on disk rather than of
      # this source file, which is UTF-8.
      File.binwrite(path, "# @intent: #{valid_annotation}".b + "\xC3\x28".b + "\nit 'x' do\n".b)

      expect(lookup.intent_for(file: path, line: 2)).to be_nil
    end
  end

  # Two guards that today's {SpecGuard::Client::Scanner} cannot exercise, pinned
  # with a stub because there is no other way to observe them.
  #
  # {SpecGuard::Client::Finding} documents that exactly one of `intent` and
  # `problem` is non-nil, and the only Finding ever produced at line 0 is a
  # KIND_READ, which by construction carries a `problem`. Both guards are
  # therefore redundant *given that invariant* — and both exist for the case
  # where it stops holding, because what gets through is an intent that nothing
  # verified, attached to an example it may not belong to, in a payload the
  # platform accepts or rejects **as a whole**.
  #
  # Written as stubs rather than deleted as dead code: an unreachable branch
  # nobody pinned is one refactor away from being reachable and wrong.
  describe "guards against a Finding shape discovery does not currently produce" do
    def stub_scanner(finding)
      allow(SpecGuard::Client::Scanner).to receive(:scan_text).and_return([finding])
    end

    def finding(**attributes)
      SpecGuard::Client::Finding.new(file: "sample_spec.rb", **attributes)
    end

    # @intent: { entity: "AnnotationLookup", action: "guard odd finding shapes", behavior: "a line-zero finding is never treated as the annotation for the example on line one", layer: "unit" }
    it "never treats a line-0 finding as the annotation for the example on line 1" do
      stub_scanner(finding(line: 0, intent: valid_intent))

      expect(lookup.intent_for(file: write_spec("it 'x' do\n"), line: 1)).to be_nil
    end

    # @intent: { entity: "AnnotationLookup", action: "guard odd finding shapes", behavior: "a finding that carries both an intent and a problem ships nothing, the problem disqualifying the payload", layer: "unit" }
    it "never ships an intent from a finding that also reports a problem" do
      stub_scanner(finding(line: 2, intent: valid_intent,
                           problem: "could not parse annotation", kind: SpecGuard::Client::Finding::KIND_PARSE))

      expect(lookup.intent_for(file: write_spec("# ...\nit 'x' do\n"), line: 2)).to be_nil
    end
  end

  # SPGD-340. The formatter's half used to run the Ruby chain unconditionally
  # while `CLI` had routed the LINTER through the backend since SPGD-247, so one
  # gem validated the same annotation with two parsers — and when they disagreed
  # CI ratified an annotation the formatter then shipped as `unannotated`,
  # silently, on both ends. This block is that seam.
  describe "when a validator backend is configured" do
    # A Runner is a subprocess wrapper; what this class depends on is the shape
    # of its answer, which is a list of Linter::Results. Stubbing at `resolve`
    # tests the wiring — the thing that was missing — without making these
    # examples require a binary. `validator_backend_spec.rb` drives a real
    # stub binary end to end.
    def with_backend(results)
      runner = instance_double(SpecGuard::Client::ValidatorBackend::Runner)
      allow(runner).to receive(:check).and_return(results)
      allow(SpecGuard::Client::ValidatorBackend).to receive(:resolve).and_return(runner)
      runner
    end

    def result(line:, intent: nil, kind: nil, problem: nil, reasons: [])
      SpecGuard::Client::Linter::Result.new(file: "sample_spec.rb", line: line, intent: intent,
                                           kind: kind, problem: problem, reasons: reasons)
    end

    let(:backend_env) { { "SPECGUARD_VALIDATE_INTENT" => "/usr/local/bin/validate-intent" } }
    subject(:lookup) { described_class.new(env: backend_env) }

    # @intent: { entity: "AnnotationLookup", action: "defer to the validator backend", behavior: "with a backend configured the intent shipped is the one the backend validated", layer: "unit" }
    it "ships the intent the backend validated" do
      with_backend([result(line: 1, intent: valid_intent)])
      path = write_spec("# @intent: #{valid_annotation}\nit 'x' do\n")

      expect(lookup.intent_for(file: path, line: 2)).to eq(valid_intent)
    end

    # The property the whole ticket is for: what the formatter ships is what the
    # BACKEND said, not what a second parser in this process would have said.
    # Asserted with a payload the two cannot agree on by accident — the Ruby
    # chain reads this file and finds a valid annotation, and the backend is
    # made to disagree — so a lookup that quietly re-derived the answer locally
    # would return the Scanner's intent and fail here.
    # @intent: { entity: "AnnotationLookup", action: "defer to the validator backend", behavior: "a backend rejection wins even when the local chain would have parsed the annotation as valid", layer: "unit" }
    it "does not re-derive the verdict locally" do
      with_backend([result(line: 1, kind: SpecGuard::Client::Finding::KIND_SCHEMA,
                           reasons: ["<root>: layer is not one of ..."], intent: valid_intent)])
      path = write_spec("# @intent: #{valid_annotation}\nit 'x' do\n")

      expect(lookup.intent_for(file: path, line: 2)).to be_nil
    end

    # @intent: { entity: "AnnotationLookup", action: "defer to the validator backend", behavior: "the backend payload is taken even where the Ruby chain could not parse the line", layer: "unit" }
    it "takes the payload from the backend even when the Ruby chain could not parse it" do
      # The motivating shape: a payload this process cannot read and the port
      # can. The file is deliberately unparseable to Ruby's JSON, so a non-nil
      # answer here can only have come from the backend.
      with_backend([result(line: 1, intent: valid_intent)])
      path = write_spec("# @intent: { entity: Order }\nit 'x' do\n")

      expect(lookup.intent_for(file: path, line: 2)).to eq(valid_intent)
    end

    # The lookback rule is the formatter's own and is NOT in the report: a
    # finding says `file:line`, and nothing in it says whether that line was a
    # comment. So the rule still has to be applied here, over the backend's
    # answers, and these are the two halves of it.
    # @intent: { entity: "AnnotationLookup", action: "defer to the validator backend", behavior: "the comment-form rule still applies to backend findings, so a trailing-only annotation is not claimed from the line above", layer: "unit" }
    it "still applies the comment-form rule to the backend's findings" do
      with_backend([result(line: 1, intent: valid_intent)])
      # Line 1 is CODE, not a comment, so line 2 may not claim it.
      path = write_spec("it 'a' do # @intent: #{valid_annotation}\nit 'b' do\n")

      expect(lookup.intent_for(file: path, line: 1)).to eq(valid_intent)
      expect(lookup.intent_for(file: path, line: 2)).to be_nil
    end

    # @intent: { entity: "AnnotationLookup", action: "defer to the validator backend", behavior: "a rejected annotation on the example own line still beats a valid comment above it", layer: "unit" }
    it "still lets a line's own rejected annotation beat the comment above it" do
      with_backend([
        result(line: 1, intent: valid_intent),
        result(line: 2, kind: SpecGuard::Client::Finding::KIND_PARSE,
               problem: "could not parse annotation")
      ])
      path = write_spec("# @intent: #{valid_annotation}\nit 'x' do # @intent: {\n")

      expect(lookup.intent_for(file: path, line: 2)).to be_nil
    end

    # Read failures and no-matches arrive line-scoped to 0, which is not a line
    # anyone can claim — the same sentinel the Ruby path filters out.
    # @intent: { entity: "AnnotationLookup", action: "defer to the validator backend", behavior: "a line-zero backend finding never becomes the annotation for line one", layer: "unit" }
    it "never lets a line-0 finding become line 1's annotation" do
      with_backend([result(line: 0, kind: SpecGuard::Client::Finding::KIND_READ,
                           problem: "could not read file: no file at this path")])

      expect(lookup.intent_for(file: write_spec("it 'x' do\n"), line: 1)).to be_nil
    end

    # The cost bound is the same bound, one process out: `--source` takes FILES,
    # so this is one shell-out per file. Per example would be O(examples)
    # subprocesses on somebody's critical path, which is the cost this class
    # exists to refuse.
    # @intent: { entity: "AnnotationLookup", action: "bound backend cost", behavior: "the backend is invoked once per file no matter how many examples come from it", layer: "unit" }
    it "invokes the backend once per file, however many examples come from it" do
      runner = with_backend([result(line: 1, intent: valid_intent)])
      path = write_spec("# @intent: #{valid_annotation}\nit 'a' do\nit 'b' do\nit 'c' do\n")

      (1..4).each { |line| lookup.intent_for(file: path, line: line) }

      expect(runner).to have_received(:check).once
    end


    # SPGD-867: there is no Ruby path to defer to any more, so the variable
    # being unset now means "resolve through the installer" — and the answer
    # still comes from the binary.
    # @intent: { entity: "AnnotationLookup", action: "resolve the validator", behavior: "with the validator variable unset the lookup resolves through the installer and still ships the valid intent", layer: "unit" }
    it "resolves through the installer when the variable is unset" do
      path = write_spec("# @intent: #{valid_annotation}\nit 'x' do\n")

      expect(described_class.new(env: {}).intent_for(file: path, line: 2)).to eq(valid_intent)
    end

    # SPGD-867, and the shape of the cutover: there is no Ruby path left to
    # fall back to, so a backend that cannot answer means the annotation ships
    # `unannotated` — the same answer this class gives for anything it could
    # not verify. The never-block-CI contract forbids anything louder from the
    # formatter; the LINTER is the loud half, and it exits 2 outright.
    # @intent: { entity: "AnnotationLookup", action: "survive an unusable backend", behavior: "a backend that cannot be resolved answers unannotated for every example rather than raising", layer: "unit" }
    it "answers unannotated when the configured binary is unusable" do
      allow(SpecGuard::Client::ValidatorBackend).to receive(:resolve)
        .and_raise(SpecGuard::Client::ValidatorError, "nope")
      path = write_spec("# @intent: #{valid_annotation}\nit 'a' do\n# @intent: #{valid_annotation}\nit 'b' do\n")

      expect(lookup.intent_for(file: path, line: 2)).to be_nil
      expect(lookup.intent_for(file: path, line: 4)).to be_nil
    end

    # ...and it probes ONCE. The resolve is a subprocess, so re-probing per
    # example is the O(examples) cost this class exists to refuse — reappearing
    # on exactly the unhappy path where somebody's CI is already having a bad
    # day. Memoized on failure, which is what makes that true.
    # @intent: { entity: "AnnotationLookup", action: "survive an unusable backend", behavior: "the unusable backend is probed exactly once, the failure being memoized", layer: "unit" }
    it "probes the unusable binary only once" do
      allow(SpecGuard::Client::ValidatorBackend).to receive(:resolve)
        .and_raise(SpecGuard::Client::ValidatorError, "nope")
      path = write_spec("# @intent: #{valid_annotation}\nit 'a' do\n# @intent: #{valid_annotation}\nit 'b' do\n")

      [2, 4].each { |line| lookup.intent_for(file: path, line: line) }

      expect(SpecGuard::Client::ValidatorBackend).to have_received(:resolve).once
    end

    # The same rule one layer in: a backend that resolved and then died
    # MID-RUN has still told us nothing about the annotation, so the file
    # answers unannotated rather than costing the run its telemetry.
    # @intent: { entity: "AnnotationLookup", action: "survive an unusable backend", behavior: "a backend that dies mid-run answers unannotated instead of costing the run its telemetry", layer: "unit" }
    it "answers unannotated when the backend dies mid-run" do
      runner = instance_double(SpecGuard::Client::ValidatorBackend::Runner)
      allow(runner).to receive(:check).and_raise(SpecGuard::Client::ValidatorError, "died")
      allow(SpecGuard::Client::ValidatorBackend).to receive(:resolve).and_return(runner)
      path = write_spec("# @intent: #{valid_annotation}\nit 'x' do\n")

      expect(lookup.intent_for(file: path, line: 2)).to be_nil
    end

    # An unreadable file is answered without starting a subprocess: the read
    # happens first on both paths, and there is nothing for a validator to say
    # about a file this process cannot open.
    # @intent: { entity: "AnnotationLookup", action: "survive an unusable backend", behavior: "a file this process cannot read is answered without starting a validator subprocess at all", layer: "unit" }
    it "does not shell out for a file it cannot read" do
      runner = with_backend([])

      expect(lookup.intent_for(file: File.join(tmpdir, "gone_spec.rb"), line: 2)).to be_nil
      expect(runner).not_to have_received(:check)
    end
  end

  # A payload can clear the schema and still be unshippable: `JSON.parse`
  # accepts a lone low surrogate and returns a String that `JSON.generate` then
  # refuses. Shipping it would take the whole run's telemetry down at the
  # transport rather than costing one example its annotation — and substituting
  # a repaired character would put an annotation on the platform that the author
  # did not write, undetectably. Unshippable means unannotated.
  describe "an intent it could parse but could not hand on" do
    # @intent: { entity: "AnnotationLookup", action: "drop unrepresentable payloads", behavior: "a payload holding a lone low surrogate downgrades to unannotated rather than detonating later at the transport", layer: "unit" }
    it "downgrades a payload holding a lone low surrogate" do
      annotation = %q({ "entity": "\udc00Or", "action": "create", ) +
                   %q("behavior": "creates an order from a valid cart", "layer": "unit" })
      intent = intent_at("# @intent: #{annotation}\nit 'x' do\n", 2)

      expect(intent).to be_nil
    end

    # Non-vacuity, and the boundary: the same annotation with a WELL-FORMED
    # surrogate pair is representable and is shipped. Without this the example
    # above would pass just as happily if the rule were "any surrogate escape"
    # or, worse, "any annotation at all".
    # @intent: { entity: "AnnotationLookup", action: "drop unrepresentable payloads", behavior: "a well-formed surrogate pair in the same position still ships the annotation", layer: "unit" }
    it "still ships the same annotation with a well-formed pair" do
      annotation = %q({ "entity": "😀Or", "action": "create", ) +
                   %q("behavior": "creates an order from a valid cart", "layer": "unit" })
      intent = intent_at("# @intent: #{annotation}\nit 'x' do\n", 2)

      expect(intent["entity"]).to eq("\u{1F600}Or")
      expect { JSON.generate(intent) }.not_to raise_error
    end
  end

  # Criterion 5. `AnnotationScanner.each_intent` walks every line of the file it
  # is handed, so scanning per example turns a 20,000-example suite into 20,000
  # reads and 20,000 full-file walks — on the critical path of somebody's test
  # run. N examples across M files must cost M scans.
  describe "cost" do
    # Counts reads per path rather than in total: `Schema.load` reads the
    # vendored schema through the same method, and RSpec itself reads source
    # files to render a failure message, so a bare call count would be a number
    # about the test framework as much as about this class.
    def read_counts
      counts = Hash.new(0)
      allow(File).to receive(:read).and_wrap_original do |original, *args, **kwargs|
        counts[args.first] += 1
        original.call(*args, **kwargs)
      end
      counts
    end

    # @intent: { entity: "AnnotationLookup", action: "bound file reads", behavior: "each spec file is read once however many examples come from it, across files and examples alike", layer: "unit" }
    it "reads each spec file once however many examples come from it" do
      counts = read_counts
      first = write_spec("# @intent: #{valid_annotation}\nit 'a' do\nit 'b' do\nit 'c' do\n", name: "a_spec.rb")
      second = write_spec("it 'd' do\nit 'e' do\n", name: "b_spec.rb")

      [1, 2, 3, 4].each { |line| lookup.intent_for(file: first, line: line) }
      [1, 2].each { |line| lookup.intent_for(file: second, line: line) }

      expect(counts[first]).to eq(1)
      expect(counts[second]).to eq(1)
    end

    # SPGD-867: on the backend path the LINES come from the backend's report
    # and `Scanner.scan_text` runs only when the backend could not answer, so
    # the local cost bound is the FILE READ the comment-form rule needs.
    # @intent: { entity: "AnnotationLookup", action: "bound file reads", behavior: "on the backend path each file is still read once for the comment-form rule", layer: "unit" }
    it "reads each spec file once" do
      counts = read_counts
      path = write_spec("# @intent: #{valid_annotation}\nit 'a' do\nit 'b' do\n")

      3.times { |i| lookup.intent_for(file: path, line: i + 1) }

      expect(counts[path]).to eq(1)
    end


  end

  # Nothing here is rescued on purpose: the formatter wraps every call in its
  # own never_fail_the_run envelope, which warns exactly once. What this class
  # owes that arrangement is that the *second* example does not raise again —
  # otherwise "warns once" would quietly still mean "rescans the file 19,999
  # more times", and the cost bound above would hold only on the happy path.
  describe "when it cannot do its job at all" do
    # Two annotations, so the second lookup is a real one. With a single
    # annotation on line 1 the follow-up call would return nil for want of
    # anything to find, and would pass whatever the schema did.
    def two_annotated_examples
      write_spec(<<~RUBY)
        # @intent: #{valid_annotation}
        it "a" do
        # @intent: #{valid_annotation}
        it "b" do
      RUBY
    end

    def unresolvable_backend
      described_class.new(env: { "SPECGUARD_VALIDATE_INTENT" => File.join(tmpdir, "no-such-binary") })
    end

    # SPGD-867: the Ruby schema load this block used to pin is gone. What
    # survives is its shape: a lookup that cannot obtain verdicts answers
    # `unannotated` — never a raise, never a silent ship — and the formatter's
    # envelope stays out of it.
    # @intent: { entity: "AnnotationLookup", action: "fail quiet and once", behavior: "a lookup with no resolvable validator answers unannotated for every example, never raising and never silently shipping", layer: "unit" }
    it "answers unannotated when no validator can be resolved" do
      broken = unresolvable_backend
      path = two_annotated_examples

      expect(broken.intent_for(file: path, line: 2)).to be_nil
      expect(broken.intent_for(file: path, line: 4)).to be_nil
    end

    # The unverified path (backend unusable) is the one that scans locally,
    # so the blow-up lands there — and the pessimistic index cache keeps
    # "warns once" meaning "scans once".
    # @intent: { entity: "AnnotationLookup", action: "fail quiet and once", behavior: "a file whose scan blew up is not rescanned by later lookups, keeping warn-once meaning scan-once", layer: "unit" }
    it "does not rescan a file whose scan blew up" do
      allow(SpecGuard::Client::ValidatorBackend).to receive(:resolve)
        .and_raise(SpecGuard::Client::ValidatorError, "nope")
      allow(SpecGuard::Client::Scanner).to receive(:scan_text).and_raise(NotImplementedError, "nope")
      path = write_spec("it 'a' do\nit 'b' do\n")

      expect { lookup.intent_for(file: path, line: 1) }.to raise_error(NotImplementedError)
      expect(lookup.intent_for(file: path, line: 2)).to be_nil
      expect(SpecGuard::Client::Scanner).to have_received(:scan_text).once
    end
  end
end
