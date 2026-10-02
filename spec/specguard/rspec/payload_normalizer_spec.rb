# frozen_string_literal: true

RSpec.describe SpecGuard::Client::PayloadNormalizer do
  def normalize(raw)
    described_class.normalize(raw)
  end

  def round_trip(raw)
    JSON.parse(normalize(raw))
  end

  describe "PROTOCOL.md §1's three equivalent forms" do
    # @intent: { entity: "PayloadNormalizer", action: "pass strict JSON through", behavior: "a payload already in strict JSON form is returned byte-identically with no rewriting", layer: "unit" }
    it "passes strict JSON through unchanged" do
      raw = '{ "entity": "Order", "layer": "request" }'

      expect(normalize(raw)).to eq(raw)
    end

    # @intent: { entity: "PayloadNormalizer", action: "convert single quotes", behavior: "single-quoted keys and string values are requoted to double quotes and parse to the same object strict JSON would", layer: "unit" }
    it "converts single-quoted keys and strings" do
      expect(round_trip("{ 'entity': 'Order' }")).to eq("entity" => "Order")
    end

    # @intent: { entity: "PayloadNormalizer", action: "quote bare keys", behavior: "unquoted keys gain double quotes while their values stay intact", layer: "unit" }
    it "quotes unquoted keys" do
      expect(round_trip('{entity:"Order",action:"checkout"}')).to eq("entity" => "Order", "action" => "checkout")
    end

    # @intent: { entity: "PayloadNormalizer", action: "tolerate loose whitespace", behavior: "arbitrary spacing around braces, keys and colons normalizes away to the same parsed object", layer: "unit" }
    it "tolerates arbitrary whitespace, including between a key and its colon" do
      expect(round_trip("{  entity   :   'Order'  }")).to eq("entity" => "Order")
    end

    # @intent: { entity: "PayloadNormalizer", action: "equate the three forms", behavior: "the strict, single-quoted and compact forms of one payload all normalize to one identical parsed object", layer: "unit" }
    it "produces identical output for all three forms" do
      results = [
        round_trip('{ "entity": "Order", "layer": "request" }'),
        round_trip("{ entity: 'Order', layer: 'request' }"),
        round_trip('{entity:"Order",layer:"request"}')
      ]

      expect(results.uniq.length).to eq(1)
    end
  end

  describe "quoted content is never rewritten" do
    # This is the property that makes the scanner a scanner. Each of these
    # would be corrupted by a regex substitution over the whole payload.
    # @intent: { entity: "PayloadNormalizer", action: "preserve quoted content", behavior: "a colon inside a double-quoted value survives normalization untouched", layer: "unit" }
    it "leaves a colon inside a value alone" do
      expect(round_trip('{behavior: "returns 402: payment required"}'))
        .to eq("behavior" => "returns 402: payment required")
    end

    # @intent: { entity: "PayloadNormalizer", action: "preserve quoted content", behavior: "a comma inside a double-quoted value survives normalization untouched", layer: "unit" }
    it "leaves a comma inside a value alone" do
      expect(round_trip('{behavior: "sums prices, then applies the discount"}'))
        .to eq("behavior" => "sums prices, then applies the discount")
    end

    # @intent: { entity: "PayloadNormalizer", action: "preserve quoted content", behavior: "a word that looks like a key inside a quoted value is never requoted or rewritten", layer: "unit" }
    it "leaves a word that looks like a key inside a value alone" do
      expect(round_trip('{behavior: "the entity: field is required"}'))
        .to eq("behavior" => "the entity: field is required")
    end

    # @intent: { entity: "PayloadNormalizer", action: "preserve quoted content", behavior: "braces inside a double-quoted value survive normalization rather than truncating the payload", layer: "unit" }
    it "leaves braces inside a value alone" do
      expect(round_trip('{behavior: "renders the {error} slot"}'))
        .to eq("behavior" => "renders the {error} slot")
    end

    # @intent: { entity: "PayloadNormalizer", action: "preserve quoted content", behavior: "an apostrophe inside a double-quoted value passes through without terminating the string", layer: "unit" }
    it "leaves an apostrophe inside a double-quoted value alone" do
      expect(round_trip(%({behavior: "the gateway's reason"}))).to eq("behavior" => "the gateway's reason")
    end
  end

  describe "trailing commas" do
    # @intent: { entity: "PayloadNormalizer", action: "drop trailing commas", behavior: "a comma left before the closing brace of an object is removed before parsing", layer: "unit" }
    it "drops a trailing comma before }" do
      expect(round_trip("{entity: 'Order', }")).to eq("entity" => "Order")
    end

    # @intent: { entity: "PayloadNormalizer", action: "drop trailing commas", behavior: "a comma left before the closing bracket of an array is removed before parsing", layer: "unit" }
    it "drops a trailing comma before ]" do
      expect(round_trip("{preconditions: ['a', ]}")).to eq("preconditions" => ["a"])
    end

    # @intent: { entity: "PayloadNormalizer", action: "keep separating commas", behavior: "a comma that separates two members of the object survives normalization", layer: "unit" }
    it "keeps a comma that separates members" do
      expect(round_trip("{a: 'x', b: 'y'}")).to eq("a" => "x", "b" => "y")
    end

    # @intent: { entity: "PayloadNormalizer", action: "keep quoted commas", behavior: "a comma and brace together inside a quoted value are preserved even though the same pair ends the object outside a string", layer: "unit" }
    it "keeps a comma inside a quoted value even when followed by a brace" do
      expect(round_trip('{behavior: "a, }"}')).to eq("behavior" => "a, }")
    end
  end

  describe ".requote" do
    # @intent: { entity: "PayloadNormalizer", action: "requote escaped quotes", behavior: "a backslash-escaped single quote is unescaped on the way to double quotes since it is meaningless in JSON", layer: "unit" }
    it "unescapes \\' — it is meaningless in JSON" do
      expect(described_class.requote("card\\'s")).to eq('"card\'s"')
    end

    # @intent: { entity: "PayloadNormalizer", action: "requote escaped quotes", behavior: "a double quote inside a single-quoted value is escaped so the requoted string stays parseable", layer: "unit" }
    it "escapes a double quote so the re-emitted string stays valid" do
      expect(round_trip(%q({behavior: 'says "hi"'}))).to eq("behavior" => 'says "hi"')
    end

    # @intent: { entity: "PayloadNormalizer", action: "preserve other escapes", behavior: "escape sequences other than the single-quote form pass through verbatim to the parsed value", layer: "unit" }
    it "preserves every other escape verbatim" do
      expect(round_trip(%q({behavior: 'a\nb'}))).to eq("behavior" => "a\nb")
    end

    # @intent: { entity: "PayloadNormalizer", action: "preserve escaped backslashes", behavior: "an escaped backslash round-trips to a single backslash in the parsed value", layer: "unit" }
    it "preserves an escaped backslash" do
      expect(round_trip(%q({behavior: 'a\\\\b'}))).to eq("behavior" => "a\\b")
    end

    # @intent: { entity: "PayloadNormalizer", action: "bound the scan", behavior: "a string ending in a lone trailing backslash is requoted without running off the end or raising", layer: "unit" }
    it "handles a trailing lone backslash without running off the end" do
      expect { described_class.requote("abc\\") }.not_to raise_error
    end
  end

  describe "non-string values" do
    # @intent: { entity: "PayloadNormalizer", action: "leave typed values alone", behavior: "numbers, booleans and null in value position parse to their JSON types rather than becoming strings", layer: "unit" }
    it "leaves numbers, booleans and null alone" do
      expect(round_trip("{count: 3, ok: true, extra: null}"))
        .to eq("count" => 3, "ok" => true, "extra" => nil)
    end

    # `true` in *key* position is a bare word like any other, so it is quoted;
    # in value position it must stay a JSON literal.
    # @intent: { entity: "PayloadNormalizer", action: "leave typed values alone", behavior: "a bare true in value position stays a JSON literal while the same word in key position would be quoted", layer: "unit" }
    it "does not quote a bare true in value position" do
      expect(normalize("{ok: true}")).to eq('{"ok": true}')
    end
  end

  # @intent: { entity: "PayloadNormalizer", action: "reject unterminated strings", behavior: "a payload whose string literal never closes raises ScanError instead of returning a broken string", layer: "unit" }
  it "raises on an unterminated string literal" do
    expect { normalize("{entity: 'Order}") }.to raise_error(SpecGuard::Client::ScanError)
  end
end
