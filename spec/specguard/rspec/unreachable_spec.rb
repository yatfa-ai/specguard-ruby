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

    # @intent: { entity: "Scanner", action: "flag payload calls", behavior: "a group line whose payload contains the sequence ; it( is still flagged, the block-opener anchor rejecting payloads on its own so only the token boundary can exempt the line", layer: "unit" }
    it "flags a group line whose payload contains ; it(" do
      # The only payload class that actually exercises guard Y: a payload
      # carrying the literal `; it(` sequence, which guard X accepts INSIDE a
      # code side. If the exemption ever reads past the `@intent:` token
      # again (guard Y violated, e.g. code = whole line), EXAMPLE_ON_LINE
      # matches the payload, the line is wrongly exempted and this example
      # fails with 0 findings — unlike the `it's` payload above, which stays
      # green under that same violation.
      text = <<~RUBY
        describe "a group" do # @intent: { entity: "A", behavior: "no-op; it( is never called", layer: "unit" }
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

  describe ".unreachable_findings_in_text (SPGD-1554: the separated-annotation pass)" do
    def findings(text)
      described_class.unreachable_findings_in_text(text, file: "order_spec.rb")
    end

    # @intent: { entity: "Scanner", action: "detect separated annotations", behavior: "a comment annotation, one blank line, then an example is flagged on the annotation line with kind unreachable", layer: "unit" }
    it "flags an @intent: comment separated from its example by one blank line" do
      text = <<~RUBY
        # @intent: { entity: "Order", behavior: "decrements stock" }

        it "decrements stock" do end
      RUBY

      expect(findings(text).map(&:line)).to eq([1])
      expect(findings(text).first.kind).to eq(SpecGuard::RSpec::Finding::KIND_UNREACHABLE)
      expect(findings(text).first.problem).to include("separated from its example")
    end

    # @intent: { entity: "Scanner", action: "detect separated annotations", behavior: "a comment annotation, one ordinary comment line, then an example is flagged the same as the blank interleave", layer: "unit" }
    it "flags an @intent: comment separated from its example by one ordinary comment line" do
      text = <<~RUBY
        # @intent: { entity: "Order", behavior: "decrements stock" }
        # rubocop:disable Style/Foo
        it "decrements stock" do end
      RUBY

      expect(findings(text).map(&:line)).to eq([1])
    end

    # @intent: { entity: "Scanner", action: "spare the direct form", behavior: "an annotation directly above its example is not flagged by the separated pass", layer: "unit" }
    it "does not flag the direct form" do
      text = <<~RUBY
        # @intent: { entity: "Order", behavior: "decrements stock" }
        it "decrements stock" do end
      RUBY

      expect(findings(text)).to be_empty
    end

    # @intent: { entity: "Scanner", action: "not double-flag stacked pairs", behavior: "a stacked pair directly above an example yields exactly the upper-line flag from the stacked pass, not a doubled finding", layer: "unit" }
    it "does not double-flag a stacked pair above its example" do
      text = <<~RUBY
        # @intent: { entity: "A" }
        # @intent: { entity: "B" }
        it "works" do end
      RUBY

      expect(findings(text).map(&:line)).to eq([1])
      expect(findings(text).first.problem).to eq(described_class::UNREACHABLE_ANNOTATION)
    end

    # @intent: { entity: "Scanner", action: "spare code interleaves", behavior: "an annotation, a blank line, a code line, then an example is not flagged because a code interleave is out of scope", layer: "unit" }
    it "does not flag a code-line interleave beyond the one-line window" do
      text = <<~RUBY
        # @intent: { entity: "A" }

        x = 1
        it "works" do end
      RUBY

      expect(findings(text)).to be_empty
    end

    # @intent: { entity: "Scanner", action: "spare two-line windows", behavior: "an annotation followed by two blank lines then an example is not flagged because the window is exactly one intervening line", layer: "unit" }
    it "does not flag two intervening blank lines" do
      text = "# @intent: { entity: \"A\" }\n\n\nit \"works\" do end\n"

      expect(findings(text)).to be_empty
    end

    # @intent: { entity: "Scanner", action: "flag every run line", behavior: "a run of two annotations then a blank then an example flags both lines, the last included, unlike the stacked pass", layer: "unit" }
    it "flags EVERY line of a multi-line run, the last included" do
      text = <<~RUBY
        # @intent: { entity: "A" }
        # @intent: { entity: "B" }

        it "works" do end
      RUBY

      expect(findings(text).map(&:line)).to eq([1, 2])
      expect(findings(text).map(&:problem).uniq).to eq([described_class::UNREACHABLE_SEPARATED_ANNOTATION])
    end

    # @intent: { entity: "Scanner", action: "defer group targets", behavior: "an annotation, a blank line, then a describe line is not flagged because describe is not an example line", layer: "unit" }
    it "does not flag a separated annotation whose target is a describe line" do
      text = <<~RUBY
        # @intent: { entity: "A" }

        describe "a group" do
          it "works" do end
        end
      RUBY

      expect(findings(text)).to be_empty
    end

    # @intent: { entity: "Scanner", action: "respect file bounds", behavior: "an annotation followed by a blank line at end of file is not flagged", layer: "unit" }
    it "does not flag an annotation plus blank line at end of file" do
      expect(findings("# @intent: { entity: \"A\" }\n\n")).to be_empty
      expect(findings("# @intent: { entity: \"A\" }\n")).to be_empty
      expect(findings("# @intent: { entity: \"A\" }")).to be_empty
    end

    # @intent: { entity: "Scanner", action: "merge the three passes", behavior: "separated, stacked and group-line findings in one file come back merged in line order", layer: "unit" }
    it "merges with the other passes in line order" do
      text = <<~RUBY
        # @intent: { entity: "A" }

        it "one" do end
        # @intent: { entity: "B" }
        # @intent: { entity: "C" }
        it "two" do end
        context "g" do # @intent: { entity: "D", behavior: "renders the thing it names", layer: "unit" }
          it "three" do end
        end
      RUBY

      expect(findings(text).map(&:line)).to eq([1, 4, 7])
    end
  end

  describe ".unreachable_findings_in_file" do
    # @intent: { entity: "Scanner", action: "read a missing file", behavior: "asking for unreachable findings on a path that does not exist returns an empty list rather than raising", layer: "unit" }
    it "contributes nothing for a file that cannot be read" do
      expect(described_class.unreachable_findings_in_file("/nonexistent/order_spec.rb")).to eq([])
    end
  end
end
