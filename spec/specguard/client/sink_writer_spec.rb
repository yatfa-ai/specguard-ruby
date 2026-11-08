# frozen_string_literal: true

require "json"
require "tmpdir"
require "specguard/client/sink_writer"

# The one write both framework clients (RSpec formatter, Minitest reporter)
# make to their sinks. The client specs pin what each does with the answer
# (the warning sentences, the budgets); this file owns the write itself, so a
# change to the contract goes red here rather than passing both client suites.
RSpec.describe SpecGuard::Client::SinkWriter do
  around do |example|
    Dir.mktmpdir("sink_writer_spec") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:dir) { @dir }
  let(:path) { File.join(dir, "log", "test_results.jsonl") }
  let(:data) { { "commit_sha" => "abc123", "specs" => [{ "id" => "a_spec.rb:1" }] } }

  describe ".append" do
    # @intent: { entity: "SinkWriter", action: "append", behavior: "a run is written as one parseable JSON line ending in a newline", layer: "unit" }
    it "appends the run as one parseable JSON line" do
      described_class.append(data, path)

      raw = File.read(path)
      expect(raw.lines.length).to eq(1)
      expect(raw).to end_with("\n")
      expect(JSON.parse(raw)).to eq(data)
    end

    # @intent: { entity: "SinkWriter", action: "append", behavior: "a second run is appended after the first rather than replacing the file", layer: "unit" }
    it "appends to an existing file rather than replacing it" do
      other = { "commit_sha" => "def456", "specs" => [] }

      described_class.append(data, path)
      described_class.append(other, path)

      expect(File.readlines(path).map { |line| JSON.parse(line) }).to eq([data, other])
    end

    # @intent: { entity: "SinkWriter", action: "append", behavior: "a missing parent directory is created", layer: "unit" }
    it "creates a missing directory" do
      nested = File.join(dir, "a", "b", "test_results.jsonl")

      described_class.append(data, nested)

      expect(JSON.parse(File.read(nested))).to eq(data)
    end

    # @intent: { entity: "SinkWriter", action: "append", behavior: "a bare filename in the working directory is written without a mkdir", layer: "unit" }
    it "writes a bare filename relative to the working directory" do
      Dir.chdir(dir) do
        expect(described_class.append(data, "test_results.jsonl")).to be_nil
        expect(JSON.parse(File.read("test_results.jsonl"))).to eq(data)
      end
    end

    # @intent: { entity: "SinkWriter", action: "report the outcome", behavior: "a landed write answers nil", layer: "unit" }
    it "returns nil on success" do
      expect(described_class.append(data, path)).to be_nil
    end

    # The fixture both client specs use: a regular file occupying the parent
    # directory's name. Unwritable for EVERY uid, unlike a `chmod` fixture that
    # root ignores — so this is correct under a root CI image.
    context "when the parent directory's name is occupied by a regular file" do
      let(:blocker) { File.join(dir, "blocker") }
      let(:sink) { File.join(blocker, "test_results.jsonl") }

      before { File.write(blocker, "not a directory") }

      # @intent: { entity: "SinkWriter", action: "report the outcome", behavior: "a failed write is returned as the exception instead of raised", layer: "unit" }
      it "returns the exception instead of raising" do
        result = nil

        expect { result = described_class.append(data, sink) }.not_to raise_error
        expect(result).to be_a(StandardError)
        expect(File.exist?(sink)).to be(false)
      end
    end

    # @intent: { entity: "SinkWriter", action: "never swallow an interrupt", behavior: "Ctrl-C raised mid-write stays Ctrl-C rather than being returned as a value", layer: "unit" }
    it "does not rescue Interrupt" do
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).with(path, "a").and_raise(Interrupt)

      expect { described_class.append(data, path) }.to raise_error(Interrupt)
    end
  end
end
