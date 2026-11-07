# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"
require "json"
require "stringio"
require "specguard/rspec/formatter"
require "minitest"
require "specguard/minitest/reporter"
require "specguard/client/configuration"

require_relative "../support/validator_stub"

# SPGD-2109: a run started from a package subdirectory of a monorepo ships
# repo-relative `file_path` / `spec_file_path` / `id`, so two packages holding
# same-named specs no longer collide on the platform's per-run upsert.
#
# Fixtures are a real `git init` repository with real package subdirectories
# (the shared moving-cwd fixtures of the older specs cannot see a git root).
# Each arm clears the class-level memos before constructing, so what binds is
# that arm's own working directory and never a value an earlier example left.
RSpec.describe "monorepo subdirectory runs" do
  # Methods, not constants: a constant assigned in an `RSpec.describe` block
  # lands at top level and collides with sibling specs' own `LIB`.
  def lib_dir = File.expand_path("../../lib", __dir__)
  def rspec_exe = Gem.bin_path("rspec-core", "rspec")

  def util_spec = <<~RUBY
    RSpec.describe "util" do
      it "adds" do
        expect(1 + 1).to eq(2)
      end
    end
  RUBY

  around do |example|
    Dir.mktmpdir("specguard-monorepo") do |dir|
      @root = File.realpath(dir)
      _out, _err, status = Open3.capture3("git", "init", "-q", @root)
      raise "git init failed" unless status.success?

      example.run
    end
  end

  # Both clients' class-level memos, plus rspec-core's relativization regex.
  def with_isolated_memos
    holders = [SpecGuard::RSpecFormatter, SpecGuard::Minitest::Reporter]
    saved = holders.map do |klass|
      [klass, %i[@repo_root @path_root_binding].to_h do |ivar|
        [ivar, klass.instance_variable_defined?(ivar) ? [klass.instance_variable_get(ivar)] : nil]
      end]
    end
    had_regex = ::RSpec::Core::Metadata.instance_variable_defined?(:@relative_path_regex)
    previous_regex = ::RSpec::Core::Metadata.instance_variable_get(:@relative_path_regex) if had_regex
    clear = lambda do
      holders.each do |klass|
        %i[@repo_root @path_root_binding].each do |ivar|
          klass.remove_instance_variable(ivar) if klass.instance_variable_defined?(ivar)
        end
      end
      if ::RSpec::Core::Metadata.instance_variable_defined?(:@relative_path_regex)
        ::RSpec::Core::Metadata.remove_instance_variable(:@relative_path_regex)
      end
    end
    clear.call
    yield
  ensure
    clear.call
    saved.each do |klass, ivars|
      ivars.each { |ivar, boxed| klass.instance_variable_set(ivar, boxed.first) if boxed }
    end
    ::RSpec::Core::Metadata.instance_variable_set(:@relative_path_regex, previous_regex) if had_regex
  end

  # Answers an intent only for a file that resolves, from the READ root (the
  # cwd), to a real file — the property the real lookup's resolution has — and
  # records what it was asked, so "annotated specs still resolve" is measured
  # rather than assumed.
  def reading_lookup
    asked = []
    lookup = Object.new
    lookup.define_singleton_method(:asked) { asked }
    lookup.define_singleton_method(:intent_for) do |file:, line:|
      asked << file
      File.file?(File.expand_path(file, Dir.pwd)) ? { "entity" => "Util" } : nil
    end
    lookup
  end

  def example_double(file_path, rerun_file_path: file_path, id: "#{rerun_file_path}[1:1]")
    instance_double(
      RSpec::Core::Example,
      full_description: "util adds", id: id,
      metadata: { file_path: file_path, line_number: 2, rerun_file_path: rerun_file_path },
      execution_result: instance_double(RSpec::Core::Example::ExecutionResult, run_time: 0.01, status: :passed)
    )
  end

  def rspec_rows(package, file_path, **example_options)
    dir = File.expand_path(package, @root)
    FileUtils.mkdir_p(File.join(dir, "spec"))
    File.write(File.join(dir, "spec", "util_spec.rb"), util_spec)
    lookup = reading_lookup
    rows = nil
    with_isolated_memos do
      Dir.chdir(dir) do
        formatter = SpecGuard::RSpecFormatter.new(StringIO.new, error_stream: StringIO.new, annotations: lookup)
        formatter.example_finished(
          instance_double(RSpec::Core::Notifications::ExampleNotification,
                          example: example_double(file_path, **example_options))
        )
        rows = formatter.payload["specs"]
      end
    end
    [rows, lookup]
  end

  def minitest_rows(package, absolute_file)
    dir = File.expand_path(package, @root)
    FileUtils.mkdir_p(File.join(dir, "test"))
    File.write(File.join(dir, "test", "util_test.rb"), "# test\n")
    lookup = reading_lookup
    rows = nil
    with_isolated_memos do
      Dir.chdir(dir) do
        reporter = SpecGuard::Minitest::Reporter.new(annotations: lookup, output: StringIO.new)
        result = ::Minitest::Result.new("test_adds")
        result.klass = "UtilTest"
        result.source_location = [absolute_file.call(dir), 4]
        result.time = 0.1
        result.failures = []
        reporter.record(result)
        rows = reporter.send(:payload)["specs"]
      end
    end
    [rows, lookup]
  end

  describe SpecGuard::RSpecFormatter do
    it "ships a repo-relative file_path, spec_file_path and id from a package subdirectory" do
      rows_a, = rspec_rows("gems/a", "./spec/util_spec.rb")
      rows_b, = rspec_rows("gems/b", "./spec/util_spec.rb")

      expect(rows_a.first).to include("file_path" => "gems/a/spec/util_spec.rb",
                                      "spec_file_path" => "gems/a/spec/util_spec.rb",
                                      "id" => "gems/a/spec/util_spec.rb[1:1]")
      expect(rows_b.first).to include("file_path" => "gems/b/spec/util_spec.rb",
                                      "id" => "gems/b/spec/util_spec.rb[1:1]")
    end

    it "reads annotations from the working directory, so a subdirectory run's annotated specs still resolve" do
      rows, lookup = rspec_rows("gems/a", "./spec/util_spec.rb")

      expect(lookup.asked).to eq(["spec/util_spec.rb"])
      expect(rows.first["status"]).to eq("annotated")
    end

    it "relativizes an absolute spec path under the working directory the same way" do
      rows, = rspec_rows("gems/a", File.join(@root, "gems/a/spec/util_spec.rb"),
                         rerun_file_path: File.join(@root, "gems/a/spec/util_spec.rb"))

      expect(rows.first).to include("file_path" => "gems/a/spec/util_spec.rb",
                                    "id" => "gems/a/spec/util_spec.rb[1:1]")
    end

    it "relativizes a sibling package's spec, outside the working directory but inside the repository" do
      rows, = rspec_rows("gems/a", File.join(@root, "gems/b/spec/util_spec.rb"),
                         rerun_file_path: File.join(@root, "gems/b/spec/util_spec.rb"))

      expect(rows.first).to include("file_path" => "gems/b/spec/util_spec.rb",
                                    "id" => "gems/b/spec/util_spec.rb[1:1]")
    end

    it "keeps an absolute path for a spec outside the repository" do
      rows, = rspec_rows("gems/a", "/somewhere/else/util_spec.rb",
                         rerun_file_path: "/somewhere/else/util_spec.rb")

      expect(rows.first).to include("file_path" => "/somewhere/else/util_spec.rb",
                                    "id" => "/somewhere/else/util_spec.rb[1:1]")
    end

    it "is byte-identical to today from the repository root" do
      rows, = rspec_rows(".", "./spec/util_spec.rb")

      expect(rows.first).to include("file_path" => "spec/util_spec.rb",
                                    "spec_file_path" => "spec/util_spec.rb",
                                    "id" => "./spec/util_spec.rb[1:1]")
    end

    it "is byte-identical to today outside a git repository" do
      allow(SpecGuard::Client::PathRoot).to receive(:toplevel).and_return(nil)

      rows, = rspec_rows("gems/a", "./spec/util_spec.rb")

      expect(rows.first).to include("file_path" => "spec/util_spec.rb",
                                    "id" => "./spec/util_spec.rb[1:1]")
    end
  end

  describe SpecGuard::Minitest::Reporter do
    it "ships a repo-relative file_path and id from a package subdirectory, distinct per package" do
      rows_a, = minitest_rows("gems/a", ->(dir) { File.join(dir, "test/util_test.rb") })
      rows_b, = minitest_rows("gems/b", ->(dir) { File.join(dir, "test/util_test.rb") })

      expect(rows_a.first).to include("file_path" => "gems/a/test/util_test.rb",
                                      "spec_file_path" => "gems/a/test/util_test.rb",
                                      "id" => "gems/a/test/util_test.rb:4")
      expect(rows_b.first).to include("file_path" => "gems/b/test/util_test.rb",
                                      "id" => "gems/b/test/util_test.rb:4")
    end

    it "reads annotations from the working directory, so a subdirectory run's annotated tests still resolve" do
      rows, lookup = minitest_rows("gems/a", ->(dir) { File.join(dir, "test/util_test.rb") })

      expect(lookup.asked).to eq(["test/util_test.rb"])
      expect(rows.first["status"]).to eq("annotated")
    end

    it "keeps an absolute path for a test outside the repository" do
      rows, = minitest_rows("gems/a", ->(_dir) { "/somewhere/else/util_test.rb" })

      expect(rows.first).to include("file_path" => "/somewhere/else/util_test.rb")
    end

    it "is byte-identical to today from the repository root" do
      rows, = minitest_rows(".", ->(dir) { File.join(dir, "test/util_test.rb") })

      expect(rows.first).to include("file_path" => "test/util_test.rb", "id" => "test/util_test.rb:4")
    end

    it "is byte-identical to today outside a git repository" do
      allow(SpecGuard::Client::PathRoot).to receive(:toplevel).and_return(nil)

      rows, = minitest_rows("gems/a", ->(dir) { File.join(dir, "test/util_test.rb") })

      expect(rows.first).to include("file_path" => "test/util_test.rb", "id" => "test/util_test.rb:4")
    end
  end

  # The in-process arms above build examples by hand; this one lets real
  # RSpec compute `example.id` and `metadata[:file_path]` in two real package
  # directories, which is the collision the ticket describes.
  describe "a real rspec run in each package" do
    def run_package(package)
      dir = File.expand_path(package, @root)
      FileUtils.mkdir_p(File.join(dir, "spec"))
      File.write(File.join(dir, "spec", "util_spec.rb"), util_spec)
      env = SpecGuard::Client::Configuration.constants.grep(/_KEYS\z/)
                                            .flat_map { |k| SpecGuard::Client::Configuration.const_get(k) }
                                            .to_h { |k| [k, nil] }
                                            .merge(ValidatorStub.stub_env)
                                            .merge("SPECGUARD_VALIDATE_INTENT" => ValidatorStub.install_stubbable)
      _out, err, status = Open3.capture3(
        env, RbConfig.ruby, "-I", lib_dir, rspec_exe,
        "--require", "specguard/rspec/formatter", "--format", "SpecGuard::RSpecFormatter",
        "spec", chdir: dir
      )
      raise "rspec failed: #{err}" unless status.success?

      JSON.parse(File.readlines(File.join(dir, "log", "test_results.local.jsonl")).last)["specs"].first
    end

    it "ships distinct file_path and id for same-named specs in two packages" do
      a = run_package("gems/a")
      b = run_package("gems/b")

      expect([a["file_path"], a["id"]]).to eq(["gems/a/spec/util_spec.rb", "gems/a/spec/util_spec.rb[1:1]"])
      expect([b["file_path"], b["id"]]).to eq(["gems/b/spec/util_spec.rb", "gems/b/spec/util_spec.rb[1:1]"])
    end
  end
end
