# frozen_string_literal: true

require "tmpdir"
require "open3"
require "digest"
require "rubygems/package"

# The vendored schema is now load-bearing: {SpecGuard::Client::Schema.load}
# reads it on every run, and a run that cannot read it exits 2. That makes the
# *packaging* trap real rather than theoretical — the gemspec builds
# `spec.files` from `git ls-files`, so a vendored file that was never
# `git add`ed is silently absent from the built gem, and the failure surfaces
# only in an installed gem on someone else's machine, far from its cause.
RSpec.describe "the vendored OpenTestIntent schema" do
  subject(:schema) { JSON.parse(File.read(SpecGuard::Client::SCHEMA_PATH)) }

  # @intent: { entity: "vendored OpenTestIntent schema", action: "ship inside the gem", behavior: "the schema path resolves under lib/specguard/client/schemas and the file exists on disk", layer: "unit" }
  it "ships inside lib/, which the gemspec packages" do
    expect(SpecGuard::Client::SCHEMA_PATH).to include("/lib/specguard/client/schemas/")
    expect(File).to exist(SpecGuard::Client::SCHEMA_PATH)
  end

  # @intent: { entity: "vendored OpenTestIntent schema", action: "stay tracked by git", behavior: "git ls-files names the schema, without which the gemspec would silently package a gem missing it", layer: "unit" }
  it "is tracked by git, without which it would not be packaged" do
    tracked = `git ls-files --error-unmatch #{SpecGuard::Client::SCHEMA_PATH} 2>/dev/null`

    expect(tracked.strip).not_to be_empty
  end

  # The digest of open-test-intent's schemas/open-test-intent.v1.json at the
  # `schema-v1.0` tag, the copy this file was vendored from — and the
  # same pin open-test-intent's own schema_test.go holds as CanonicalV1SHA256.
  # A byte count would not say this: any same-length edit — swapping an enum
  # member, moving a digit of `minLength` — passes a size check while changing
  # what the linter enforces.
  CANONICAL_V1_SHA256 = "3760d8f7c6694aa19ca53cd39c323d7c096ae1140be08c435cd433e77db618ee"

  # `$id` is pinned as a literal, not derived from anything, precisely because
  # the last one was wrong for the whole life of the project: it named a host
  # that never existed, and an assertion that read the value out of the file it
  # was checking would have agreed with it every single day. It now names the
  # protocol repository at a real, fetchable address for exactly these bytes.
  #
  # The tag is `schema-v1.0`, scoped to a DOCUMENT REVISION rather than to the
  # major version, and that distinction is load bearing here. PROTOCOL.md §5
  # lets v1 gain an optional field without becoming v2, so a `schema-v1` tag
  # would eventually have to either move — handing everyone who pinned it a
  # document they never pinned — or stop matching the file that names it. A
  # revision-scoped tag never faces that: an additive change cuts schema-v1.1
  # and this constant moves with it, in the same change as the digest above.
  CANONICAL_V1_ID = "https://raw.githubusercontent.com/yatfa-ai/open-test-intent/schema-v1.0/schemas/open-test-intent.v1.json"

  # @intent: { entity: "vendored OpenTestIntent schema", action: "match the canonical bytes", behavior: "the sha256 digest, id and schema dialect equal the pins from the protocol repository schema-v1.0 tag", layer: "unit" }
  it "is the canonical v1 schema, byte-for-byte" do
    expect(Digest::SHA256.file(SpecGuard::Client::SCHEMA_PATH).hexdigest).to eq(CANONICAL_V1_SHA256)
    expect(schema["$id"]).to eq(CANONICAL_V1_ID)
    expect(schema["$schema"]).to eq("http://json-schema.org/draft-07/schema#")
  end

  # @intent: { entity: "vendored OpenTestIntent schema", action: "carry the enforced constraints", behavior: "additionalProperties is false, exactly the four intent keys are required, behavior minLength is fifteen and layer lists only the four enum members", layer: "unit" }
  it "carries the constraints the linter enforces" do
    expect(schema["additionalProperties"]).to be(false)
    expect(schema["required"]).to contain_exactly("entity", "action", "behavior", "layer")
    expect(schema.dig("properties", "behavior", "minLength")).to eq(15)
    expect(schema.dig("properties", "layer", "enum")).to eq(%w[unit integration request system])
  end

  # The fixtures are excluded from the gem by design, so nothing at runtime may
  # depend on them. This is the assertion that keeps that true.
  # @intent: { entity: "vendored OpenTestIntent schema", action: "avoid the unshipped fixtures", behavior: "the schema path stays outside spec/, keeping runtime independent of files the gem does not package", layer: "unit" }
  it "is reachable without the spec fixtures, which do not ship" do
    expect(SpecGuard::Client::SCHEMA_PATH).not_to include("/spec/")
  end

  # Criterion 9 + trap (b). Only an actual `gem build` proves `spec.files`
  # resolved the way the gemspec's `git ls-files` intended — reading the
  # gemspec cannot, because the trap is about what git knows, not about what
  # the file says.
  describe "the built gem" do
    # `gem build` shells out, so it runs once for the whole group.
    before(:context) do
      root = File.expand_path("../../..", __dir__)
      @build_dir = Dir.mktmpdir("specguard-gem")
      gem_file = File.join(@build_dir, "built.gem")

      out, err, status = Open3.capture3("gem", "build", "specguard-ruby.gemspec", "--output", gem_file,
                                        chdir: root)
      raise "gem build failed:\n#{out}\n#{err}" unless status.success?

      @spec = Gem::Package.new(gem_file).spec
    end

    after(:context) { FileUtils.remove_entry(@build_dir) if @build_dir }

    # @intent: { entity: "built gem", action: "build from the gemspec", behavior: "a real gem build produces a package named specguard-ruby carrying the current version constant", layer: "integration" }
    it "builds, and is named and versioned as expected" do
      expect(@spec.name).to eq("specguard-ruby")
      expect(@spec.version.to_s).to eq(SpecGuard::RSpec::VERSION)
    end

    # @intent: { entity: "built gem", action: "package the vendored schema", behavior: "the built gem file list includes the schema under lib, which the linter cannot run without", layer: "integration" }
    it "packages the vendored schema, which the linter cannot run without" do
      expect(@spec.files).to include("lib/specguard/client/schemas/open-test-intent.v1.json")
    end

    # The schema is not the only file the trap can eat. `git ls-files` misses
    # ANY untracked file, and an untracked `lib/**.rb` produces a LoadError in
    # the installed gem — reproduced during this ticket, before these files
    # were added. Enumerating the tree rather than naming files keeps the next
    # person who adds one honest without their having to remember this spec.
    # @intent: { entity: "built gem", action: "package every lib Ruby file", behavior: "the built gem file list contains every Ruby file found under lib on disk, so an untracked file cannot produce a load error only on install", layer: "integration" }
    it "packages every Ruby file under lib/, not just the ones named here" do
      root = File.expand_path("../../..", __dir__)
      on_disk = Dir.glob("lib/**/*.rb", base: root).sort

      expect(@spec.files & on_disk).to match_array(on_disk)
    end

    # Both of them, and pinned as a whole list rather than with `include`: an
    # executable declared in `spec.executables` but absent from `spec.files` is
    # installed as a broken shim, and one added to `bin/` but never declared is
    # not installed at all. `spec.files` comes from `git ls-files`, so the
    # second shape is one `git add` away at any time — this example is what
    # caught `bin/specguard-ingest` while it was still untracked (SPGD-631).
    # @intent: { entity: "built gem", action: "package both executables", behavior: "the built gem declares and carries exactly the specguard-lint and specguard-ingest executables", layer: "integration" }
    it "packages both executables" do
      expect(@spec.executables).to match_array(%w[specguard-lint specguard-ingest])
      expect(@spec.files).to include("bin/specguard-lint", "bin/specguard-ingest")
    end

    # @intent: { entity: "built gem", action: "exclude the spec tree", behavior: "no file under spec/ appears in the built gem, so fixtures can never become load-bearing at runtime", layer: "integration" }
    it "does not package the spec fixtures, so they can never become load-bearing" do
      expect(@spec.files.grep(%r{^spec/})).to be_empty
    end

    # SPGD-867 INVERTED this pin: json_schemer was the gem's first runtime
    # dependency and is now FORBIDDEN in lib/ (validation is the binary's
    # job; it survives only as a development dependency for the offline spec
    # stub). A runtime dependency creeping back would mean the hand-rolled
    # validation path had quietly returned.
    # @intent: { entity: "built gem", action: "declare no json_schemer runtime dependency", behavior: "the runtime dependency list omits json_schemer, keeping validation owned by the Go binary", layer: "integration" }
    it "declares no json_schemer runtime dependency" do
      expect(@spec.runtime_dependencies.map(&:name)).not_to include("json_schemer")
    end
  end

  # The end of the trap: prove the packaged gem's own copy of the schema is
  # loadable, standing outside the source checkout so no stray relative path
  # can rescue it.
  describe "the schema as the installed gem would see it" do
    # SPGD-867: nothing loads the schema any more — the digest the
    # schema-contract check computes is the only runtime reader, and it needs
    # BYTES. So the packaged copy is proven by digest: parseable JSON whose
    # bytes match the checkout's copy, which is what the contract check
    # compares against the binary's.
    # @intent: { entity: "vendored OpenTestIntent schema", action: "load from outside the checkout", behavior: "a copy placed in a scratch directory parses to the same document and byte-identical digest as the checkout copy", layer: "unit" }
    it "matches the checkout's copy byte for byte, from outside the checkout" do
      Dir.mktmpdir do |dir|
        packaged = File.join(dir, "open-test-intent.v1.json")
        FileUtils.cp(SpecGuard::Client::SCHEMA_PATH, packaged)

        expect(JSON.parse(File.read(packaged))).to eq(schema)
        expect(Digest::SHA256.file(packaged).hexdigest)
          .to eq(Digest::SHA256.file(SpecGuard::Client::SCHEMA_PATH).hexdigest)
      end
    end
  end
end
