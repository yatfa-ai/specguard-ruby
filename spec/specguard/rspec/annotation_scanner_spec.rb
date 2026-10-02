# frozen_string_literal: true

require "timeout"

RSpec.describe SpecGuard::Client::AnnotationScanner do
  def intents(text)
    described_class.each_intent(text).to_a
  end

  describe ".each_intent" do
    # @intent: { entity: "AnnotationScanner", action: "number findings by line", behavior: "each captured annotation carries the one-based line number it was written on", layer: "unit" }
    it "reports the 1-based line number of each annotation" do
      text = "line one\n# @intent: {a: 1}\nline three\n# @intent: {b: 2}\n"

      expect(intents(text).map(&:first)).to eq([2, 4])
    end

    # @intent: { entity: "AnnotationScanner", action: "return raw payloads", behavior: "the payload comes back exactly as written, still in permissive syntax, for the normalizer to handle", layer: "unit" }
    it "returns the payload exactly as written, still in permissive syntax" do
      _, raw, = intents("# @intent: {entity: 'Order'}").first

      expect(raw).to eq("{entity: 'Order'}")
    end

    # @intent: { entity: "AnnotationScanner", action: "scan trailing prose", behavior: "a second token in the prose after a payload yields a second capture on the same line", layer: "unit" }
    it "finds a second annotation in the trailing prose of the same line" do
      text = %(# @intent: {a: 1} and also @intent: {b: 2})

      expect(intents(text).map { |_, raw, _| raw }).to eq(["{a: 1}", "{b: 2}"])
    end

    # @intent: { entity: "AnnotationScanner", action: "skip rescan of payloads", behavior: "a token quoted inside a captured payload is not itself reported as another annotation", layer: "unit" }
    it "does not rescan the captured payload for a nested token" do
      text = %(# @intent: { behavior: "mentions @intent: {nope} in prose" })

      expect(intents(text).length).to eq(1)
    end

    # The payload-brace search is bounded by the next `@intent:` token, and
    # that bound is a naive string search — so it finds this line's quoted
    # token too. It must not matter: a token quoted *inside* a payload is by
    # definition after that payload's `{`, so the bound is inert and the
    # capture is unchanged. The example above pins the count; this one pins
    # that the payload itself still comes back whole.
    # @intent: { entity: "AnnotationScanner", action: "capture whole payloads", behavior: "a payload whose value quotes a token still comes back whole, byte for byte", layer: "unit" }
    it "captures the whole payload when the payload quotes an @intent: token" do
      text = %(# @intent: { behavior: "mentions @intent: {nope} in prose" })

      expect(intents(text).map { |_, raw, _| raw })
        .to eq([%({ behavior: "mentions @intent: {nope} in prose" })])
    end

    # @intent: { entity: "AnnotationScanner", action: "enumerate lazily", behavior: "calling each_intent without a block returns an Enumerator", layer: "unit" }
    it "returns an Enumerator without a block" do
      expect(described_class.each_intent("# @intent: {a: 1}")).to be_a(Enumerator)
    end

    # @intent: { entity: "AnnotationScanner", action: "scan clean files", behavior: "a file carrying no annotations yields nothing", layer: "unit" }
    it "yields nothing for a file with no annotations" do
      expect(intents("RSpec.describe Order do\nend\n")).to be_empty
    end

    # @intent: { entity: "AnnotationScanner", action: "tolerate a missing final newline", behavior: "a final annotation with no trailing newline is still captured exactly once", layer: "unit" }
    it "is not confused by a file with no trailing newline" do
      expect(intents("# @intent: {a: 1}").length).to eq(1)
    end

    context "when an annotation cannot be captured" do
      # @intent: { entity: "AnnotationScanner", action: "report bare tokens", behavior: "a token with nothing after it yields a no-payload problem rather than being skipped", layer: "unit" }
      it "reports a token with nothing after it" do
        _, raw, problem = intents("# @intent:").first

        expect(raw).to be_nil
        expect(problem).to eq("no '{...}' object literal follows the @intent: token")
      end

      # @intent: { entity: "AnnotationScanner", action: "report prose-only tokens", behavior: "a token followed by prose but no object literal yields the no-payload problem", layer: "unit" }
      it "reports a token followed by prose but no object literal" do
        _, _, problem = intents("# @intent: see the other spec").first

        expect(problem).to eq("no '{...}' object literal follows the @intent: token")
      end

      # @intent: { entity: "AnnotationScanner", action: "report run-on payloads", behavior: "a payload that runs past the end of its line yields the unterminated object problem", layer: "unit" }
      it "reports a payload that runs off the end of the line" do
        _, _, problem = intents(%(# @intent: { entity: "Order", action: "total",)).first

        expect(problem).to eq("unterminated object literal (an annotation must fit on one line)")
      end

      # The string scan fails before the object scan can, so the reason names
      # the string rather than the object — the more specific diagnosis, and
      # what `validate-intent` reports too.
      # @intent: { entity: "AnnotationScanner", action: "report open strings", behavior: "an unterminated quoted string inside a payload is named as a string problem, the more specific diagnosis", layer: "unit" }
      it "reports an unterminated string inside the payload" do
        _, _, problem = intents(%(# @intent: { entity: "Order })).first

        expect(problem).to eq(%(unterminated "-quoted string))
      end

      # @intent: { entity: "AnnotationScanner", action: "report mismatched brackets", behavior: "an array closed by a brace yields the unbalanced brackets problem", layer: "unit" }
      it "reports mismatched brackets" do
        _, _, problem = intents("# @intent: {entity: [1}").first

        expect(problem).to eq("unbalanced brackets in the annotation payload")
      end

      # Bailing out of the whole *file* on one bad line would hide every later
      # annotation; bailing out of the rest of the *line* is what the reference
      # does, since the line's structure is already untrustworthy.
      # @intent: { entity: "AnnotationScanner", action: "abandon only the broken line", behavior: "a capture failure stops that line but the next line annotations still scan normally", layer: "unit" }
      it "stops scanning the broken line but carries on with the next one" do
        text = "# @intent: { oops\n# @intent: {a: 1}\n"
        results = intents(text)

        expect(results.length).to eq(2)
        expect(results[0][2]).not_to be_nil
        expect(results[1][1]).to eq("{a: 1}")
      end

      # The payload search is bounded by the next `@intent:` token. Unbounded,
      # it read to end of line, so this token adopted its neighbour's literal
      # and was yielded with problem: nil — a typo'd annotation reported as
      # VALID, carrying an intent its author never wrote for it, and the
      # linter exiting 0 having "checked 1 annotation, 0 malformed". A false
      # green is the one outcome this tool exists to make impossible.
      context "when a malformed token is followed by a well-formed one" do
        let(:text) { %(# @intent: (entity: Order) - superseded by @intent: {"entity":"Order"}) }

        # @intent: { entity: "AnnotationScanner", action: "bound the payload search", behavior: "a malformed token followed by a well-formed one is still reported as having no payload", layer: "unit" }
        it "reports the malformed token rather than passing it" do
          _, raw, problem = intents(text).first

          expect(problem).to eq("no '{...}' object literal follows the @intent: token")
          expect(raw).to be_nil
        end

        # The sharp end of the defect: not merely that it passed, but that it
        # passed carrying somebody else's payload.
        # @intent: { entity: "AnnotationScanner", action: "bound the payload search", behavior: "the earlier token never adopts the later token object literal as its own payload", layer: "unit" }
        it "never attributes the later token's literal to the earlier one" do
          expect(intents(text).map { |_, raw, _| raw }).not_to include(%({"entity":"Order"}))
        end

        # One finding, not two: the line-abandonment rule above still holds,
        # and this fix deliberately does not touch it. The second token goes
        # unreported because the line's structure is already untrustworthy.
        # @intent: { entity: "AnnotationScanner", action: "bound the payload search", behavior: "a line with a malformed token yields one finding, the rest of the line being abandoned as untrustworthy", layer: "unit" }
        it "abandons the rest of the line, as any other capture failure does" do
          expect(intents(text).length).to eq(1)
        end
      end

      # `pos` must strictly advance (or the loop must break) on every path.
      # A line of nothing but bare tokens is the shape that would hang if a
      # future change turned a break into a retry without moving `pos`.
      # @intent: { entity: "AnnotationScanner", action: "terminate on token runs", behavior: "a line of fifty bare payload-less tokens scans to completion without hanging", layer: "unit" }
      it "terminates on a line of repeated payload-less tokens" do
        text = "# #{'@intent: ' * 50}"

        expect { Timeout.timeout(5) { intents(text) } }.not_to raise_error
      end
    end
  end

  describe ".scan_object" do
    # @intent: { entity: "AnnotationScanner", action: "scan an object", behavior: "scan_object returns the index just past the brace matching the opener it started from", layer: "unit" }
    it "returns the index just past the matching brace" do
      text = "xx{a}yy"

      expect(described_class.scan_object(text, 2)).to eq(5)
    end

    # @intent: { entity: "AnnotationScanner", action: "scan an object", behavior: "nested arrays and objects inside the payload balance correctly to the closing brace", layer: "unit" }
    it "balances nested arrays and objects" do
      text = %({ preconditions: ["a {", "b"], nested: {x: 1} })

      expect(described_class.scan_object(text, 0)).to eq(text.length)
    end

    # @intent: { entity: "AnnotationScanner", action: "scan an object", behavior: "an unterminated object literal raises ScanError rather than returning a truncated index", layer: "unit" }
    it "raises on an unterminated literal" do
      expect { described_class.scan_object("{a: 1", 0) }.to raise_error(SpecGuard::Client::ScanError)
    end
  end

  describe ".scan_string" do
    # @intent: { entity: "AnnotationScanner", action: "scan a string", behavior: "scan_string returns the index just past the closing quote it started at", layer: "unit" }
    it "returns the index just past the closing quote" do
      expect(described_class.scan_string(%("ab"c), 0, '"')).to eq(4)
    end

    # @intent: { entity: "AnnotationScanner", action: "scan a string", behavior: "a backslash-escaped quote does not terminate the string scan", layer: "unit" }
    it "honours a backslash escape so an escaped quote does not terminate it" do
      expect(described_class.scan_string(%("a\\"b"), 0, '"')).to eq(6)
    end

    # @intent: { entity: "AnnotationScanner", action: "scan a string", behavior: "a string that never closes raises ScanError naming the unterminated string", layer: "unit" }
    it "raises on an unterminated string" do
      expect { described_class.scan_string(%("abc), 0, '"') }
        .to raise_error(SpecGuard::Client::ScanError, /unterminated/)
    end
  end
end
