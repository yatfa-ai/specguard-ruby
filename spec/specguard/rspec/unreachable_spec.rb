# frozen_string_literal: true

RSpec.describe SpecGuard::RSpec::Scanner do
  describe ".unreachable_findings_in_text (SPGD-900: the stacked-annotation structural pass)" do
    def findings(text)
      described_class.unreachable_findings_in_text(text, file: "order_spec.rb")
    end

    # @intent: { entity: "Scanner", action: "detect stacked annotations", behavior: "two consecutive comment-form annotations yield exactly one unreachable finding, reported on the upper line with kind unreachable", layer: "unit" }
    it "flags the UPPER line of two consecutive comment-form @intent: lines" do
      text = <<~RUBY
        # @intent: { entity: "Order", behavior: "decrements stock" }
        # @intent: { entity: "Refund", behavior: "restores stock" }
        it "restores stock on refund" do
          expect(order.stock).to eq(3)
        end
      RUBY

      expect(findings(text).length).to eq(1)
      expect(findings(text).first.line).to eq(1)
      expect(findings(text).first.kind).to eq(SpecGuard::RSpec::Finding::KIND_UNREACHABLE)
    end

    # @intent: { entity: "Scanner", action: "detect stacked annotations", behavior: "a run of three comment-form annotations flags every line except the last, at relative lines one and two", layer: "unit" }
    it "flags each line except the last of a run of three stacked annotations" do
      text = <<~RUBY
        # @intent: { entity: "A" }
        # @intent: { entity: "B" }
        # @intent: { entity: "C" }
        it "works" do end
      RUBY

      expect(findings(text).map(&:line)).to eq([1, 2])
    end

    # @intent: { entity: "Scanner", action: "spare the canonical form", behavior: "one comment annotation directly above its example produces no unreachable finding", layer: "unit" }
    it "does not flag the canonical one-comment-above-one-it form" do
      text = <<~RUBY
        # @intent: { entity: "Order", behavior: "decrements stock" }
        it "decrements stock" do end
      RUBY

      expect(findings(text)).to be_empty
    end

    # @intent: { entity: "Scanner", action: "spare trailing-form lines", behavior: "adjacent one-line examples carrying same-line annotations produce no unreachable findings", layer: "unit" }
    it "does not flag the trailing same-line form, even on adjacent one-liners" do
      text = <<~RUBY
        it { is_expected.to eq(1) } # @intent: { entity: "A" }
        it { is_expected.to be_positive } # @intent: { entity: "B" }
      RUBY

      expect(findings(text)).to be_empty
    end

    # @intent: { entity: "Scanner", action: "spare mixed forms", behavior: "a comment annotation above a line that also carries a trailing annotation is not flagged, the stacked rule covering comment-form pairs only", layer: "unit" }
    it "does not flag a comment-form annotation above a trailing-form line" do
      # The stacked rule is comment-form pairs only (SPGD-900's fix): a
      # comment-form annotation above a trailing-form line may be dead too,
      # but that shape is out of scope and must not over-match.
      text = <<~RUBY
        # @intent: { entity: "A" }
        it { is_expected.to eq(1) } # @intent: { entity: "B" }
      RUBY

      expect(findings(text)).to be_empty
    end

    # @intent: { entity: "Scanner", action: "spare separated annotations", behavior: "two comment annotations split by a plain non-intent comment are both reachable and produce no findings", layer: "unit" }
    it "does not flag separated comment annotations separated by a plain comment" do
      text = <<~RUBY
        # @intent: { entity: "A" }
        # rubocop:disable Style/... (not an intent)
        # @intent: { entity: "B" }
        it "works" do end
      RUBY

      expect(findings(text)).to be_empty
    end

    # @intent: { entity: "Scanner", action: "word the finding", behavior: "the unreachable finding carries a problem sentence naming the one-line lookback", layer: "unit" }
    it "carries a problem sentence naming the one-line lookback" do
      text = "# @intent: { entity: \"A\" }\n# @intent: { entity: \"B\" }\nit \"x\" do end\n"

      expect(findings(text).first.problem).to include("unreachable annotation")
    end
  end

  describe ".unreachable_findings_in_text (SPGD-1510: the group-line pass)" do
    def findings(text)
      described_class.unreachable_findings_in_text(text, file: "order_spec.rb")
    end

    # @intent: { entity: "Scanner", action: "detect group-line annotations", behavior: "a schema-valid trailing annotation on a describe line is flagged on that line with kind unreachable", layer: "unit" }
    it "flags an @intent: trailing on a describe group line" do
      text = <<~RUBY
        RSpec.describe "x" do
          describe "a group" do # @intent: { entity: "Forms::FieldComponent", behavior: "renders the wrapper class it consumes", layer: "integration" }
            it("works") { expect(1).to eq(1) }
          end
        end
      RUBY

      expect(findings(text).length).to eq(1)
      expect(findings(text).first.line).to eq(2)
      expect(findings(text).first.kind).to eq(SpecGuard::RSpec::Finding::KIND_UNREACHABLE)
      expect(findings(text).first.problem).to include("example-group line")
    end

    # @intent: { entity: "Scanner", action: "detect group-line annotations", behavior: "the other example-group keywords are flagged the same as describe", layer: "unit" }
    it "flags the trailing form on every example-group keyword" do
      %w[
        context
        feature
        shared_examples
        shared_examples_for
        shared_context
        example_group
      ].each do |keyword|
        text = "#{keyword} \"a group\" do # @intent: { entity: \"A\", behavior: \"renders the thing it names\", layer: \"unit\" }\n  it \"works\" do end\nend\n"
        found = findings(text)

        expect(found.length).to eq(1), "#{keyword} produced #{found.length} findings"
        expect(found.first.line).to eq(1)
      end
    end

    # @intent: { entity: "Scanner", action: "detect group-line annotations", behavior: "the RSpec-prefixed group keyword is flagged the same as the bare form", layer: "unit" }
    it "flags the RSpec.-prefixed group form" do
      text = <<~RUBY
        RSpec.describe "a group" do # @intent: { entity: "A", behavior: "renders the thing it names", layer: "unit" }
          it "works" do end
        end
      RUBY

      expect(findings(text).map(&:line)).to eq([1])
    end

    # @intent: { entity: "Scanner", action: "spare one-liner groups", behavior: "a group line that also defines its example on the same line keeps its trailing annotation unflagged", layer: "unit" }
    it "does not flag a one-liner group whose own line defines the example" do
      text = <<~RUBY
        describe "one" do it("x") { expect(1).to eq(1) } end # @intent: { entity: "A", behavior: "renders the thing it names", layer: "unit" }
      RUBY

      expect(findings(text)).to be_empty
    end

    # @intent: { entity: "Scanner", action: "flag payload prose", behavior: "a group line whose annotation payload contains the word it's is still flagged, the exemption never reading past the token", layer: "unit" }
    it "flags a group line whose payload prose contains it's" do
      # The exemption reads the code BEFORE the `@intent:` token only. The
      # payload is prose an author wrote about the behavior — `it's given
      # one` — and reading it as an example call exempted the exact
      # group-line shape this pass exists to flag (audit on SPGD-1510 round
      # 1: `specguard` carries 78 real payloads matching the old whole-line
      # form).
      text = <<~RUBY
        describe "a group" do # @intent: { entity: "A", behavior: "renders the wrapper class when it's given one", layer: "unit" }
          it "works" do end
        end
      RUBY

      expect(findings(text).map(&:line)).to eq([1])
    end

    # @intent: { entity: "Scanner", action: "flag description prose", behavior: "a group line whose description string ends in the word it is still flagged, the exemption requiring a block opener before the call", layer: "unit" }
    it "flags a group line whose description ends in the word it" do
      # `it" do` used to read as an example call because the exemption
      # scanned the description string too. The block-opener anchor (`do`,
      # `{`, `;` BEFORE the call) means a description may end in the word
      # `it` without exempting the line.
      text = <<~RUBY
        describe "the cost of rendering it" do # @intent: { entity: "A", behavior: "renders the thing it names", layer: "unit" }
          it "works" do end
        end
      RUBY

      expect(findings(text).map(&:line)).to eq([1])
    end

    # @intent: { entity: "Scanner", action: "spare prose tokens", behavior: "the @intent token inside a group description string carries no payload and is not flagged", layer: "unit" }
    it "does not flag an @intent: token inside a group's description string" do
      # Extraction is marker-based (SPGD-8 §7), so the token is found inside
      # quoted strings too — this repo's own suite carries a describe titled
      # "unreachable stacked @intent: annotations". Without the payload brace
      # requirement every such title would read as an annotation; with it,
      # only lines the scanner captures a payload from are judged.
      text = <<~RUBY
        describe "unreachable stacked @intent: annotations" do
          it "works" do end
        end
      RUBY

      expect(findings(text)).to be_empty
    end

    # @intent: { entity: "Scanner", action: "spare comment forms", behavior: "a comment-form annotation directly above a group line is out of scope and unflagged", layer: "unit" }
    it "does not flag a comment-form annotation above a group line" do
      # SPGD-1510 flags the group line ITSELF. A comment above a group is a
      # different shape, deliberately out of scope — the same boundary the
      # stacked pass draws for a comment above a trailing-form line.
      text = <<~RUBY
        # @intent: { entity: "A", behavior: "renders the thing it names", layer: "unit" }
        describe "a group" do
          it "works" do end
        end
      RUBY

      expect(findings(text)).to be_empty
    end

    # @intent: { entity: "Scanner", action: "merge the two passes", behavior: "stacked and group-line findings in one file come back merged in line order", layer: "unit" }
    it "merges stacked and group-line findings in line order" do
      text = <<~RUBY
        # @intent: { entity: "A", behavior: "renders the thing it names", layer: "unit" }
        # @intent: { entity: "B", behavior: "renders the thing it names", layer: "unit" }
        it "works" do end
        context "a group" do # @intent: { entity: "C", behavior: "renders the thing it names", layer: "unit" }
          it "also works" do end
        end
      RUBY

      expect(findings(text).map(&:line)).to eq([1, 4])
    end

    # @intent: { entity: "Scanner", action: "word the finding", behavior: "the group-line finding names why it is unreachable and where to move the annotation", layer: "unit" }
    it "carries a problem sentence naming examples, not groups" do
      text = "describe \"a group\" do # @intent: { entity: \"A\", behavior: \"renders the thing it names\", layer: \"unit\" }\n  it \"works\" do end\nend\n"

      expect(findings(text).first.problem).to include("attach to examples, never to groups")
      expect(findings(text).first.problem).to include("directly above")
    end
  end

  describe ".unreachable_findings_in_file" do
    # @intent: { entity: "Scanner", action: "read a missing file", behavior: "asking for unreachable findings on a path that does not exist returns an empty list rather than raising", layer: "unit" }
    it "contributes nothing for a file that cannot be read" do
      expect(described_class.unreachable_findings_in_file("/nonexistent/order_spec.rb")).to eq([])
    end
  end
end
