# frozen_string_literal: true

require_relative "rspec/version"
require_relative "client"

module SpecGuard
  # The RSpec-facing entry point of the gem.
  #
  # The framework-free client — scanner, linter, CLIs, configuration,
  # transport — lives under {SpecGuard::Client}; the one component that is
  # genuinely RSpec's is {SpecGuard::RSpecFormatter}
  # (`require "specguard/rspec/formatter"`). What remains here is the
  # documented `SpecGuard::RSpec.configure` entry point, kept working for
  # anybody who configures the client from a `spec_helper.rb`.
  #
  # It is a thin delegate, not a second configuration: all three methods
  # forward to {SpecGuard.configure} / {SpecGuard.configuration} /
  # {SpecGuard.reset_configuration!}, so `SpecGuard::RSpec.configure` and
  # `SpecGuard.configure` return the very same {Client::Configuration} object.
  # A Minitest consumer has no reason to say `RSpec` and should configure
  # through `SpecGuard.configure`.
  module RSpec
    class << self
      # @yieldparam configuration [Client::Configuration]
      # @return [Client::Configuration] the same object {SpecGuard.configure} returns
      def configure(&)
        SpecGuard.configure(&)
      end

      # @return [Client::Configuration]
      def configuration
        SpecGuard.configuration
      end

      # @return [void]
      def reset_configuration!
        SpecGuard.reset_configuration!
      end
    end
  end
end
