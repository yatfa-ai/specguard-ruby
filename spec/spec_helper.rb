# frozen_string_literal: true

require "specguard/rspec"
require "fileutils"
require "stringio"

module FixtureHelpers
  FIXTURE_ROOT = File.expand_path("fixtures", __dir__)

  def fixture_path(name)
    File.join(FIXTURE_ROOT, name)
  end

  # One of the protocol repo's `examples/` payloads, parsed. These are copies
  # of open-test-intent's own corpus, so a spec asserting on them is asserting
  # against the documents the reference validator was tuned on.
  def payload_fixture(name)
    JSON.parse(File.read(File.join(FIXTURE_ROOT, "payloads", name)))
  end

  # The `@intent:` payloads in a fixture, as written. Lets a test assert on the
  # normalizer's input without hard-coding the fixture's long annotation lines.
  def raw_payloads(path)
    SpecGuard::Client::AnnotationScanner
      .each_intent(File.read(path))
      .filter_map { |line_no, raw, problem| [line_no, raw] if problem.nil? }
  end
end

RSpec.configure do |config|
  # Enable flags like --only-failures and --next-failure
  config.example_status_persistence_file_path = ".rspec_status"

  # Disable RSpec exposing methods globally on `Module` and `main`
  config.disable_monkey_patching!

  config.expect_with :rspec do |c|
    c.syntax = :expect
  end

  config.include FixtureHelpers

  # spec/fixtures/ holds *data* that happens to be named `*_spec.rb` — it is the
  # linter's input, not examples. `.rspec` and the Rakefile both carry a
  # matching --exclude-pattern; this is the backstop for the case those miss.
  #
  # Today's two fixtures raise on load (`rails_helper`, `Order`), so a lost
  # exclusion shows up as a loud load error before this ever runs. A fixture
  # that happened to load cleanly would instead run as a *passing* empty
  # example group and silently inflate the suite — which is what this catches.
  config.before(:suite) do
    offenders = RSpec.world.example_groups.map { |g| g.metadata[:file_path] }.grep(%r{spec/fixtures/})
    raise "spec/fixtures/ was loaded as specs (#{offenders.join(', ')}) — check .rspec" if offenders.any?
  end
end
