# frozen_string_literal: true

require "open3"

# The load-time separation between the gem's two halves.
#
# `specguard-ruby.gemspec` declares exactly one runtime dependency —
# `json`. `rspec` is a **development** gem here, listed only in the
# Gemfile. `bin/specguard-lint` loads `specguard/rspec`, so anyone who installed
# this gem purely to lint annotations must be able to load that on a machine
# with no RSpec at all: their CI lint step may well be a `gem install` in a
# container that never runs a test.
#
# That makes "does `require "specguard/rspec"` pull in `rspec/core`?" a real
# packaging contract rather than a stylistic preference, and one that a single
# stray `require_relative "rspec/formatter"` at the bottom of lib/specguard/rspec.rb
# would break invisibly — invisibly, because in *this* repo RSpec is always
# present, so every other spec would keep passing.
#
# Hence a subprocess: it is the only way to observe a load path that has not
# already been contaminated by the suite currently running.
RSpec.describe "the gem's load boundary" do
  # A method rather than a constant: a bare `LIB = ...` inside an
  # `RSpec.describe` block assigns at the lexical scope, which is top level.
  def lib_dir
    File.expand_path("../../../lib", __dir__)
  end

  # @return [[String, String, Integer]] stdout, stderr and the exit status of a
  #   fresh interpreter that has been handed nothing but our lib/ directory.
  def load_in_fresh_ruby(source)
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, "-I", lib_dir, "-e", source)
    [stdout, stderr, status.exitstatus]
  end

  # Criterion 7.
  describe "require \"specguard/rspec\" — the linter's entry point" do
    subject(:result) do
      load_in_fresh_ruby(<<~RUBY)
        require "specguard/rspec"
        puts(defined?(::RSpec::Core) ? "rspec-core DEFINED" : "rspec-core absent")
        puts "loaded_features=\#{$LOADED_FEATURES.grep(%r{/rspec/core}).length}"
        puts "linter=\#{SpecGuard::RSpec::CLI.name}"
        puts(defined?(SpecGuard::RSpec::Transport) ? "transport DEFINED" : "transport absent")
        puts(defined?(SpecGuard::RSpec::Configuration) ? "configuration DEFINED" : "configuration absent")
      RUBY
    end

    let(:stdout) { result[0] }

    # @intent: { entity: "gem load boundary", action: "require the linter half", behavior: "a fresh interpreter with only the gem lib on the load path requires specguard/rspec and exits zero", layer: "integration" }
    it "loads without error" do
      expect(result[2]).to eq(0), "stderr was: #{result[1]}"
    end

    # @intent: { entity: "gem load boundary", action: "require the linter half", behavior: "requiring the linter entry point leaves the RSpec::Core constant undefined in the fresh interpreter", layer: "integration" }
    it "does not define RSpec::Core" do
      expect(stdout).to include("rspec-core absent")
    end

    # The stronger form: not merely "the constant is missing" but "not one file
    # of rspec-core was read", which also catches a partial require.
    # @intent: { entity: "gem load boundary", action: "require the linter half", behavior: "not a single rspec-core file enters loaded_features, catching a partial require the constant probe would miss", layer: "integration" }
    it "does not load a single file of rspec-core" do
      expect(stdout).to include("loaded_features=0")
    end

    # @intent: { entity: "gem load boundary", action: "require the linter half", behavior: "the linter chain resolves to the CLI constant, so the entry point is whole without the test framework", layer: "integration" }
    it "still gives the linter everything it needs" do
      expect(stdout).to include("linter=SpecGuard::RSpec::CLI")
    end

    # Criterion 8. The transport chain belongs to the formatter half and must
    # stay there. `transport.rb` requires `configuration.rb`, so a stray
    # `require_relative "transport"` in lib/specguard/rspec.rb would drag both
    # onto the linter's load path — and every other spec would keep passing,
    # because in *this* repo everything is present anyway. What the linter must
    # not gain is a reason to fail: it is installed on machines with no test
    # framework, and every file it does not need is a file that can be missing.
    # @intent: { entity: "gem load boundary", action: "require the linter half", behavior: "the formatter half transport and configuration constants stay absent from the linter load path", layer: "integration" }
    it "does not bring the formatter's transport with it" do
      expect(stdout).to include("transport absent")
      expect(stdout).to include("configuration absent")
    end
  end

  # Criterion 8, end to end rather than by constant: the linter's real
  # entrypoint, in an interpreter that has never heard of RSpec, still returning
  # the exit code the 0/1/2 contract promises. `--version` is used because it is
  # the one invocation that needs no fixture on disk, and it still exercises the
  # whole `require "specguard/rspec"` → `CLI#run` chain that the bin is.
  describe "bin/specguard-lint, on a machine with no RSpec" do
    subject(:result) do
      stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, File.expand_path("../../../bin/specguard-lint", __dir__), "--version"
      )
      [stdout, stderr, status.exitstatus]
    end

    # @intent: { entity: "specguard-lint executable", action: "run without RSpec installed", behavior: "the bin script answers --version with exit zero in an interpreter that has never heard of RSpec", layer: "integration" }
    it "runs and exits 0" do
      expect(result[2]).to eq(0), "stderr was: #{result[1]}"
    end

    # @intent: { entity: "specguard-lint executable", action: "run without RSpec installed", behavior: "the version output reaches stdout, proving the run traversed the full require chain into the CLI", layer: "integration" }
    it "reports the gem's version, so it really reached the CLI" do
      expect(result[0]).to include(SpecGuard::RSpec::VERSION)
    end

    # @intent: { entity: "specguard-lint executable", action: "run without RSpec installed", behavior: "stderr stays empty on the way through require and option parsing", layer: "integration" }
    it "does not warn about anything on the way" do
      expect(result[1]).to be_empty
    end
  end

  describe "require \"specguard/rspec/formatter\" — the opt-in half" do
    subject(:result) do
      load_in_fresh_ruby(<<~RUBY)
        require "specguard/rspec/formatter"
        puts "formatter=\#{SpecGuard::RSpecFormatter.name}"
        puts "superclass=\#{SpecGuard::RSpecFormatter.superclass.name}"
        puts "configurable=\#{SpecGuard::RSpec.configuration.output_path}"
        puts "transport=\#{SpecGuard::RSpec::Transport.name}"
        puts "path=\#{SpecGuard::RSpec::Transport::PATH}"
      RUBY
    end

    let(:stdout) { result[0] }

    # Standalone: it must not assume the linter half was required first, or the
    # documented one-line `.rspec` opt-in would only work by accident.
    # @intent: { entity: "gem load boundary", action: "require the formatter half", behavior: "requiring the formatter file alone, without the linter half, exits zero in the fresh interpreter", layer: "integration" }
    it "loads on its own, without specguard/rspec having been required" do
      expect(result[2]).to eq(0), "stderr was: #{result[1]}"
      expect(stdout).to include("formatter=SpecGuard::RSpecFormatter")
    end

    # The constant-resolution trap, observed from outside: inside `module
    # SpecGuard`, an unqualified `RSpec::Core` resolves to `SpecGuard::RSpec::Core`.
    # If the `::` qualification were ever dropped, this require would die with
    # `NameError: uninitialized constant SpecGuard::RSpec::Core`.
    # @intent: { entity: "gem load boundary", action: "require the formatter half", behavior: "the formatter constant resolves to a subclass of the real RSpec BaseFormatter, escaping the SpecGuard::RSpec namespace trap", layer: "integration" }
    it "subclasses the real RSpec's BaseFormatter" do
      expect(stdout).to include("superclass=RSpec::Core::Formatters::BaseFormatter")
    end

    # @intent: { entity: "gem load boundary", action: "require the formatter half", behavior: "the configuration object comes with the formatter require, defaulting its output path", layer: "integration" }
    it "brings the configuration with it" do
      expect(stdout).to include("configurable=log/test_results.jsonl")
    end

    # The other side of the boundary: the formatter half must arrive complete.
    # `--require specguard/rspec/formatter` in a project's `.rspec` is the whole
    # of the documented opt-in, so anything the run needs at `close` has to be
    # on this one chain.
    # @intent: { entity: "gem load boundary", action: "require the formatter half", behavior: "the transport constant and its ingest path arrive on the same require chain the documented opt-in uses", layer: "integration" }
    it "brings the transport with it, so close has something to POST with" do
      expect(stdout).to include("transport=SpecGuard::RSpec::Transport")
      expect(stdout).to include("path=/api/v1/ingest")
    end
  end
end
