# frozen_string_literal: true

require_relative "version"

module SpecGuard
  module Client
    # The Ruby client for SpecGuard.
    #
    # The linter is complete end to end: it finds `@intent:` annotations in
    # spec files, captures each payload string-aware, normalizes PROTOCOL.md
    # §1's permissive syntax into strict JSON, validates the result against the
    # vendored OpenTestIntent schema, and reports violations in the reference
    # tool's own grammar under the 0/1/2 exit contract (see {CLI}).
    #
    # Everything under `SpecGuard::Client` is framework-free: the RSpec
    # formatter and the Minitest reporter are the framework halves of the
    # client and both build on it. Neither is required from here — `rspec`
    # is a development dependency of this gem, not a runtime one, and
    # `bin/specguard-lint` loads this file on machines that may have no RSpec
    # at all. Requiring `rspec/core` from this chain would turn a missing test
    # framework into a broken linter. Load the formatter by its own path when
    # you want it — `require "specguard/rspec/formatter"` — and see that file
    # for the opt-in wiring.
    class Error < StandardError; end

    # A source line could not be scanned (unterminated string or object
    # literal). Internal to the scanner: it is caught and turned into a
    # {Finding}'s `problem` rather than reaching a caller.
    class ScanError < Error; end

    # The tool was invoked in a way that cannot work — `--changed` outside a git
    # repository, say. Distinct from "the annotations are bad": the exit-code
    # contract makes this a 2, and it is typed here so the CLI can map it
    # without re-deriving the distinction from an error message.
    class UsageError < Error; end

    # The Go validator backend could not produce a verdict — the binary named
    # by `SPECGUARD_VALIDATE_INTENT`, or the default binary the backend
    # resolves when that is blank, is missing, will not execute, exited with a
    # code that is not a verdict, or emitted something this cannot read as a
    # report.
    #
    # Typed separately from {UsageError} because the two are different
    # accusations ("you invoked me wrongly" vs "the tool I was told to use is
    # broken"), and rescued *beside* it in {CLI#run} because the answer to both
    # is the same and non-negotiable: exit 2, never 1. See {ValidatorBackend}.
    class ValidatorError < Error; end

    # The vendored canonical OpenTestIntent schema, copied byte-for-byte from
    # open-test-intent so this gem has **no cross-repo runtime dependency**.
    # It ships packaged (it lives under `lib/`, which the gemspec includes);
    # the spec fixtures deliberately do not, so nothing here may be
    # load-bearing at runtime.
    #
    # Since the SPGD-867 cutover nothing VALIDATES against this copy — every
    # verdict comes from the `validate-intent` binary's own compiled-in
    # schema. It survives because {ValidatorBackend}'s schema-contract check
    # digests it at runtime and refuses a binary that would enforce different
    # bytes: the two halves of the seam must keep meeting somewhere, and this
    # file is where the gem's half lives.
    SCHEMA_PATH = File.expand_path("client/schemas/open-test-intent.v1.json", __dir__).freeze
  end
end

module SpecGuard
  class << self
    # The process-wide client configuration — one object shared by the RSpec
    # formatter, the Minitest reporter and the CLIs, whatever framework a
    # consumer runs.
    #
    # Built on first use rather than at load time so that a `configure` block
    # in a `spec_helper.rb` / `test_helper.rb` and a variable exported by a CI
    # job describe the same object regardless of which the interpreter reached
    # first.
    #
    # {SpecGuard::RSpec.configure} (the documented RSpec entry point) delegates
    # here and returns this same object — there is exactly one configuration,
    # not one per entry point.
    #
    # @return [Client::Configuration]
    def configuration
      # Loaded here, not at the top of this file: the linter's chain
      # (`require "specguard/client"`) must stay free of the formatter's
      # configuration/transport half — formatter_loading_spec pins it.
      require_relative "client/configuration"
      @configuration ||= Client::Configuration.new
    end

    # Configure the client.
    #
    #   SpecGuard.configure do |config|
    #     config.branch = "release/2.0"
    #   end
    #
    # @yieldparam configuration [Client::Configuration]
    # @return [Client::Configuration] the configuration, block or no block
    def configure
      yield configuration if block_given?
      configuration
    end

    # Drop the memoized configuration so the next read re-seeds from ENV.
    # Exists for tests, and for the rare caller that changes the environment
    # after this file was loaded.
    #
    # @return [void]
    def reset_configuration!
      @configuration = nil
    end
  end
end

require_relative "client/finding"
require_relative "client/annotation_scanner"
require_relative "client/payload_normalizer"
require_relative "client/scanner"
require_relative "client/file_selector"
require_relative "client/linter"
require_relative "client/json_reporter"
require_relative "client/validator_backend"
require_relative "client/cli"
