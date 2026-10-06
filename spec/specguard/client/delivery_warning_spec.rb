# frozen_string_literal: true

require "specguard/client/delivery_warning"

# The two clauses that finish a delivery-failure warning line for BOTH clients
# (RSpec formatter, Minitest reporter). The client specs only pin fragments of
# this sentence; this file owns its exact wording, so a one-line reword of the
# shared definition goes red here instead of passing both client suites.
RSpec.describe SpecGuard::Client::DeliveryWarning do
  let(:path) { "log/test_results.jsonl" }

  describe ".sink_clause" do
    it "names the queue, the error class and message, and says the run's telemetry was lost when the queue could not be written either" do
      expect(described_class.sink_clause(path, Errno::EACCES.new("probe"))).to eq(
        "The replay queue log/test_results.jsonl could not be written either " \
        "(Errno::EACCES: Permission denied - probe), so this run's telemetry was lost."
      )
    end

    it "is the replay clause when the queue took the run (no error)" do
      expect(described_class.sink_clause(path, nil)).to eq(described_class.replay_clause(path))
    end
  end

  describe ".replay_clause" do
    it "says where the run sits, that the run is unaffected, and fix-the-delivery-then-replay with the full ingest command" do
      expect(described_class.replay_clause(path)).to eq(
        "Falling back to log/test_results.jsonl; the test run is unaffected. " \
        "Once the delivery is fixed, replay this run with: bundle exec specguard-ingest log/test_results.jsonl"
      )
    end
  end
end
