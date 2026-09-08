# frozen_string_literal: true

# May be required before minitest (the README's `-rminitest/specguard_plugin` path):
# load real minitest, never a bare stub — under discovery the require is a no-op.
require "minitest"

# Minitest's plugin discovery point. Minitest loads every `minitest/*_plugin.rb`
# it can find on the load path (`Minitest.load_plugins` → `Gem.find_files`), so
# a gem providing this file needs no require in the consumer's spec files —
# putting `gem "specguard-ruby"` in the Gemfile is the whole integration.
#
# This file exists to be FOUND; the reporter itself lives at
# `specguard/minitest/reporter` so it can be required explicitly (the
# deterministic path CI should use, for the same reason the RSpec formatter is
# registered by flags rather than magic: what posts your telemetry should be
# visible in the command that ran the tests).
#
# The hook name `plugin_specguard_init` is Minitest's convention: everything
# between `plugin_` and `_init` is the plugin's name. `Minitest.reporter` is
# the live CompositeReporter at this point — Minitest assigns it before
# initializing plugins precisely so plugins can append to it — and appending
# keeps the default Summary/Progress reporters untouched, so the suite's own
# output looks exactly as it did without telemetry.
module Minitest
  def self.plugin_specguard_init(_options)
    require "specguard/minitest/reporter"
    reporter << SpecGuard::Minitest::Reporter.new
  end
end
