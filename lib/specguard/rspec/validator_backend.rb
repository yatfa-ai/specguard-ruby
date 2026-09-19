# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "net/http"
require "open3"

module SpecGuard
  module RSpec
    # The Go validator backend: `validate-intent --source --json`, and since
    # SPGD-867 the ONLY validator `specguard-lint` has.
    #
    # == What this is
    #
    # SPGD-96's Definition of Done ends "…and the Ruby gem invoking it for
    # linting … with the Ruby hand-rolled validation logic removed". This file
    # IS that sentence: {resolve} is default-on, obtaining a prebuilt
    # `validate-intent` binary on first run ({Installer}) when
    # `SPECGUARD_VALIDATE_INTENT` does not name one, and every run validates
    # through the binary it resolved. There is no Ruby fallback — when no
    # binary can be resolved the run exits 2 naming both remediations (see
    # {Installer::REMEDIATIONS}).
    #
    # The reason the cutover waited was distribution, and that blocker is
    # discharged: open-test-intent publishes prebuilt static binaries
    # (`validate-intent-{linux,darwin}-{amd64,arm64}`, CGO_ENABLED=0, schema
    # compiled in) plus a `SHA256SUMS` manifest on its GitHub releases,
    # consumable via `scripts/install.sh` — so the gem can resolve or fetch a
    # binary instead of failing every existing user's working linter.
    #
    # == Why a dedicated seam rather than {Configuration}
    #
    # The originating proposal put this on `Configuration`. That is the wrong
    # object twice over: `Configuration` is the *telemetry* config — its only
    # consumers are `Formatter` and `Transport`, and `CLI` does not reference
    # it at all — so threading the lint backend through it would make the
    # linter depend on the telemetry object solely to read one env var. It also
    # memoizes process-wide (`SpecGuard::RSpec.configuration`), with
    # `reset_configuration!` existing only for tests, which is a poor fit for
    # something a spec wants to vary per example. {CLI} takes an `env:` instead
    # and asks this module, so the seam is one hash away in a test and one
    # method here in production.
    #
    # == The mapping, and the one thing the JSON document does not carry
    #
    # `RunSourceJSON` (open-test-intent, `cmd/validate-intent/report.go`)
    # NORMALIZES the reference's `problem` and `errors` into a single `errors`
    # list, saying so in a comment: "`problem` and `errors` are the same thing
    # to a consumer… `kind` is what tells them apart". {Linter::Result} keeps
    # them apart, and {CLI#report_failure} renders them differently — an em
    # dash on one line for a `problem`, an indented `-> ` line per `reason`.
    #
    # So the split has to be *reconstructed from `kind`*, which is exactly what
    # the Go comment says `kind` is for:
    #
    #   schema                     -> reasons: errors
    #   extraction / parse / read  -> problem: errors.first
    #   no-match                   -> problem, and see below
    #
    # For the three `problem` kinds an `errors` list of any length other than 1
    # is a **contract change**, not something to paper over by joining the
    # strings: the renderer would silently emit one line where the tool meant
    # several. {Runner} raises, and the run exits 2.
    #
    # == `no-match`: the gem's arguments are PATHS, the binary's are GLOBS
    #
    # `validate-intent` expands its arguments as GLOB PATTERNS, recursive `**`
    # included; `specguard-lint`'s are paths, checked as
    # given (`CLI#select`, `Scanner.scan_file`). Handing a path straight through
    # would silently re-expand it: `spec/fixtures/bracket[1]_spec.rb` becomes a
    # character class, and a file containing `*` becomes a wildcard that may
    # match *other* files. Every path is therefore escaped with {escape_glob},
    # so each argument matches exactly the file it names or nothing at all.
    #
    # "Or nothing at all" is Go's `no-match` kind, which the gem has no
    # `Finding::KIND_*` for. It is mapped to {Finding::KIND_READ}, because that
    # is what it *means* on the gem's side of the seam: a named path that could
    # not be opened. The classification, the dropped line number, the "N files
    # could not be read" clause of the summary and the exit code all follow the
    # Ruby path exactly. Two things about it are deliberate:
    #
    #   * the reported file is the ORIGINAL path, not the escaped pattern —
    #     `[[]1]` is an artifact of this file and printing it would misreport
    #     what the caller asked for;
    #   * the wording is the gem's own, not Go's `no file(s) match <pattern>`,
    #     which is a statement about a *pattern* — a concept `specguard-lint`
    #     does not have, and whose text would carry the escaped form.
    #
    # This is one of the ratified differences between the backends, all of
    # which are asserted in `spec/specguard/rspec/validator_backend_spec.rb`.
    #
    # The other three mechanisms are below. Only the first two are about TEXT —
    # the backend passing the binary's wording through where the Ruby path
    # spells it its own way. The third is not a wording difference at all,
    # which is why this list does not call the group "text differences":
    #
    #   * the read-failure tail — see {Scanner.scan_text}, which records the
    #     ratified difference and both spellings. Both refuse the file;
    #     PROTOCOL.md §1.1 requires that much and specifies no prose.
    #   * the parse-failure tail — see {Scanner#parse} (1). A payload that
    #     survives normalisation and still is not JSON is described by
    #     whichever JSON parser saw it, so the Ruby path carries Ruby's
    #     `JSON::ParserError#message` and the backend carries the binary's.
    #     This is the most commonly hit of the three: `parse` is one of the
    #     three things the linter exists to report.
    #   * THE ACCEPTANCE SET — see {Scanner#parse} (2), and note that this one
    #     is not a wording difference at all. It used to be a three-member set
    #     in which the BINARY was the permissive side; PROTOCOL.md §1.1 states
    #     the accepted JSON language now, and the binary refuses all three, so
    #     those have converged. What survives runs the other way: this gem's
    #     `JSON.parse` accepts a LONE LOW surrogate escape that §1.1(a)
    #     refuses, and its nesting boundary sits a little deeper than
    #     §1.1(c)'s 100. For such a payload the backend does not merely word
    #     the failure differently — it HAS one where the Ruby path does not,
    #     so the backend exits 1 where the Ruby path exits 0.
    #
    # That last case is the only known input on which the two backends return
    # different verdicts for the same file, and it is ratified rather than
    # closed for reasons {Scanner#parse} sets out. Nothing here can detect it:
    # a document reporting no findings is exactly what a clean run looks like,
    # so the mapping below is correct and the disagreement is upstream of it.
    #
    # It has NOT always been the only one, and the other one ran the DANGEROUS
    # way round. Until SPGD-512 the binary's `@intent:` payload search was
    # unbounded where {AnnotationScanner#payload_brace} bounds it at the next
    # token, so on a line carrying a malformed token followed by a well-formed
    # one the binary adopted the neighbour's literal, reported it valid and
    # exited 0 where the Ruby path reported no-payload and exited 1 — backend
    # permissive, Ruby strict, the reverse of the surviving case above. That is
    # the direction that costs something: opting into the backend bought a
    # false green. SPGD-512 ported the bound, which is why the claim above
    # holds again; it is recorded rather than deleted because the shape can
    # recur any time a scanner-stage rule lands in one implementation only, and
    # a reader who sees only the surrogate case will not think to look for it.
    #
    # == Everything that can go wrong here is exit 2
    #
    # A missing binary, a binary that will not execute, a non-zero exit this
    # cannot read a document out of, or unparseable output are all "the linter
    # could not do its job". They must never reach exit 1, which the contract
    # has already spent on "an annotation is malformed" ({CLI}). Hence
    # {ValidatorError}, rescued beside {UsageError} so the message reads
    # `specguard-lint: error: …` rather than the backstop's `internal error:`.
    #
    # == Naming what produced the verdicts — and why identity is NOT in that band
    #
    # The paragraph above is about failures to obtain a VERDICT. The binary's
    # identity is not one, and the distinction is the whole of {#identity}.
    #
    # This file already refuses to let "which validator ran" be ambiguous in the
    # two places it can be decided: a named-but-missing binary is a hard exit 2
    # ({Runner#verify!}), and a bare command name is refused rather than
    # PATH-resolved ({Runner#path_hint}) because "a run that succeeded against a
    # different validator … nothing downstream can detect". Both close the hole
    # for binaries that do not resolve. For every binary that DOES resolve, the
    # run was still silent about it: a report produced by the port and a report
    # produced by {Linter} were the same bytes.
    #
    # So {Runner#verify!} asks the binary who it is, once, before anything is
    # selected or scanned — the same fail-early placement as the checks beside
    # it — and {Runner#provenance} renders the answer for the one stderr line
    # {CLI} prints per run. Three properties make that safe:
    #
    #   * it is asked ONCE per run, so it cannot become a per-batch cost on a
    #     large audit. Not by memoizing the answer — {Runner#verify!} re-probes
    #     every time it is called, exactly as it re-runs the three file checks
    #     beside it — but because {ValidatorBackend.resolve} is the only thing
    #     that calls {Runner#verify!} and {CLI} resolves once per run;
    #   * the answer is passed through VERBATIM. A line the gem composed about
    #     the binary would be a claim by the gem; the point is to carry the
    #     binary's own statement, which is the only thing that can distinguish
    #     two builds this gem has never heard of;
    #   * a binary that cannot answer still validates. `--version` arrived in
    #     open-test-intent slice 6; an older build reads it as a filename,
    #     reports "no file(s) match" on stderr and exits 1. That must not cost
    #     a verdict, so the probe treats a non-zero exit, empty output, or
    #     output that cannot be rendered as one line as "identity unavailable"
    #     and never as a {ValidatorError}. `SystemCallError` is caught in the
    #     probe rather than left to {Runner#run}'s rescue for the same reason.
    #
    # "Unavailable" is then reported IN WORDS by {Runner#provenance}. Dropping
    # the line instead would make a run that could not name its validator look
    # exactly like a run nobody looked at — the silent-omission shape this
    # project keeps naming, arrived at from a third direction.
    #
    # == Asking the answer a question: the schema contract across the seam
    #
    # The identity above was carried through and rendered, and nothing read it.
    # One token in it is not decoration: open-test-intent's `VersionLine`
    # (`cmd/validate-intent/version.go`) ends `schema sha256:<64-hex>`, the
    # digest of the schema COMPILED INTO that binary, and `schema.go`'s
    # `SchemaSHA256` says in as many words why it exists —
    #
    #   "a gem that vendors schema A can be pointed at a binary built when
    #   canonical was B, and all three guards stay green while the two halves
    #   enforce different contracts."
    #
    # Every drift guard in this ecosystem compares a matched pair inside ONE
    # checkout: `schema_test.go` digests the Go embed against the Go tree's
    # `schemas/`, and `spec/specguard/rspec/schema_packaging_spec.rb` digests
    # this gem's vendored copy against this gem's pin. Neither looks at an
    # INSTALLED artifact, and neither can. The seam is ordinary, not contrived:
    # `install.sh` fetches
    # a released binary by version with nothing tying that release's vintage to
    # the gem beside it, and {ENV_VAR} accepts any path on the host.
    #
    # And on this path the gem does not even read its own schema — `CLI#run`
    # loads it only when the backend is nil, deliberately, because with the
    # backend on the binary's copy is what governs. So the two contracts never
    # met. {Runner#verify!} is where they now do, beside the three file checks
    # and before anything is selected or scanned: the same fail-early placement
    # this file already argues for, and for the same reason — a divergence is
    # not a verdict about anyone's annotations.
    #
    # == CARRIED is not ENFORCED, and only one of them is the question
    #
    # The paragraphs above are how this check was first built, and they compare
    # the wrong digest. `--version` reports the schema the artifact CARRIES —
    # `SchemaSHA256` is a pure fold of the compiled-in bytes — while `LoadSchema`
    # (`cmd/validate-intent/fileio.go`) gives a `schemas/open-test-intent.v1.json`
    # found beside the executable priority over that copy and falls back to it
    # only on ENOENT. `--version` returns some thirty lines above that decision
    # and never reaches it; the binary's own `--help` trailer says the digest
    # "is not a claim about what a given run enforced".
    #
    # So the carried digest is the one answer that cannot settle the question,
    # and asking it fails in BOTH directions:
    #
    #   * a binary whose embedded schema is ours, sitting beside a `schemas/`
    #     file that is not, reports a matching digest — the guard returns
    #     `:matched` and stays silent — and then enforces different bytes. That
    #     is precisely the case this check exists to refuse, passing;
    #   * the mirror: a binary whose embedded schema differs from ours but whose
    #     on-disk schema IS ours gets refused, for a run that would have been
    #     correct. Planting a schema beside the binary is not exotic — it is how
    #     open-test-intent's own release and cross-build checks operate.
    #
    # open-test-intent slice 19 added `--schema-source`, which calls the REAL
    # loader and prints `schema <origin> sha256:<hex>` for the bytes a verdict
    # run on this host would load. It is the only surface that answers the
    # question, so {Runner#verify!} asks it — once per run, beside the identity
    # probe — and the comparison uses the ENFORCED digest whenever one comes
    # back, falling back to the carried digest, unchanged, when it does not.
    #
    # The bands, and the boundaries between them are the whole design:
    #
    #   * ENFORCED AND EQUAL — the run proceeds, and {Runner#provenance} says so
    #     WITHOUT the hedge below, naming the origin the bytes were loaded from.
    #     This arm may state what the run enforces because that is the question
    #     `--schema-source` answers.
    #
    #   * ENFORCED AND DIFFERENT — {ValidatorError}, exit 2, naming BOTH digests
    #     and the origin. This is the one addition to the exit-2 band, and it
    #     belongs there for the reason the band exists: a verdict produced under
    #     a different contract is not a verdict this gem can stand behind, and
    #     nothing downstream can notice — the report is a normal report, the
    #     exit code is a normal exit code, and the findings are whatever the
    #     other contract implies. Note this is the OPPOSITE of the identity
    #     rule above rather than an exception to it: "I could not ask" stays
    #     out of the band, "I asked and the answer was wrong" goes in.
    #
    #   * CARRIED AND EQUAL, CARRIED AND DIFFERENT — the fallback, reached only
    #     when `--schema-source` did not answer, and byte for byte what this
    #     file did before it was asked: the same two outcomes, the same two
    #     messages, and the hedge kept on the matched arm because on that path
    #     it is still true.
    #
    #   * NOT REPORTED — never a refusal, in any of its three shapes: a
    #     pre-slice-17 build whose `--version` carries no digest token, a binary
    #     that could not answer `--version` at all, and this gem being unable to
    #     read its own vendored schema. Each says so IN WORDS in its own
    #     wording, because "could not check" and "checked and clean" are two
    #     different statements and a checker owes both.
    #
    # == The rule the second probe inherits, and the one it cannot
    #
    # A binary predating slice 19 reads `--schema-source` as a filename, writes
    # "no file(s) match" to stderr and exits 1; a binary whose schema exists and
    # cannot be loaded exits 2 with the "could not load schema" diagnostic that
    # belongs to it, which {#check} reaches a moment later anyway. Both are the
    # identity probe's rule unchanged — a non-zero exit, empty output or output
    # this cannot read is "unavailable" and never a {ValidatorError} — so with
    # the flag absent the run is byte-identical to the one before this existed.
    #
    # That rule is also why {SCHEMA_SOURCE_PATTERN} is pinned against RECORDED
    # output of the real binary in `spec/fixtures/validator/schema-source-probes.json`
    # rather than against a hand-written line. A parse bug does not announce
    # itself here: every miss reads as "this binary is too old", the guard
    # silently reverts to comparing the carried digest, and the run goes green —
    # the exact defect this file is closing, re-created inside the fix.
    #
    # What two probes CANNOT promise is what one probe did. {#verify_schema_contract!}
    # reads {#identity} rather than re-asking, so the digest it compared and the
    # name in the provenance line come from the same process; a second probe is
    # a second process, so the enforced digest carries no such guarantee. It
    # says what a run STARTED at that moment would load, which is the strongest
    # thing any answer to this question can say — the schema beside a binary can
    # change between two lines of a shell script — and the identity/carried pair
    # keeps the promise it always had.
    #
    # That third shape is the one judgment call here, so it is recorded rather
    # than left to be re-derived. The precedent was that an unreadable
    # {SCHEMA_PATH} is exit 2 — but that was a schema the run was about to
    # ENFORCE, and this one is not: `CLI#run` skips the load on this path
    # precisely so an unrelated packaging accident cannot fail a run that never
    # reads it, and making the digest fatal here would re-introduce exactly the
    # dependency that comment removed. An unreadable vendored copy is also not
    # what the exit-2 arm is for — divergence is a POSITIVE finding, two digests
    # that differ, and a missing operand is not a difference. So it lands in the
    # third band and is said out loud. (Hence {Digest::SHA256.file} rather than
    # a digest needs bytes, not a parsed and validated document, so only an
    # unreadable file can fail it and a schema this run does not use cannot
    # fail it twice.)
    #
    # The digest is computed from {SCHEMA_PATH} at runtime and never written
    # down here. A constant would be a fourth copy of a hex string that already
    # exists in three places, drifting independently of the file it claims to
    # describe — which is the precise failure this whole check was added to
    # detect, re-created inside the detector.
    module ValidatorBackend
      # Names a `validate-intent` binary to validate through, overriding the
      # default first-run auto-install. Blank or unset means the default:
      # resolve a cached or freshly downloaded prebuilt binary ({Installer}).
      ENV_VAR = "SPECGUARD_VALIDATE_INTENT"

      # @param env [Hash, ENV]
      # @return [Runner] always a runner — there is no Ruby fallback, so a
      #   binary that cannot be resolved raises rather than degrades
      # @raise [ValidatorError] when no usable binary can be resolved
      def self.resolve(env: ENV)
        # Blank means unset, following `Configuration`'s `blank_to_nil` idiom:
        # `SPECGUARD_VALIDATE_INTENT=` in a CI environment file is somebody
        # asking for the default resolution, not for a binary named "".
        path = env[ENV_VAR].to_s.strip
        path = Installer.obtain(env: env) if path.empty?

        Runner.new(path).tap(&:verify!)
      end

      # Escapes a POSIX path so the binary's globber matches it literally: wrap
      # each of `*`, `?` and `[` in a character class, which makes it match
      # itself. `]` is not escaped and does not need to be — outside a class it
      # is already a literal.
      #
      # @param path [String]
      # @return [String] a glob pattern matching exactly `path`
      def self.escape_glob(path)
        path.gsub(/([*?\[])/, '[\1]')
      end

      # Obtains a `validate-intent` binary for the DEFAULT-ON path: the
      # platform-matched prebuilt asset from open-test-intent's GitHub release,
      # verified against the release's `SHA256SUMS` manifest, cached under the
      # user's cache dir so the network is touched once per machine.
      #
      # == Why the download is verified the way `Runner#verify!` verifies
      #
      # The posture is inherited from the schema-contract check: a downloaded
      # blob is not a binary because we asked for one. The release publishes a
      # `SHA256SUMS` manifest beside its assets, and the gem checks the ONE row
      # that names this platform's asset — the same choice
      # open-test-intent's own `scripts/install.sh` makes, for the reason its
      # header gives (`sha256sum -c` would report the three rows this host did
      # not stage as missing files). Only a row that matches BOTH the digest
      # and the asset name counts, so a manifest that does not describe the
      # fetched bytes is a refusal and not a pass.
      #
      # == Why a failed fetch is an exit 2 naming two remediations
      #
      # There is no Ruby fallback any more, so "no binary" must be loud: the
      # message names the env var (point at a binary you already have) and the
      # `install.sh` curl|sh path (the CI-pinned alternative). A first run with
      # no network is the expected shape of this failure and the message is
      # written for it.
      module Installer
        # The release the gem resolves against. Pinned by tag, not "latest":
        # which validator validated a CI job must not change because somebody
        # published a new release, and {Runner#verify_schema_contract!} pins
        # the fetched binary to this gem's vendored schema anyway.
        # v0.1.4 is the first release whose JSON findings carry `intent` on
        # passing rows; v0.1.3 validated the same schema but reported no payload,
        # which the formatter's mapping reads as "unannotated" — every annotation
        # silently dropped while the verdicts stayed green (found via
        # yatfa-ai/specguard's CI reporting 0.0% annotated after its lock jumped
        # 0.2.3 -> 0.3.1 and the SPGD-867 binary cutover ran for real).
        RELEASE_TAG = "v0.1.4"
        REPOSITORY = "yatfa-ai/open-test-intent"
        DOWNLOAD_BASE = "https://github.com/#{REPOSITORY}/releases/download/#{RELEASE_TAG}"

        # The CI-pinned alternative to the auto-install: install the same
        # verified release artifact onto PATH and point the env var at it.
        INSTALL_SH = "curl -fsSL " \
                     "https://raw.githubusercontent.com/#{REPOSITORY}/#{RELEASE_TAG}/scripts/install.sh | sh"

        # Both remediations, spelled once and reused by every refusal, so the
        # message cannot drift between the ways the fetch can fail.
        REMEDIATIONS = "set #{ValidatorBackend::ENV_VAR} to a validate-intent binary, " \
                       "or install one with: #{INSTALL_SH}"

        # Where the cached binary lives when the user has not redirected it.
        # Honours `SPECGUARD_CACHE_DIR` (hermetic CI caches), then XDG, then
        # `~/.cache` for hosts without XDG set.
        CACHE_DIR_VAR = "SPECGUARD_CACHE_DIR"

        # `RUBY_PLATFORM` -> the release's os/arch vocabulary. Anything outside
        # the four published assets is unsupported: guessable names
        # (`freebsd`?) would produce a 404 masquerading as a policy, so the
        # mapping is closed and the refusal names the platform it was asked
        # about.
        OS_FOR = { /linux/ => "linux", /darwin|mac/ => "darwin" }.freeze
        ARCH_FOR = { /x86_64|amd64|x64/ => "amd64", /aarch64|arm64/ => "arm64" }.freeze

        # `Net::HTTP` timeouts. Short on purpose: this runs at the front of a
        # lint step, and a first-run fetch that hangs is worse than one that
        # fails fast with the remediation message.
        OPEN_TIMEOUT = 10
        READ_TIMEOUT = 30
        MAX_REDIRECTS = 5

        class << self
          # @param env [Hash, ENV]
          # @return [String] path to an executable, SHA256SUMS-verified binary
          # @raise [ValidatorError] when the platform is unsupported or the
          #   binary cannot be obtained or verified
          def obtain(env: ENV)
            asset = asset_name
            destination = File.join(cache_dir(env), asset)

            return destination if cached?(destination)

            install(asset, destination)
          end

          # The release asset name for this host.
          #
          # @param platform [String] a `RUBY_PLATFORM`-shaped string;
          #   injectable so the mapping is testable off exotic hosts
          # @raise [ValidatorError] on an OS or arch with no published asset
          def asset_name(platform: RUBY_PLATFORM)
            os = OS_FOR.find { |pattern, _| pattern.match?(platform) }&.last
            arch = ARCH_FOR.find { |pattern, _| pattern.match?(platform) }&.last

            if os.nil? || arch.nil?
              raise ValidatorError,
                    "no prebuilt validate-intent release asset for #{platform} " \
                    "(#{RELEASE_TAG} publishes #{OS_FOR.values.uniq.product(ARCH_FOR.values.uniq) \
                      .map { |o, a| "#{o}/#{a}" }.join(', ')}) — #{REMEDIATIONS}"
            end

            "validate-intent-#{os}-#{arch}"
          end

          # @param env [Hash, ENV]
          # @return [String]
          def cache_dir(env)
            override = env[CACHE_DIR_VAR].to_s.strip
            xdg = env["XDG_CACHE_HOME"].to_s.strip
            root = override.empty? ? (xdg.empty? ? File.join(Dir.home, ".cache") : xdg) : override
            # Named for the gem, so a cached validator binary survives gem upgrades
            # within one name and is re-downloaded once — and only once — when the
            # gem itself changes name.
            File.join(root, "specguard-ruby", "validate-intent", RELEASE_TAG)
          end

          # Downloads the asset plus its manifest, verifies, and installs
          # atomically (temp file + rename, chmod 0755) so a killed download
          # can never leave a half-written binary the next run mistakes for
          # good — or worse, executes.
          def install(asset, destination)
            manifest = download("#{DOWNLOAD_BASE}/SHA256SUMS")
            expected = manifest_digest(manifest, asset)

            bytes = download("#{DOWNLOAD_BASE}/#{asset}")
            actual = Digest::SHA256.hexdigest(bytes)
            unless actual == expected
              raise ValidatorError,
                    "downloaded #{DOWNLOAD_BASE}/#{asset} has sha256:#{actual}, but the release " \
                    "manifest says sha256:#{expected} — the download is not the artifact the " \
                    "release published, so it was not installed; #{REMEDIATIONS}"
            end

            dir = File.dirname(destination)
            FileUtils.mkdir_p(dir)
            tmp = "#{destination}.tmp.#{Process.pid}"
            File.binwrite(tmp, bytes)
            File.chmod(0o755, tmp)
            File.rename(tmp, destination)
            destination
          rescue ValidatorError
            raise
          rescue StandardError => e
            # Net::HTTP's failures (SocketError, OpenTimeout, EOFError, ...),
            # and any filesystem failure writing the cache. All of them mean
            # "no binary could be obtained", which is the one refusal this
            # module has — exit 2, both remediations.
            raise ValidatorError, "could not obtain validate-intent from #{DOWNLOAD_BASE}: " \
                                  "#{e.class}: #{e.message}; #{REMEDIATIONS}"
          end

          private

          def cached?(path)
            File.file?(path) && File.executable?(path)
          end

          # The one row of `SHA256SUMS` naming this asset:
          # `<64-hex>  <asset-name>` (two spaces, the coreutils format the
          # release workflow writes). A manifest without a row for the asset,
          # or with a row this cannot read, is a refusal — an unverified
          # install is the vacuous green this ecosystem keeps refusing.
          def manifest_digest(manifest, asset)
            manifest.each_line do |line|
              match = /\A(?<digest>\h{64})\s+\*?(?<name>\S+)\s*\z/.match(line)
              next if match.nil?
              return match[:digest].downcase if match[:name] == asset
            end

            raise ValidatorError,
                  "the #{RELEASE_TAG} release manifest does not describe #{asset} — " \
                  "cannot verify the download, so it was not installed; #{REMEDIATIONS}"
          end

          # GET with redirects (the release download 302s to a signed object
          # URL). Bounds the hop count so a misbehaving mirror cannot loop.
          def download(url, redirects = MAX_REDIRECTS)
            uri = URI(url)
            response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                          open_timeout: OPEN_TIMEOUT,
                                                          read_timeout: READ_TIMEOUT) do |http|
              request = Net::HTTP::Get.new(uri)
              # GitHub's release endpoints require a client that names itself.
              request["User-Agent"] = "specguard-ruby-installer"
              http.request(request)
            end

            case response
            when Net::HTTPRedirection
              raise ValidatorError, "too many redirects fetching #{url}" if redirects.zero?

              download(response["Location"], redirects - 1)
            when Net::HTTPSuccess
              response.body
            else
              raise ValidatorError,
                    "fetching #{url} answered HTTP #{response.code} — " \
                    "the release asset is not where the gem looked; #{REMEDIATIONS}"
            end
          end
        end
      end

      # Invokes the binary and turns its report into {Linter::Result}s.
      class Runner
        # `kind` -> the gem's equivalent. `no-match` has no equivalent of its
        # own and folds into KIND_READ; see the module comment.
        KINDS = {
          "schema" => Finding::KIND_SCHEMA,
          "extraction" => Finding::KIND_EXTRACTION,
          "parse" => Finding::KIND_PARSE,
          "read" => Finding::KIND_READ,
          "no-match" => Finding::KIND_READ
        }.freeze

        # Kinds that are a statement about a FILE rather than about an
        # annotation site. They contribute nothing to `summary.annotations`,
        # exactly as `CLI#summary_line` keeps unread files out of the gem's own
        # annotation count.
        #
        # DERIVED from {KINDS}, not transcribed beside it: folding into
        # KIND_READ is what "about a file, not about a site" MEANS here, so the
        # filter is the rule rather than a copy of it. The copy could only go
        # one way — {#failing_result} raises by name on a kind {KINDS} has not
        # been taught, so the port growing its vocabulary forces an edit there
        # and none here, and that one-line edit is exactly what would silence
        # the guard while leaving a hand-written list behind. The set is pinned
        # by name in the spec, so widening it stays a decision someone makes.
        NON_ANNOTATION_KINDS = KINDS.select { |_kind, mapped| mapped == Finding::KIND_READ }.keys.freeze

        # The report used to be all ASCII: paths, a fixed kind vocabulary, and
        # error prose the tool wrote itself. Since SPGD-340 it also carries
        # `intent` — WHAT THE PAYLOAD PARSED TO — so the DOCUMENT now inherits
        # the PAYLOAD's parser-compatibility domain, and a payload the port
        # accepts can be one Ruby's default reader will not read.
        #
        # ONE OF THE TWO OPTIONS IS LOAD-BEARING; THE OTHER IS BELT AND BRACES.
        # Measured against the binary this gem is shipped alongside:
        #
        #   max_nesting: false  LOAD-BEARING. PROTOCOL.md §1.1(c) admits a
        #                       payload nested to depth 100, and a finding WRAPS
        #                       it, so the report nests two deeper than the
        #                       payload while `JSON.parse` defaults to 100.
        #                       Measured: payload depth 98 -> report nests 100,
        #                       parses; depth 99 -> nests 101, raises
        #                       JSON::NestingError. So depths 99-100 are
        #                       PROTOCOL-LEGAL payloads whose report a default
        #                       reader cannot parse at all.
        #
        #   allow_nan: true     NOT reachable from a current binary, and kept
        #                       deliberately. An earlier revision of this
        #                       comment said `1e400` decodes to inf and is
        #                       re-emitted as `Infinity`; that was true of the
        #                       CPython reference and is FALSE of the port,
        #                       which now echoes a number from its own literal
        #                       (`1e400` stays `1e400`) precisely because
        #                       `Infinity` is not JSON and §1.1(b) refuses it.
        #                       Measured: no probe payload produces a bare
        #                       NaN/Infinity token anywhere in a report.
        #
        # Both are enabled rather than left to raise, because the alternative is
        # a batch-wide exit 2 over one annotation's payload — and it would be an
        # exit 2 for a payload the schema was going to REJECT anyway (a
        # non-finite is a number and a deep nest is a container; neither can
        # occupy a schema-legal slot, all of which are strings). Parsing them
        # permissively changes no verdict. Refusing to parse them changes every
        # verdict in the batch.
        PARSE_OPTIONS = { allow_nan: true, max_nesting: false }.freeze

        # A full audit passes every spec file in the repository — thousands of
        # arguments on a large suite — and an argument vector has two separate
        # kernel limits on Linux: `ARG_MAX` caps the TOTAL vector (a quarter of
        # the stack rlimit, so typically ~2 MiB) and `MAX_ARG_STRLEN` caps each
        # SINGLE argument at 128 KiB. Exceeding either is `E2BIG`. This budget
        # is for the first, and is deliberately well under the typical value
        # rather than derived from it: the limit is not portable (it is smaller
        # on some kernels and much smaller on other Unixes), and there is
        # nothing to gain from crowding it. The batches are an implementation
        # detail: {#check} concatenates their findings in argument order, so the
        # caller still gets one list and {CLI} still prints one selection line
        # and one summary line.
        MAX_ARG_BYTES = 96 * 1024
        # A second, independent bound. Some kernels cap the argument *count*
        # (and `MAX_ARG_BYTES` alone would allow ~90k one-character paths).
        MAX_BATCH_FILES = 1_000

        # The `--version` probe's own guard rail, and the only thing it asserts
        # about the answer's SHAPE. The identity is passed through verbatim, so
        # the question is not "is this the format I expect" — a future build may
        # word it differently and still be telling the truth — but "can this be
        # rendered as the one line {CLI} promises per run". A binary answering
        # `--version` with a report document, a stack trace, or a megabyte of
        # anything is answering a different question, and its output would break
        # the line rather than fill it.
        IDENTITY_MAX_BYTES = 200

        # The one token of the identity line this file interprets, matched
        # exactly as `cmd/validate-intent/version.go` writes it: the literal
        # `schema sha256:` followed by 64 hex digits. Everything around it stays
        # opaque — the version, the toolchain, the platform and anything a
        # future build appends are still the binary's business.
        #
        # Anchored at both ends. Without the trailing boundary a 65-digit token
        # would match its first 64 and be compared as if it were a digest; with
        # it, such a token matches nothing and the run lands in the "not
        # reported" band, which is the right answer for a line this gem cannot
        # read rather than one it disagrees with.
        #
        # Case-insensitive, and the capture is compared downcased. Go's
        # `hex.EncodeToString` is lower case and {Digest::SHA256#hexdigest} is
        # too, so today this changes nothing; if a future build shouts, that is
        # a spelling of the same digest and must not be reported as divergence.
        SCHEMA_DIGEST_PATTERN = /\bschema sha256:(\h{64})\b/i

        # The flag that answers what a run ENFORCES. Named as a constant for
        # the reason `schemaSourceFlag` is one on the other side of the seam:
        # the probe passes it, the diagnostics quote it, and the specs assert
        # the argument vector — three places that must spell it the same way.
        SCHEMA_SOURCE_FLAG = "--schema-source"

        # `--schema-source` writes ONE line: `schema <origin> sha256:<64-hex>`,
        # where the origin is either an absolute path or the literal
        # `<embedded schema>` (`cmd/validate-intent/schemasource.go`,
        # `SchemaSourceLine`).
        #
        # This is a SECOND pattern rather than a reuse of {SCHEMA_DIGEST_PATTERN},
        # and the difference is not cosmetic: that one requires `schema`
        # IMMEDIATELY followed by `sha256:`, which is how `--version` writes it,
        # and the origin interposed here means it matches this surface never.
        # Reusing it would have made every probe unreadable, every run fall back
        # to the carried digest, and nothing go red — see the module comment.
        #
        # Anchored to the WHOLE line, unlike the identity token. There, the
        # digest is one token inside a line that is otherwise the binary's own
        # business; here the line IS the answer, so anything around it means
        # this is not the surface being read and the run belongs in the
        # unavailable band. Both captures matter: the digest is compared, and
        # the origin is what lets {#provenance} say WHICH schema was enforced
        # rather than that one was.
        #
        # The trailing anchor is what makes the digest the LAST `sha256:` token
        # on the line rather than the first — the same reading Go's own comment
        # prescribes for the shell (`${line##* }` "yields `sha256:<hex>`
        # whatever the origin contains"). A path may contain spaces, and one may
        # even be NAMED like this tail; ending the match at the end of the line
        # is what keeps the answer the last token in both cases. (The origin is
        # also captured greedily, but that is not what decides it: only one
        # token can end the line.)
        SCHEMA_SOURCE_PATTERN = /\Aschema (?<origin>\S(?:.*\S)?) sha256:(?<digest>\h{64})\z/i

        # The `--schema-source` probe's renderability budget, and the reason it
        # is not {IDENTITY_MAX_BYTES}. This line carries a filesystem path,
        # which POSIX allows up to `PATH_MAX` (4096 on Linux) all by itself, so
        # the 200-byte budget that suits a one-line version string would reject
        # legitimate answers from correctly-installed binaries. It still bounds
        # the line, for the same reason the other one does: a binary answering
        # with a report document or a megabyte of anything is answering a
        # different question, and its output would break the line rather than
        # fill it.
        SCHEMA_SOURCE_MAX_BYTES = 8 * 1024

        attr_reader :path

        # The binary's own `--version` line, or nil when it could not report
        # one. Populated by {#verify!}; nil before it runs, which is why nothing
        # constructs a Runner without it (see {ValidatorBackend.resolve}).
        #
        # Assigned unconditionally rather than memoized: a second {#verify!}
        # re-probes, in step with the file checks it sits among, which also
        # re-run. "Once per run" is a property of the single {#verify!} call
        # {ValidatorBackend.resolve} makes, not of a cache here.
        #
        # @return [String, nil]
        attr_reader :identity

        # The result of the schema-contract comparison, one of:
        #
        #   :enforced      — the binary reported the schema its runs LOAD, and
        #                    it is ours. The strong arm: this one is an answer
        #                    about the contract a verdict would be produced
        #                    under, not about the bytes the artifact carries
        #   :matched       — `--schema-source` did not answer, so the carried
        #                    digest was compared instead, and it is ours
        #   :unreported    — it named itself but carries no digest token
        #   :unidentified  — it could not name itself at all
        #   :unreadable    — we could not read our own vendored schema
        #
        # There is no `:diverged` member: both comparisons raise out of
        # {#verify!} on a difference, so no Runner ever exists holding one.
        # Populated by {#verify!} beside {#identity}, and nil before it runs for
        # the same reason.
        #
        # @return [Symbol, nil]
        attr_reader :schema_contract

        # What `--schema-source` answered: `{origin:, digest:}`, or nil when the
        # binary could not answer it — a build predating open-test-intent slice
        # 19, a schema that exists and will not load, or output this cannot
        # read. Populated by {#verify!} beside {#identity}.
        #
        # The digest is the schema a run STARTED at that moment would enforce.
        # It is a second process from {#identity}, so the two are not guaranteed
        # to describe the same instant — see the module comment for what that
        # does and does not cost.
        #
        # @return [Hash{Symbol => String}, nil]
        attr_reader :enforced_schema

        # @param path [String] the `validate-intent` binary
        def initialize(path)
          @path = path
        end

        # Fails before anything is selected or scanned, so "the backend you
        # asked for is not there" is never mistaken for a verdict about
        # anyone's annotations.
        #
        # The two probes ride along for the placement rather than for the
        # check: asking here is what makes them once-per-run and ahead of
        # selection. Neither can fail the run — see the module comment.
        #
        # The schema-contract comparison reads the answers the probes already
        # obtained, so it costs no third process, and it CAN fail the run — see
        # the module comment for why that one band belongs in exit 2 while the
        # identity itself does not.
        #
        # @raise [ValidatorError]
        def verify!
          raise ValidatorError, "#{describe} does not exist#{path_hint}" unless File.exist?(@path)
          raise ValidatorError, "#{describe} is not a file" unless File.file?(@path)
          raise ValidatorError, "#{describe} is not executable" unless File.executable?(@path)

          @identity = probe_identity
          @enforced_schema = probe_schema_source
          @schema_contract = verify_schema_contract!
          self
        end

        # The active arm of {CLI}'s one-line-per-run provenance statement.
        #
        # The identity half is the binary's own words, uninterpreted. The path
        # is spelled exactly as every diagnostic in this file spells it, so the
        # line naming the validator and any error about it name the same thing.
        #
        # The clause after it is the gem's own, because it is a statement about
        # a COMPARISON the gem made and not about the binary. Each of the five
        # states it can report is worded distinctly: three of them mean the
        # contract was not checked, for three different reasons, and collapsing
        # them into one sentence would leave an operator unable to tell a build
        # too old to answer from an installation missing its own schema. The
        # remaining two are both "checked and clean" and must NOT be collapsed
        # either — one of them answers what the run enforces and the other only
        # what the binary carries, which is the whole distinction this file
        # turns on.
        #
        # Composed from three pieces rather than branched on, because the
        # identity and the schema contract are answers to two different
        # questions and every combination of them is reachable: a binary can
        # fail `--version` and answer `--schema-source`, and the line then has
        # to say both things rather than the first one only.
        #
        # @return [String]
        def provenance
          "validated by #{@identity || 'the binary'} at #{@path} (#{ENV_VAR})" \
            "#{identity_clause}#{schema_contract_clause}"
        end

        # @param paths [Enumerable<String>] spec files, as the caller named them
        # @return [Array<Linter::Result>] in argument order
        # @raise [ValidatorError] on any failure to obtain a report
        def check(paths)
          paths = paths.to_a
          # `validate-intent --source` with no argument is a usage error (exit
          # 2) — and there is nothing to ask it. `CLI#report_selection` has
          # already warned about the empty selection.
          return [] if paths.empty?

          batch(paths).flat_map { |group| check_batch(group) }
        end

        private

        def describe
          "the validator backend at #{@path} (#{ENV_VAR})"
        end

        # A bare command name is refused rather than resolved against PATH, and
        # the refusal says how to fix it. Which binary a CI job validated
        # against should not depend on what else happens to be installed and in
        # what order — and the failure that arrangement produces is a run that
        # succeeded against a different validator, which nothing downstream can
        # detect. One shell substitution buys a value that means one thing.
        def path_hint
          return "" if @path.include?(File::SEPARATOR)

          " — #{ENV_VAR} takes a path, not a command name; try #{ENV_VAR}=\"$(command -v #{@path})\""
        end

        # Asks the binary who it is. Never raises: every way this can go wrong
        # is "identity unavailable", which {#provenance} reports in words.
        #
        # `--version` is position-independent in the port and answers on stdout
        # with exit 0 (`cmd/validate-intent/main.go`), so the whole answer is
        # `stdout` and the exit code is a usable gate. A pre-slice-6 build has
        # no such flag: it reads `--version` as a filename, writes "no file(s)
        # match" to STDERR and exits 1 — caught by the exit check, with the
        # stdout checks behind it in case some other build answers differently.
        #
        # The `SystemCallError` rescue is local rather than shared with {#run}'s
        # because the two mean opposite things: there, a binary that will not
        # execute is a run with no verdict and an exit 2; here it is a question
        # that went unanswered, and {#check} will reach the same failure a
        # moment later with the diagnostic that belongs to it.
        #
        # @return [String, nil]
        def probe_identity
          stdout, _stderr, status = Open3.capture3(@path, "--version")
          return nil unless status.success?

          identity_line(stdout)
        rescue SystemCallError
          nil
        end

        # The one shape check, and it is about renderability rather than
        # format — see {IDENTITY_MAX_BYTES}. Anything that survives is returned
        # byte for byte apart from surrounding whitespace, which is the
        # newline `--version` ends with.
        #
        # The encoding test comes FIRST because `String#strip` raises
        # `Encoding::CompatibilityError` on an invalid byte sequence, and an
        # exception here would reach {CLI}'s backstop and turn a binary with an
        # odd `--version` into `internal error:` and an exit 2 — the exact cost
        # this probe is not allowed to have.
        #
        # @return [String, nil]
        def identity_line(stdout)
          return nil unless stdout.to_s.valid_encoding?

          text = stdout.to_s.strip
          return nil if text.empty? || text.bytesize > IDENTITY_MAX_BYTES
          # A control character — a second line, an ANSI escape, a NUL — would
          # break the single line this becomes, or forge extra ones.
          return nil if text.match?(/[[:cntrl:]]/)

          text
        end

        # Asks the binary which schema a run on this host would ENFORCE. Never
        # raises, for the same reasons {#probe_identity} never does and with one
        # more of its own.
        #
        # `--schema-source` is position-independent and answers on stdout with
        # exit 0 (`cmd/validate-intent/schemasource.go`). Three ways it does
        # not, and all three are "unavailable":
        #
        #   * a build predating open-test-intent slice 19 reads the flag as a
        #     filename, writes `no file(s) match '--schema-source'` to stderr
        #     and exits 1. Refusing those runs would be enforcing a contract by
        #     breaking every binary too old to state one;
        #   * a schema that EXISTS beside the binary and cannot be read,
        #     decoded or compiled exits 2 with the "could not load schema"
        #     diagnostic. That is a real failure, but it is not this check's to
        #     report: {#check} reaches it a moment later, from the verdict path,
        #     with the diagnostic that belongs to it. Turning it into a schema
        #     CONTRACT error here would rename somebody's broken installation
        #     into a divergence that does not exist;
        #   * anything this cannot read as the one line the flag documents.
        #
        # @return [Hash{Symbol => String}, nil]
        def probe_schema_source
          stdout, _stderr, status = Open3.capture3(@path, SCHEMA_SOURCE_FLAG)
          return nil unless status.success?

          schema_source(stdout)
        rescue SystemCallError
          nil
        end

        # The parse, guarded exactly as {#identity_line} is and for exactly the
        # same reasons — the encoding test first because `String#strip` raises
        # on an invalid byte sequence, the control-character test because a
        # second line or an ANSI escape would break or forge the single line
        # {CLI} prints per run.
        #
        # Returning nil on a shape this does not recognise is the degrade rule,
        # and it is also this method's one hazard: an unreadable answer and an
        # old binary are indistinguishable downstream by design, so a bug here
        # would be silent. Which is why {SCHEMA_SOURCE_PATTERN} is asserted
        # against recorded output of the real binary rather than against a line
        # written to fit it.
        #
        # @return [Hash{Symbol => String}, nil]
        def schema_source(stdout)
          return nil unless stdout.to_s.valid_encoding?

          text = stdout.to_s.strip
          return nil if text.empty? || text.bytesize > SCHEMA_SOURCE_MAX_BYTES
          return nil if text.match?(/[[:cntrl:]]/)

          match = SCHEMA_SOURCE_PATTERN.match(text)
          return nil if match.nil?

          { origin: match[:origin], digest: match[:digest].downcase }
        end

        # The comparison itself. Returns the state {#schema_contract} reports,
        # and raises for the one band that is a refusal.
        #
        # The ENFORCED digest wins whenever there is one, because it is the only
        # answer to the question being asked: a schema found beside the binary
        # beats the compiled-in copy at validation time, so the carried digest
        # can match while the run enforces other bytes, and can differ while the
        # run enforces ours. The carried comparison below is what happens when
        # the binary is too old to be asked — unchanged, hedge included.
        #
        # The carried arm reads {#identity}, which {#verify!} has just assigned
        # — not a second `--version` — so the digest it compares and the name in
        # the provenance line are guaranteed to have come from the same process.
        # That promise is intact and this method still keeps it. It does NOT
        # extend to the enforced digest, which is necessarily a second process:
        # what that answer promises is what a run started at that moment would
        # load, which is the most any answer to this question can promise, since
        # the file beside a binary can change between two lines of a script.
        #
        # @return [Symbol]
        # @raise [ValidatorError] when the compared digests are both known and differ
        def verify_schema_contract!
          return verify_enforced_contract! unless @enforced_schema.nil?
          return :unidentified if @identity.nil?

          carried = @identity[SCHEMA_DIGEST_PATTERN, 1]&.downcase
          return :unreported if carried.nil?

          verify_carried_contract!(carried)
        end

        # The strong arm: the binary told us which bytes its runs load.
        def verify_enforced_contract!
          vendored = vendored_schema_digest
          return :unreadable if vendored.nil?
          return :enforced if @enforced_schema[:digest] == vendored

          # The origin joins the two digests here for the same reason they are
          # both spelled in full: the reader's next question is which half to
          # move, and `<embedded schema>` and `/usr/local/schemas/…` are fixed
          # by entirely different actions — rebuild or reinstall the binary
          # versus delete or replace a file on this host. Without it the
          # message would state a disagreement and withhold the one fact that
          # says where to go.
          raise ValidatorError,
                "#{describe} reports enforcing schema sha256:#{@enforced_schema[:digest]}, loaded from " \
                "#{@enforced_schema[:origin]}, but this gem vendors sha256:#{vendored} — the two halves " \
                "would enforce different contracts, so this run would produce a verdict this gem cannot " \
                "stand behind; #{self_description}"
        end

        # The fallback, for a binary that cannot be asked what it enforces.
        # Byte for byte the comparison and the message this file had before
        # `--schema-source` existed.
        def verify_carried_contract!(carried)
          vendored = vendored_schema_digest
          return :unreadable if vendored.nil?
          return :matched if carried == vendored

          # Both digests, spelled in full. A message naming only one of them
          # would send the reader to compute the other by hand, and the whole
          # point of this diagnostic is that the two halves are in different
          # places — one inside a binary, one inside an installed gem — and
          # neither is inspectable from where the other lives.
          #
          # The identity is named too, because the question that comes straight
          # after "these differ" is "WHICH build is this, so I know which half
          # to move" — and the path alone does not answer it: the same path can
          # hold a different binary tomorrow. The probe already holds the
          # version string, and this refusal happens above {#provenance}, so
          # unless the error says it nothing in the run ever does.
          raise ValidatorError,
                "#{describe} reports carrying schema sha256:#{carried}, but this gem vendors " \
                "sha256:#{vendored} — the two halves would enforce different contracts, so this run " \
                "would produce a verdict this gem cannot stand behind; the binary identifies itself " \
                "as #{@identity}"
        end

        # How a refusal names the build it read a digest from. The carried arm
        # has an identity by construction; the enforced arm does not, because
        # the two probes are independent and a binary that answers one can fail
        # the other. Saying "identifies itself as " and then nothing would be
        # the worst of the three options.
        def self_description
          return "the binary could not identify itself" if @identity.nil?

          "the binary identifies itself as #{@identity}"
        end

        # This gem's own contract, digested from the file at runtime. Never a
        # constant: see the module comment.
        #
        # nil rather than an exception on an unreadable file, which puts a
        # broken installation in the "could not check" band instead of failing
        # a run that does not otherwise read this file at all. `Errno::ENOENT`
        # and `Errno::EACCES` are `SystemCallError`s; `IOError` covers the rest
        # of the ways a read can end without one.
        #
        # @return [String, nil] 64 lower-case hex digits
        def vendored_schema_digest
          Digest::SHA256.file(SCHEMA_PATH).hexdigest
        rescue SystemCallError, IOError
          nil
        end

        # The identity half of the provenance line's tail: present exactly when
        # the binary could not name itself, and separate from the schema clause
        # because the two probes fail independently. With no `--schema-source`
        # answer this composes into the sentence this file printed before that
        # flag existed; with one, it stops a run whose identity is unknown from
        # silently dropping the fact.
        def identity_clause
          @identity.nil? ? ", which could not report its identity" : ""
        end

        # The tail of the provenance line, one sentence per state.
        #
        # The ENFORCED arm is the only one that may speak about the run: it is
        # the answer to "which bytes would a verdict be produced under", asked
        # of the loader itself, and it names the origin so the reader can see
        # WHICH copy won. The matched (carried) arm below is careful twice over
        # instead — "reports carrying" attributes the claim to the binary, and
        # the clause after the dash refuses the stronger reading the reader
        # would otherwise supply for free. That hedge is kept rather than
        # retired because on the path that still reaches it — a binary too old
        # to answer `--schema-source` — it remains exactly true.
        def schema_contract_clause
          case @schema_contract
          when :enforced
            " — it reports enforcing the schema this gem vendors, loaded from #{@enforced_schema[:origin]}"
          when :matched
            ", which reports carrying the schema this gem vendors — the contract it carries, " \
              "not necessarily the one this run enforced"
          when :unreadable
            ", whose schema contract could not be checked: this gem could not read its own vendored copy"
          when :unidentified
            ", so the schema contract it carries could not be checked"
          else
            ", which reports no schema digest, so the contract it carries could not be checked"
          end
        end

        # Greedy, order-preserving, and never empty: a single path longer than
        # the byte budget still gets its own batch rather than being silently
        # dropped from the run.
        #
        # That is a weaker promise than "it still gets checked", and
        # deliberately so. A path over `MAX_ARG_STRLEN` (128 KiB) is refused by
        # `execve` however it is batched — no grouping can make one argument
        # smaller — so it lands in {#run}'s `SystemCallError` rescue and the run
        # is exit 2. What batching buys is that the failure is LOUD: the file is
        # never quietly omitted from a report that then calls itself clean,
        # which is the silent-omission shape this project keeps naming.
        def batch(paths)
          groups = [[]]
          bytes = 0

          paths.each do |path|
            size = ValidatorBackend.escape_glob(path).bytesize + 1
            if !groups.last.empty? && (bytes + size > MAX_ARG_BYTES || groups.last.length >= MAX_BATCH_FILES)
              groups << []
              bytes = 0
            end
            groups.last << path
            bytes += size
          end

          groups
        end

        def check_batch(paths)
          # The pattern list keeps DUPLICATES. `specguard-lint a a` reports
          # every annotation twice — the Ruby path checks the files it is
          # handed, in the order it is handed them, without de-duplicating —
          # and so does the port. Deriving the argument vector from the
          # lookup hash below instead would silently collapse them and halve
          # the report.
          patterns = paths.map { |path| ValidatorBackend.escape_glob(path) }
          # escaped pattern -> the path the caller named. Used to undo
          # {escape_glob} on a `no-match`, whose `file` is the pattern rather
          # than a path that exists. Collapsing duplicates here is harmless:
          # the same pattern always maps back to the same path.
          originals = patterns.zip(paths).to_h

          document = run(patterns)
          findings = fetch_findings(document)
          check_annotation_count(document, findings)

          findings.map { |finding| result_for(finding, originals) }
        end

        # @return [Hash] the parsed report document
        def run(patterns)
          # No shell: the argument vector goes straight to execve, so a path
          # containing a space or a quote needs no quoting and cannot be
          # re-split. (`--json` is position-independent in the port; it is
          # written next to `--source` for readability.)
          stdout, stderr, status = Open3.capture3(@path, "--source", "--json", *patterns)

          check_status(status, stderr)
          parse_document(stdout, stderr)
        rescue Errno::EPIPE
          # An EPIPE here is about THIS process's own stdout, not the child:
          # `Open3.capture3` flushes the parent's buffered output while
          # setting up the child, and when the reader of that pipe — `| head`,
          # a quitting pager, a CI log tailer — has gone, it is that flush
          # which raises. The rescue below was written for a child that
          # cannot execute; re-wrapping this one would report "the validator
          # could not be executed", accusing the configured backend of a
          # fault that does not exist, and {CLI}'s EPIPE band — which sits
          # ahead of its `ValidatorError` band precisely for this — would
          # never see the exception at all. So it propagates as itself.
          # Every OTHER `SystemCallError` keeps the rescue below: ENOENT,
          # EACCES, ENOEXEC and E2BIG remain validator failures and exit 2.
          raise
        rescue SystemCallError => e
          # ENOENT/EACCES between #verify! and here (a binary deleted or
          # chmod'ed mid-run), ENOEXEC for a file that is not a program, E2BIG
          # if the batching above is ever outgrown.
          raise ValidatorError, "#{describe} could not be executed: #{e.message}"
        end

        # The port's own contract: 0 when everything checked was valid, 1 when
        # something was not. Anything else — 2 for a schema it could not load
        # or a mode it refuses, or death by signal — means it produced no
        # verdict, and neither may this run.
        def check_status(status, stderr)
          return if [0, 1].include?(status.exitstatus)

          raise ValidatorError, "#{describe} #{exit_description(status)}#{trailing(stderr)}"
        end

        def exit_description(status)
          return "exited #{status.exitstatus}" if status.exitstatus

          "did not exit normally (#{status})"
        end

        def parse_document(stdout, stderr)
          document = decode(stdout)
          unless document.is_a?(Hash)
            raise ValidatorError, "#{describe} emitted a #{document.class} where a JSON object was expected"
          end

          # `--source` is the only mode this asks for. A document announcing
          # anything else means the argument vector above no longer says what
          # this code thinks it says — and a report read under the wrong mode's
          # counting rules is worse than no report.
          mode = document["mode"]
          raise ValidatorError, "#{describe} reported mode #{mode.inspect}, expected \"source\"" unless mode == "source"

          document
        rescue JSON::ParserError => e
          raise ValidatorError,
                "#{describe} did not emit a JSON document: #{e.message}#{trailing(stderr)}"
        end

        # An unpaired HIGH surrogate escape in the report text, e.g. `\ud800`
        # not followed by a low surrogate. Ruby's parser refuses it outright.
        #
        # NO CURRENT BINARY CAN EMIT ONE, and this is kept anyway. An earlier
        # revision of this comment said "CPython decodes it and keeps it, so the
        # port emits it" — that was true of the deleted Python reference and is
        # FALSE of the port since SPGD-403, which refuses an unpaired surrogate
        # escape at PARSE time under PROTOCOL.md §1.1(a) and reports the finding
        # with `intent: null`. Measured against the shipped binary: a payload
        # carrying `\ud800` yields `"kind": "parse"`, `"intent": null`, and a
        # report that parses with a plain `JSON.parse` and no options at all.
        #
        # It stays because the gem does not choose which binary it is pointed
        # at. `SPECGUARD_VALIDATE_INTENT` names an arbitrary path, and a report
        # from an OLDER build — or from a third-party implementation of the
        # protocol, which the vendor-neutral wording invites — is exactly the
        # input this class must not turn into a batch-wide exit 2. The recovery
        # is unreachable from the binary in this repository and cheap to keep;
        # deleting it would be trading a real safety net for tidiness.
        UNPAIRED_HIGH_SURROGATE = /\\u[dD][89abAB][0-9a-fA-F]{2}(?!\\u[dD][c-fC-F][0-9a-fA-F]{2})/
        private_constant :UNPAIRED_HIGH_SURROGATE

        # What the escape above is rewritten to: U+FFFD REPLACEMENT CHARACTER,
        # chosen because it is always valid and is the same six characters wide
        # as the `\udXXX` it stands in for, so byte offsets in any parser error
        # still point where they did.
        UNREADABLE_ESCAPE = "\\ufffd"
        private_constant :UNREADABLE_ESCAPE

        # Parse the report, recovering the VERDICTS from a document whose
        # PAYLOADS Ruby cannot read.
        #
        # Since the report began carrying `intent`, the document inherits the
        # payload's parser domain, and an unpaired high surrogate makes the
        # whole thing unparseable here. Letting that raise would cost the batch
        # an exit 2 — up to MAX_BATCH_FILES files reported as "the validator is
        # broken" — over one annotation that the port validated successfully and
        # that this gem, before the key existed, simply shipped as
        # `unannotated`. That is strictly worse than the behaviour the `intent`
        # key was added to improve, so it is not allowed to happen.
        #
        # THE RECOVERY DROPS EVERY PAYLOAD IN THE DOCUMENT AND KEEPS EVERY
        # VERDICT. Both halves are deliberate:
        #
        # * Keeping the verdicts is safe. `file`, `line`, `ok`, `kind` and
        #   `errors` are the tool's own vocabulary and its own prose — no author
        #   text reaches them — so they are unaffected by whatever the payload
        #   contained. The exit code, the FAIL blocks and the counts come out
        #   exactly as they would have.
        #
        # * Dropping ALL the payloads, rather than just the offending one, is
        #   the conservative direction and the only one that cannot corrupt.
        #   The substitution below operates on TEXT, and JSON text can contain
        #   an escaped backslash — an author who literally wrote `\\ud800`
        #   inside their annotation has a perfectly valid payload whose bytes
        #   this regex cannot distinguish from a real escape without
        #   re-implementing the scanner's backslash accounting. Rewriting that
        #   author's payload and then SHIPPING it would put an annotation on the
        #   platform that is not the one they wrote, undetectably (KB SPGD-78 in
        #   value form). Dropping is a lie nobody acts on; corrupting is one
        #   everybody does.
        #
        # The blast radius is bounded by never being worse than the status quo:
        # every annotation in such a document was ALREADY arriving unannotated
        # before this key existed, so the recovery costs nothing that was
        # previously being delivered.
        #
        # The rewrite SUBSTITUTES an equal-length escape rather than DELETING
        # the match, and that is structural rather than cosmetic. Where the
        # regex has landed on an author's literal `\\ud800`, the match begins at
        # the SECOND backslash — so deleting it strands the first, and an orphan
        # backslash escapes whatever now follows. Measured on a document
        # carrying a real lone surrogate and author-typed text together:
        # `lit\\ud800Xtail` deletes to `lit\Xtail` (`invalid escape character in
        # string`), and a match at the end of a value strands the backslash onto
        # the closing quote (`unexpected end of input`). Both raise HERE, inside
        # the recovery, and so become precisely the exit 2 the recovery exists
        # to prevent. Substituting keeps the backslash paired; all three cases
        # parse.
        #
        # The corruption objection above does not reach the substituted value,
        # because {#drop_every_payload} nils every `intent` on the very next
        # line: the rewritten text is read for its VERDICTS, and the value the
        # substitution produced is never shipped and never seen. Substitution is
        # strictly safer than deletion structurally and identical to it on
        # corruption — so the trade that bullet describes is not being re-made
        # here, only carried out without the self-inflicted parse error.
        def decode(stdout)
          JSON.parse(stdout, **PARSE_OPTIONS)
        rescue JSON::ParserError
          # Only a document that actually carries one gets rewritten. A parse
          # failure with no unpaired surrogate in it is a real one and is
          # re-raised for the handler above to report.
          raise unless stdout.match?(UNPAIRED_HIGH_SURROGATE)

          # Block form: in a replacement STRING the backslash would be read as
          # the start of a backreference escape, which is the same class of bug
          # as the one being fixed.
          rewritten = stdout.gsub(UNPAIRED_HIGH_SURROGATE) { UNREADABLE_ESCAPE }
          drop_every_payload(JSON.parse(rewritten, **PARSE_OPTIONS))
        end

        # Sets every finding's `intent` to nil in place. Written over the parsed
        # document rather than by not-parsing the key, because the findings are
        # what the rest of this class reads and `nil` is already its word for
        # "no payload here" — so nothing downstream needs to know a recovery
        # happened.
        def drop_every_payload(document)
          findings = document.is_a?(Hash) ? document["findings"] : nil
          return document unless findings.is_a?(Array)

          findings.each { |finding| finding["intent"] = nil if finding.is_a?(Hash) }
          document
        end

        def fetch_findings(document)
          findings = document["findings"]
          raise ValidatorError, "#{describe} emitted no `findings` array" unless findings.is_a?(Array)
          unless findings.all?(Hash)
            raise ValidatorError, "#{describe} emitted a `findings` entry that is not a JSON object"
          end

          findings
        end

        # The port counts ANNOTATION SITES EXAMINED in `summary.annotations`,
        # and a read failure or a no-match contributes none. So the count and
        # the findings are two independent statements about the same run, and
        # comparing them is what catches output truncated by a full pipe or a
        # killed batch — a case that would otherwise show up as a *smaller*
        # clean report, which is precisely the shape nobody notices.
        def check_annotation_count(document, findings)
          declared = document.dig("summary", "annotations")
          unless declared.is_a?(Integer)
            raise ValidatorError, "#{describe} emitted no integer `summary.annotations`"
          end

          seen = findings.count { |finding| !NON_ANNOTATION_KINDS.include?(finding["kind"]) }
          return if seen == declared

          raise ValidatorError,
                "#{describe} reported #{declared} annotation(s) but emitted #{seen} annotation finding(s)"
        end

        def result_for(finding, originals)
          file = finding["file"]
          raise ValidatorError, "#{describe} emitted a finding with no `file`" unless file.is_a?(String)

          kind = finding["kind"]
          errors = finding_errors(finding, file)
          # Absent on a binary too old to carry it, which reads as nil — the
          # same answer as "this finding had no payload". That is the intended
          # behaviour and not a gap to guard: an annotation whose payload could
          # not be obtained is `unannotated`, whatever the reason. There is no
          # Ruby re-parse to fall back to (SPGD-340 owner decision), so there is
          # no fallback to get wrong.
          intent = finding["intent"]

          return passing_result(finding, file, kind, errors, intent) if finding["ok"] == true

          failing_result(finding, file, kind, errors, originals, intent)
        end

        def finding_errors(finding, file)
          errors = finding["errors"]
          unless errors.is_a?(Array) && errors.all?(String)
            raise ValidatorError, "#{describe} emitted a finding on #{file} whose `errors` is not a list of strings"
          end

          errors
        end

        def passing_result(finding, file, kind, errors, intent)
          unless kind.nil? && errors.empty?
            raise ValidatorError,
                  "#{describe} emitted a passing finding on #{file} carrying kind #{kind.inspect} " \
                  "and #{errors.length} error(s)"
          end

          Linter::Result.new(file: file, line: line_of(finding, file), intent: intent)
        end

        def failing_result(finding, file, kind, errors, originals, intent)
          mapped = KINDS[kind]
          # An unknown kind is a vocabulary the port grew and this file has not
          # been taught. Guessing would render it under whichever branch of
          # #report_failure it fell into by accident; refusing keeps the
          # divergence visible and costs one exit 2.
          raise ValidatorError, "#{describe} emitted the unknown kind #{kind.inspect} on #{file}" if mapped.nil?
          raise ValidatorError, "#{describe} emitted a failing finding on #{file} with no errors" if errors.empty?

          return schema_result(finding, file, errors, intent) if kind == "schema"

          # Extraction, parse, read and no-match findings have no payload by
          # construction — the port emits null for all four — so the intent is
          # not threaded past here. Reading it anyway would invent a case the
          # producer cannot produce.
          problem_result(finding, file, kind, errors, originals)
        end

        def schema_result(finding, file, errors, intent)
          Linter::Result.new(file: file, line: line_of(finding, file),
                             kind: Finding::KIND_SCHEMA, reasons: errors, intent: intent)
        end

        def problem_result(finding, file, kind, errors, originals)
          unless errors.length == 1
            # See the module comment: joining these would collapse several
            # lines the tool meant to print into one em-dashed sentence.
            raise ValidatorError,
                  "#{describe} emitted #{errors.length} errors on a #{kind} finding for #{file}, " \
                  "where the report can render exactly one"
          end

          return no_match_result(file, originals) if kind == "no-match"

          Linter::Result.new(file: file, line: line_of(finding, file),
                             kind: KINDS.fetch(kind), problem: errors.first)
        end

        # A path that matched nothing. Reported against the path the caller
        # named — `originals` undoes {ValidatorBackend.escape_glob} — and in
        # the gem's own words, because Go's "no file(s) match <pattern>" is a
        # statement about a glob pattern this CLI does not have and would carry
        # the escaped spelling into the report.
        def no_match_result(pattern, originals)
          Linter::Result.new(file: originals.fetch(pattern, pattern), line: 0,
                             kind: Finding::KIND_READ,
                             problem: "could not read file: no file at this path")
        end

        # `line` is null exactly where the finding is not line-scoped, which is
        # the same rule `Linter::Result#location` applies from the other side —
        # it drops the line for KIND_READ. 0 is the sentinel `Scanner` already
        # uses for a finding that never reached a line.
        def line_of(finding, file)
          line = finding["line"]
          return 0 if line.nil?
          raise ValidatorError, "#{describe} emitted a non-integer `line` on #{file}" unless line.is_a?(Integer)

          line
        end

        # The binary's stderr, appended to a diagnostic when it said anything.
        # A `--json` run that failed to produce a document has usually
        # explained itself there ("error: could not load schema …"), and
        # dropping it would leave the operator with "it did not emit a JSON
        # document" and nothing to act on.
        def trailing(stderr)
          text = stderr.to_s.strip
          return "" if text.empty?

          " — it said: #{text.lines.first.strip}"
        end
      end
    end
  end
end
