# frozen_string_literal: true

require "json"
require "fileutils"

module SpecGuard
  module Client
    # The local JSON-line sink writer shared by the two framework clients'
    # sinks: the RSpec formatter's replay queue and local development record,
    # and the Minitest reporter's (see {Configuration#output_path} and
    # {Configuration#local_output_path}). One definition here means the write
    # — the guarded `mkdir_p`, the single append-mode write of the full line,
    # the exception-as-value contract — cannot drift between the two clients,
    # which hand-copied it until SPGD-2124 and had already been co-edited in
    # separate commits (SPGD-1413).
    #
    # What stays in each client: which sink the run warrants (`#deliver`
    # decides), and what each does with the write's answer — the formatter's
    # fall-back folds it into the delivery line its budget is already spent
    # on, the reporter's keyless branch names the configured path in its own
    # line. The write itself is shared.
    module SinkWriter
      module_function

      # Appends one line to `path`. Opened in append mode and written with a
      # single call so that two suites sharing an output path (parallel CI
      # shards, say) interleave whole runs rather than halves of one.
      #
      # `path` is passed in rather than read here, so the line a client's
      # fall-back composes and the file it describes are provably the same
      # string — a second read of a process-wide singleton could answer
      # differently and name a path nothing was written to.
      #
      # Returns the exception the write died of, or `nil` when it landed,
      # rather than warning itself or raising — the clients need the outcome
      # *in* their own sentence, and a raise here could not be folded into
      # one: it would fall through to a client's generic handler and spend
      # the run's one warning budget on a sentence this module's answer was
      # meant to replace (SPGD-1413). `Interrupt` stays deliberately outside
      # the clause, as everywhere else in these files: Ctrl-C must stay
      # Ctrl-C.
      def append(data, path)
        directory = File.dirname(path)
        FileUtils.mkdir_p(directory) unless directory == "." || File.directory?(directory)

        File.open(path, "a") { |file| file.write("#{JSON.generate(data)}\n") }
        nil
      rescue ScriptError, StandardError => e
        e
      end
    end
  end
end
