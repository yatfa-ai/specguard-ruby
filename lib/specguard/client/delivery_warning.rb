# frozen_string_literal: true

module SpecGuard
  module Client
    # The two clauses that finish a delivery-failure warning line, shared by
    # the RSpec formatter and the Minitest reporter.
    #
    # Both clients print the same sentence after their own prefix and status
    # clause: where the run ended up, and (when it was saved) the command that
    # gets it back. They used to carry two inline copies kept equal
    # "word-for-word" by hand, and the pair had already been co-edited in
    # separate commits (SPGD-1139, SPGD-1413). One definition here means a
    # wording change cannot reach one client and miss the other.
    #
    # What stays in each client: the prefix, the warning budget (`@warned`),
    # and the `append` that decides whether `error` is nil. Those differ by
    # design; only the clause text is shared.
    module DeliveryWarning
      module_function

      # Report, not promise. Composed after the write so it can tell the
      # operator which of the two things actually happened. `error` is the
      # client's `append` answer: `nil` means the queue took the run (the
      # success arm, {#replay_clause}); anything else means both sinks are
      # gone and the run really is lost (SPGD-1413).
      def sink_clause(path, error)
        return replay_clause(path) if error.nil?

        "The replay queue #{path} could not be written either " \
          "(#{error.class}: #{error.message}), so this run's telemetry was lost."
      end

      # The success arm (SPGD-1139): where the run sits AND the command that
      # gets it back, fix-the-delivery first and replay after — the order the
      # ingest CLI's own doctrine describes. The lost-run arm deliberately
      # names no command: with no queue written there is nothing to replay.
      def replay_clause(path)
        "Falling back to #{path}; the test run is unaffected. " \
          "Once the delivery is fixed, replay this run with: bundle exec specguard-ingest #{path}"
      end
    end
  end
end
