# frozen_string_literal: true

require "tmpdir"
require "fileutils"
require "open3"
require "specguard/client/path_root"

# SPGD-2109. Every fixture here is a real `git init` repository with a real
# subdirectory: the behaviour under test is what `git rev-parse
# --show-toplevel` says about a directory, which a stub of the probe could
# only restate. The working directory is passed in, never `Dir.chdir`ed to,
# so the examples cannot be moved by (or move) anything else in the suite.
RSpec.describe SpecGuard::Client::PathRoot do
  around do |example|
    Dir.mktmpdir("specguard-path-root") do |dir|
      @tmp = File.realpath(dir)
      example.run
    end
  end

  def git_init(dir)
    FileUtils.mkdir_p(dir)
    _out, _err, status = Open3.capture3("git", "init", "-q", dir)
    raise "git init failed" unless status.success?
  end

  describe ".resolve" do
    it "answers the git toplevel when the working directory is a package subdirectory" do
      git_init(@tmp)
      pkg = File.join(@tmp, "gems", "a")
      FileUtils.mkdir_p(pkg)

      expect(described_class.resolve(pkg)).to eq(@tmp)
    end

    it "answers the working directory itself, unchanged, when it is the toplevel" do
      git_init(@tmp)

      expect(described_class.resolve(@tmp)).to eq(@tmp)
    end

    it "answers the working directory when it is not inside a repository" do
      plain = File.join(@tmp, "plain")
      FileUtils.mkdir_p(plain)
      # A ceiling at the fixture, so a repository above the tmpdir on an odd
      # host cannot adopt it.
      allow(Open3).to receive(:capture3).and_wrap_original do |orig, *args, **opts|
        orig.call({ "GIT_CEILING_DIRECTORIES" => @tmp }, *args, **opts)
      end

      expect(described_class.resolve(plain)).to eq(plain)
    end

    it "answers the working directory when git is not installed" do
      git_init(@tmp)
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

      expect(described_class.resolve(@tmp)).to eq(@tmp)
    end

    it "answers the working directory when the reported toplevel does not contain it" do
      git_init(@tmp)
      elsewhere = File.join(@tmp, "elsewhere")
      FileUtils.mkdir_p(elsewhere)
      allow(described_class).to receive(:toplevel).and_return(File.join(@tmp, "gems", "a"))

      expect(described_class.resolve(elsewhere)).to eq(elsewhere)
    end

    it "keeps the spelling of a symlinked working directory, not the real path" do
      git_init(File.join(@tmp, "real"))
      pkg = File.join(@tmp, "real", "gems", "a")
      FileUtils.mkdir_p(pkg)
      FileUtils.ln_s(File.join(@tmp, "real"), File.join(@tmp, "link"))
      linked_pkg = File.join(@tmp, "link", "gems", "a")

      # `git` reports the physical toplevel; the paths a framework builds
      # through the symlink start with the symlink spelling, so that is the
      # spelling the root must come back in.
      expect(described_class.resolve(linked_pkg)).to eq(File.join(@tmp, "link"))
    end
  end

  describe ".prefix" do
    it "is empty when the root is the working directory" do
      expect(described_class.prefix("/r", "/r")).to eq("")
    end

    it "is the working directory relative to the root" do
      expect(described_class.prefix("/r/gems/a", "/r")).to eq("gems/a")
    end
  end

  describe ".rebase" do
    it "returns the path untouched when the roots coincide" do
      expect(described_class.rebase("spec/x_spec.rb", root: "/r", prefix: "")).to eq("spec/x_spec.rb")
      expect(described_class.rebase("/r/spec/x_spec.rb", root: "/r", prefix: "")).to eq("/r/spec/x_spec.rb")
    end

    it "prefixes a cwd-relative path with the working directory's place under the root" do
      expect(described_class.rebase("spec/x_spec.rb", root: "/r", prefix: "gems/a")).to eq("gems/a/spec/x_spec.rb")
    end

    it "resolves a relative path that climbs to a sibling package" do
      expect(described_class.rebase("../b/spec/x_spec.rb", root: "/r", prefix: "gems/a"))
        .to eq("gems/b/spec/x_spec.rb")
    end

    it "keeps a relative path that climbs out of the root as it was" do
      expect(described_class.rebase("../../../x_spec.rb", root: "/r", prefix: "gems/a")).to eq("../../../x_spec.rb")
    end

    it "strips the root from an absolute path under it" do
      expect(described_class.rebase("/r/gems/b/spec/x_spec.rb", root: "/r", prefix: "gems/a"))
        .to eq("gems/b/spec/x_spec.rb")
    end

    it "keeps an absolute path outside the root" do
      expect(described_class.rebase("/elsewhere/x_spec.rb", root: "/r", prefix: "gems/a")).to eq("/elsewhere/x_spec.rb")
    end
  end
end
