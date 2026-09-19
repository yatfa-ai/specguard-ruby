# frozen_string_literal: true

source "https://rubygems.org"

# The client gem itself. This tree holds exactly one gemspec —
# specguard-ruby.gemspec — and the name: argument below names it explicitly.
gemspec name: "specguard-ruby"

# Development-only: spec/support/validator_stub.rb uses json_schemer to give
# ad-hoc spec fixtures REAL verdicts offline. Since SPGD-867 the gem's lib/
# never touches json_schemer — validation is the binary's job — and the
# gemspec deliberately declares no such runtime dependency.
gem "json_schemer", "~> 2.5"

gem "irb"
gem "rake", "~> 13.0"
gem "rspec", "~> 3.13"

# The Minitest adapter's own suite runs through RSpec like everything here;
# minitest itself is what that adapter drives in its integration specs.
gem "minitest", "~> 5.20"
