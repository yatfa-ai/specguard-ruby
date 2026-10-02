# frozen_string_literal: true

# The acceptance corpus. Both files are copied byte-for-byte from
# open-test-intent's `examples/sources/` so the gem's expectations are pinned to
# the protocol repo's own fixtures — but they are *copies*, deliberately: the
# roadmap forbids a cross-repo runtime dependency, and the same applies to the
# suite. They also do not ship in the gem (the gemspec excludes `spec/`), which
# is what keeps them from becoming load-bearing at runtime.
#
# NOTE: these fixtures are themselves named `*_spec.rb`, which is exactly what
# RSpec's default pattern loads. `.rspec` carries a matching `--exclude-pattern`
# so they are treated as data, not as examples.
RSpec.describe "acceptance corpus" do
  def scan(fixture)
    SpecGuard::Client::Scanner.scan_file(fixture_path(fixture))
  end

  describe "examples/sources/order_spec.rb — every annotation extracts cleanly" do
    subject(:findings) { scan("order_spec.rb") }

    # @intent: { entity: "Scanner", action: "scan the order fixture", behavior: "the protocol order fixture yields exactly seven findings at the lines the fixture pins them on", layer: "unit" }
    it "finds exactly 7 annotations, at the lines the protocol fixture puts them on" do
      expect(findings.map(&:line)).to eq([10, 17, 24, 32, 41, 49, 57])
    end

    # @intent: { entity: "Scanner", action: "scan the order fixture", behavior: "no finding on the clean order fixture carries a problem", layer: "unit" }
    it "reports no problems at all" do
      expect(findings.select(&:problem?)).to be_empty
    end

    # @intent: { entity: "Scanner", action: "scan the order fixture", behavior: "every annotation on the order fixture parses to a Hash whose keys include entity, action, behavior and layer", layer: "unit" }
    it "parses every annotation to a Hash carrying all four required keys" do
      findings.each do |finding|
        expect(finding.intent).to be_a(Hash), "#{finding.file}:#{finding.line} did not parse"
        expect(finding.intent.keys).to include("entity", "action", "behavior", "layer")
      end
    end

    # @intent: { entity: "PayloadNormalizer", action: "normalize corpus payloads", behavior: "each raw payload captured from the order fixture normalizes to a string JSON.parse accepts without raising", layer: "unit" }
    it "normalizes every payload to a string JSON.parse accepts" do
      raw_payloads(fixture_path("order_spec.rb")).each do |line_no, raw|
        normalized = SpecGuard::Client::PayloadNormalizer.normalize(raw)
        expect { JSON.parse(normalized) }.not_to raise_error, "line #{line_no} normalized to #{normalized.inspect}"
      end
    end

    # PROTOCOL.md §1 calls forms 1-3 "equivalent"; they must therefore not
    # merely all parse, they must parse to the *same* object.
    # @intent: { entity: "Scanner", action: "scan the order fixture", behavior: "the double-quoted, single-quoted and compact forms all parse to one identical intent object", layer: "unit" }
    it "parses the three equivalent forms (double-quoted, single-quoted, compact) identically" do
      forms = findings.select { |f| [10, 17, 24].include?(f.line) }.map(&:intent)
      expect(forms.uniq.length).to eq(1)
    end
  end

  describe "examples/sources/invalid/broken_intent_spec.rb — the slice-1 / slice-2 seam" do
    subject(:findings) { scan("broken_intent_spec.rb") }

    # @intent: { entity: "Scanner", action: "scan the broken fixture", behavior: "the invalid fixture yields exactly five findings at lines nine, fifteen, twenty-one, twenty-eight and thirty-four", layer: "unit" }
    it "finds exactly 5 annotations, at the lines the protocol fixture puts them on" do
      expect(findings.map(&:line)).to eq([9, 15, 21, 28, 34])
    end

    # The 3-vs-2 split IS the seam: 9/15/21 are syntactically fine and only
    # *schema*-invalid, which is the next slice's job to notice. Extraction must
    # not pre-empt that by rejecting them here.
    # @intent: { entity: "Scanner", action: "scan the broken fixture", behavior: "annotations at lines nine, fifteen and twenty-one extract without problems, leaving their schema violations for the validation stage", layer: "unit" }
    it "extracts 9, 15 and 21 cleanly — they are schema-invalid, not malformed" do
      clean = findings.select { |f| [9, 15, 21].include?(f.line) }

      expect(clean.map(&:problem)).to eq([nil, nil, nil])
      expect(clean.map(&:intent)).to all(be_a(Hash))
    end

    # @intent: { entity: "Scanner", action: "scan the broken fixture", behavior: "extracted intents keep their violations intact, including the misspelled entity key, an out-of-enum layer and a truncated required-key set", layer: "unit" }
    it "keeps the schema violations intact for the next slice to find" do
      by_line = findings.to_h { |f| [f.line, f.intent] }

      expect(by_line[9]).to include("entiity" => "Order")  # typo'd key
      expect(by_line[9]).not_to have_key("entity")
      expect(by_line[15]).to include("layer" => "model")   # outside the enum
      expect(by_line[21]).to eq("entity" => "Order", "action" => "total", "behavior" => "sums")
    end

    # @intent: { entity: "Scanner", action: "scan the broken fixture", behavior: "line twenty-eight is reported as an unterminated object literal with kind extraction and no parsed intent", layer: "unit" }
    it "reports line 28 as an unterminated literal rather than as absent" do
      finding = findings.find { |f| f.line == 28 }

      expect(finding.problem).to eq("unterminated object literal (an annotation must fit on one line)")
      expect(finding.kind).to eq(SpecGuard::Client::Finding::KIND_EXTRACTION)
      expect(finding.intent).to be_nil
    end

    # @intent: { entity: "Scanner", action: "scan the broken fixture", behavior: "the token on line thirty-four lacking an object literal is reported as a no-payload finding instead of being skipped", layer: "unit" }
    it "reports line 34's payload-less token rather than skipping it" do
      finding = findings.find { |f| f.line == 34 }

      expect(finding.problem).to eq("no '{...}' object literal follows the @intent: token")
      expect(finding.kind).to eq(SpecGuard::Client::Finding::KIND_EXTRACTION)
    end

    # The whole reason problems are Findings and not silent skips: a typo'd
    # annotation must never be indistinguishable from an unannotated example.
    # @intent: { entity: "Scanner", action: "scan the broken fixture", behavior: "the count of findings equals the count of intent tokens in the fixture source, so no token is silently dropped", layer: "unit" }
    it "never silently drops an @intent: token" do
      tokens_in_source = File.read(fixture_path("broken_intent_spec.rb")).scan("@intent:").length

      expect(findings.length).to eq(tokens_in_source)
    end
  end
end
