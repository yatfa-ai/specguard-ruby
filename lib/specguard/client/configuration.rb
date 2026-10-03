# frozen_string_literal: true

module SpecGuard
  module Client
    # Where the checkout is sitting — which commit, and which branch — asked of
    # git directly.
    #
    # This is the *last* resort for both, consulted only when no environment
    # variable named the answer.
    #
    # The two questions carry different stakes and the same honesty
    # requirement. `commit_sha` is the one envelope field the platform refuses
    # a run without (`Ingest::Payload#validate_commit_sha` rejects a blank one
    # and the whole POST comes back 400, every example discarded), so a run
    # that cannot name its commit is a run whose telemetry is lost entirely —
    # not one with a gap in it. A nil `branch`, by contrast, is *accepted*: the
    # platform stores it, and renders it as "not reported". Which is precisely
    # why a guess is worse here than a gap — see {BRANCH_COMMAND}.
    #
    # Three properties, all load-bearing, and both questions have all three:
    #
    #   * It never raises. `git` may not be installed at all, in which case
    #     `IO.popen` raises `Errno::ENOENT` before a subprocess ever exists.
    #   * It never prints. `git rev-parse HEAD` outside a repository writes
    #     "fatal: not a git repository" to stderr, and a telemetry tool that
    #     graffitis somebody's CI log with a git error has already failed.
    #   * It answers once per process. Each result is memoized *separately*
    #     because a subprocess is expensive relative to everything else here,
    #     and neither answer can change mid-run.
    module GitCheckout
      COMMIT_SHA_COMMAND = %w[git rev-parse HEAD].freeze

      # `symbolic-ref`, deliberately, and **not** `rev-parse --abbrev-ref HEAD`.
      #
      # On a detached checkout `--abbrev-ref` *succeeds*, exit 0, printing the
      # literal string `"HEAD"`. `actions/checkout` detaches by default, so that
      # command would report `branch: "HEAD"` for a large share of CI runs — a
      # value the platform stores, renders in its Branch column, and groups by,
      # indistinguishable from a repository that genuinely has a branch called
      # `HEAD`. It is the wrong answer wearing the costume of a right one.
      #
      # `git symbolic-ref --short -q HEAD` asks the question actually being
      # asked: *what branch is HEAD a symbolic reference to?* Detached, there is
      # no answer, and it says so the honest way — no output, exit 1, and `-q`
      # keeps it silent while doing it. {.resolve}'s existing `$?.success?`
      # guard turns that straight into `nil`, which is what a detached checkout
      # should report and what the platform already knows how to render.
      BRANCH_COMMAND = %w[git symbolic-ref --short -q HEAD].freeze

      class << self
        # @return [String, nil] the checked-out commit, or nil for any reason
        #   at all — no git, no repository, an empty repository, a broken HEAD.
        def commit_sha
          return @commit_sha if defined?(@commit_sha)

          @commit_sha = resolve(COMMIT_SHA_COMMAND)
        end

        # @return [String, nil] the branch the checkout is on, or nil for any
        #   reason at all — no git, no repository, and notably a **detached
        #   HEAD**, which is nil rather than the string "HEAD". See
        #   {BRANCH_COMMAND}.
        def branch
          return @branch if defined?(@branch)

          @branch = resolve(BRANCH_COMMAND)
        end

        # Drop the memoized answers — *both* of them. For tests, and for the
        # rare caller that changes directory into a different checkout
        # mid-process, where the commit and the branch have equally gone stale.
        #
        # @return [void]
        def reset!
          remove_instance_variable(:@commit_sha) if defined?(@commit_sha)
          remove_instance_variable(:@branch) if defined?(@branch)
          nil
        end

        private

        # Shared by both questions so that the two guards below are written
        # once and cannot drift apart — they are the whole of the never-raises
        # and never-prints contract.
        #
        # @param command [Array<String>] argv, never a shell string
        # @return [String, nil]
        def resolve(command)
          # `err: IO::NULL` is the "never prints" half: outside a repository
          # either command writes the same "fatal: not a git repository" to
          # stderr, and the exit status is the only part of that we want.
          output = IO.popen(command, err: IO::NULL, &:read)
          # A non-zero exit is a real answer for {BRANCH_COMMAND} rather than
          # only an error: `symbolic-ref -q` exits 1 on a detached HEAD, and
          # "no branch" is exactly what that should mean.
          return nil unless $?&.success? # rubocop:disable Style/SpecialGlobalVars

          value = output.to_s.strip
          value.empty? ? nil : value
        rescue ScriptError, StandardError
          # `Errno::ENOENT` (no git binary) is the common one; the broad rescue
          # is deliberate, because there is no failure here worth a raise.
          nil
        end
      end
    end

    # What {SpecGuard::RSpecFormatter} needs to know about the run it is
    # watching: which checkout produced it, and where to send what was captured.
    #
    # == Why the environment is the default source
    #
    # `commit_sha` and `branch` are facts about the *checkout*, not about the
    # suite, and every CI provider already publishes them. Reading them from
    # ENV means the common case — a CI job on any of the five major providers —
    # needs no configuration at all. When no provider named either, both fall
    # through to {GitCheckout}, which asks git itself — so a laptop run and a
    # hand-rolled container report their checkout too, without being told to.
    #
    # The escape hatch stays open on top of all of it, for a value neither
    # source can know:
    #
    #   SpecGuard.configure do |config|
    #     config.branch = "release/2.0"
    #   end
    #
    # An explicitly assigned value always wins; the ENV names and the git
    # fallback are only consulted to seed the defaults.
    #
    # == Why an unset value is nil rather than an error
    #
    # Nothing here may ever be the reason a test run fails (see
    # {SpecGuard::RSpecFormatter}'s never-block-CI contract). Somebody running
    # `bundle exec rspec` on a laptop has no `GITHUB_SHA`, and that is not a
    # misconfiguration to shout about — it is a run whose envelope honestly
    # records "unknown commit". A blank or whitespace-only variable is treated
    # the same as an unset one, because CI providers routinely export `""` for
    # a variable that does not apply to the current event.
    #
    # == Transport, and what an unset `api_key` means
    #
    # `endpoint`, `api_key` and `timeout` configure the POST to SpecGuard's
    # ingest endpoint. `api_key` is the switch: set it and the run is delivered
    # over HTTP, leave it unset and the run is appended to `local_output_path`,
    # a local development record kept apart from the `output_path` replay queue
    # (a run offered to the endpoint and not accepted). Local development is
    # therefore the default, and it needs no opt-out — which is the whole
    # reason the switch is the credential rather than a separate `enabled`
    # flag nobody would remember to turn off.
    #
    # There is deliberately **no default endpoint**. SpecGuard is self-hostable
    # and there is no address that is right for everybody; guessing one would
    # mean a misconfigured project POSTing its test names to whatever happens to
    # answer at that name.
    class Configuration
      # Relative to the working directory the suite was started from, which is
      # the project root for every normal `bundle exec rspec` invocation.
      DEFAULT_OUTPUT_PATH = "log/test_results.jsonl"

      # The keyless branch's sink: a local development record, deliberately
      # separate from the replay queue. See {DEFAULT_OUTPUT_PATH}.
      DEFAULT_LOCAL_OUTPUT_PATH = "log/test_results.local.jsonl"

      # Applied to opening the connection and to reading the response.
      #
      # `Net::HTTP`'s own defaults are 60s each, which is up to two minutes
      # added to every CI run against a hung endpoint — squarely against the
      # roadmap's "a 20,000-example run must not be meaningfully slowed". Ten
      # seconds is the number the client-gem spec settles on, and it is the
      # whole budget: there are **no retries**, because a retry doubles the
      # worst case for telemetry that is explicitly allowed to be lost.
      DEFAULT_TIMEOUT_SECONDS = 10

      # Checked in order, first non-blank wins. The `SPECGUARD_`-prefixed name
      # comes first everywhere so a project can always override whatever its CI
      # provider decided to export.
      #
      # The provider list is not decoration. `commit_sha` is the one field the
      # platform rejects a run over, so a list that only knew `GITHUB_SHA` meant
      # every GitLab, CircleCI, Buildkite and Jenkins run 400ing as a matter of
      # course — the *default* outcome on four of the five providers this gem is
      # likely to meet.
      COMMIT_SHA_KEYS = %w[
        SPECGUARD_COMMIT_SHA
        GITHUB_SHA
        CI_COMMIT_SHA
        CIRCLE_SHA1
        BUILDKITE_COMMIT
        GIT_COMMIT
      ].freeze

      # The same providers, in the same order. `GITHUB_REF_NAME` is the short
      # name (`main`), not the full ref (`refs/heads/main`) that `GITHUB_REF`
      # carries; Jenkins's `GIT_BRANCH` is passed through as it comes
      # (`origin/main` on many setups), because `branch` is a free-form string
      # to the platform and inventing a normalization here would be this gem
      # guessing at somebody's ref layout.
      BRANCH_KEYS = %w[
        SPECGUARD_BRANCH
        GITHUB_REF_NAME
        CI_COMMIT_REF_NAME
        CIRCLE_BRANCH
        BUILDKITE_BRANCH
        GIT_BRANCH
      ].freeze

      # The id the CI provider gave the *build*, which every shard of a sharded
      # run shares.
      #
      # This is the field that makes a 20,000-example suite land as one run.
      # Nobody runs a suite that size in a single process: under
      # `parallel_tests`, Knapsack or a CI matrix each shard loads this
      # formatter and POSTs its own slice, and every shard carries the same
      # `commit_sha` and `branch` — so the platform had nothing to tell four
      # shards of one run apart from four separate runs, and recorded four
      # `TestRun` rows each holding a quarter of the denominator. Annotations
      # tend to cluster in whatever area a team is currently working on rather
      # than spreading evenly across shards, so the headline ratio then moved
      # from re-run to re-run without the suite changing at all.
      #
      # == It identifies the run, and deliberately survives a re-run
      #
      # These ids are stable across re-attempts of the same build, and that is
      # documented behaviour rather than an accident. GitHub Actions, verbatim:
      # `GITHUB_RUN_ID` is *"A unique number for each workflow run within a
      # repository. This number does not change if you re-run the workflow
      # run."* (`GITHUB_RUN_ATTEMPT` is the value that increments per attempt.)
      # Buildkite retries a job inside the same `BUILDKITE_BUILD_ID`, bumping
      # `BUILDKITE_RETRY_COUNT`; GitLab retries a job inside the same
      # `CI_PIPELINE_ID`.
      #
      # **The attempt is deliberately not part of this id**, and that is the
      # correction this field carries over its first implementation. Pressing
      # "re-run failed jobs" — the mainline recovery gesture for a sharded
      # suite, because re-running all 20,000 examples for one flaky shard is
      # the thing sharding exists to avoid — re-runs a *subset* of shards. Had
      # the attempt been folded in, that subset would have formed a brand-new
      # run holding only the shards that happened to be retried, which is the
      # split denominator this whole field exists to abolish, one gesture
      # further down. Keeping the id stable instead lets a retried shard land
      # back on the run it belongs to and *replace* its own previous slice.
      #
      # That replacement is what {SHARD_ID_KEYS} is for, and the two fields are
      # only correct together: without a shard identity the platform can add a
      # re-delivered slice but cannot recognise it, so a re-run inflates the
      # denominator instead of refreshing it.
      #
      # Same providers in the same order as above, and the same "unset is nil,
      # never an error" rule — a laptop run has none of these, and the platform
      # treats a run with no id as its own run, which is exactly right.
      #
      # The requirement on whatever a provider exports is only this: every shard
      # of one run reads the same value, and no *other* run reads it. A project
      # whose CI layout does not satisfy that for the variable below — Jenkins
      # `BUILD_TAG` interpolates `JOB_NAME`, which some matrix layouts vary per
      # axis — sets `SPECGUARD_RUN_ID` itself, which wins over all of them.
      RUN_ID_KEYS = %w[
        SPECGUARD_RUN_ID
        GITHUB_RUN_ID
        CI_PIPELINE_ID
        CIRCLE_WORKFLOW_ID
        BUILDKITE_BUILD_ID
        BUILD_TAG
      ].freeze

      # Which shard of the run this process is.
      #
      # The platform keys each slice of a run by this, so a shard that reports
      # twice — a retried job, a re-run of the whole build — replaces its own
      # previous numbers rather than adding to them. Without it, ingest can
      # only ever add, and "re-run failed jobs" reports a suite larger than the
      # suite.
      #
      # It only has to be unique *within one run*; it is never compared across
      # runs, so a bare parallel-process index is a perfectly good value.
      #
      # `nil` is allowed and is not an error: the slice is still counted, it
      # just cannot be recognised if it arrives twice. See the "anonymous
      # contribution" note in the platform's `Ingest::RunRecorder` for exactly
      # what that costs.
      #
      # == Two traps that are the reason this is not a plain key list
      #
      # 1. `parallel_tests` — by far the most likely way a Ruby suite is
      #    sharded — sets `TEST_ENV_NUMBER` to the **empty string** for its
      #    first process (`''`, `'2'`, `'3'`, … so that the first process uses
      #    the plain `yourproject_test` database). A first-non-blank rule would
      #    therefore skip straight past it and leave process 1, and only
      #    process 1, anonymous — the single hardest version of this bug to
      #    see, because three shards of four would be idempotent. Presence of
      #    the variable is the signal here, not its value, so a set-but-empty
      #    `TEST_ENV_NUMBER` resolves to `"1"`. See {#resolve_shard_id}.
      #
      # 2. GitHub Actions exports **no** per-leg index for a `matrix:` job.
      #    `GITHUB_JOB` is the job's id as written in the workflow YAML and is
      #    identical across every leg of the matrix, so it is not in this list —
      #    it would make all N shards claim to be the same shard, and the run
      #    would keep only whichever finished last. A matrix-sharded suite sets
      #    `SPECGUARD_SHARD_ID` from the matrix value itself, e.g.
      #    `SPECGUARD_SHARD_ID: ${{ matrix.shard }}`.
      #
      # The same rule applies to any nesting: `parallel_tests` *inside* a
      # matrix leg makes `TEST_ENV_NUMBER` repeat across legs, so those
      # projects set `SPECGUARD_SHARD_ID` to something that composes both.
      SHARD_ID_KEYS = %w[
        SPECGUARD_SHARD_ID
        TEST_ENV_NUMBER
        CI_NODE_INDEX
        CIRCLE_NODE_INDEX
        BUILDKITE_PARALLEL_JOB
      ].freeze

      # The one key in {SHARD_ID_KEYS} whose empty value is meaningful rather
      # than absent. See trap 1 above.
      BLANK_MEANS_FIRST_SHARD_KEY = "TEST_ENV_NUMBER"

      OUTPUT_PATH_KEYS = %w[SPECGUARD_OUTPUT_PATH].freeze
      LOCAL_OUTPUT_PATH_KEYS = %w[SPECGUARD_LOCAL_OUTPUT_PATH].freeze
      ENDPOINT_KEYS = %w[SPECGUARD_ENDPOINT].freeze
      API_KEY_KEYS = %w[SPECGUARD_API_KEY].freeze
      REPOSITORY_ID_KEYS = %w[SPECGUARD_REPOSITORY_ID].freeze
      TIMEOUT_KEYS = %w[SPECGUARD_TIMEOUT].freeze

      # The commit the suite ran against. `nil` when nothing said.
      attr_accessor :commit_sha
      # The branch the suite ran on. `nil` when nothing said — including a
      # detached checkout, which has no branch to name and says so rather than
      # inventing one. See {GitCheckout::BRANCH_COMMAND}.
      attr_accessor :branch
      # The CI provider's id for the build this process is one shard of.
      # `nil` when nothing said, which is how a laptop run spells "I am my own
      # run". See {RUN_ID_KEYS}.
      attr_accessor :run_id
      # Which shard of that build this process is. `nil` when nothing said.
      # See {SHARD_ID_KEYS}.
      attr_accessor :shard_id
      # Where a run that was *offered to the endpoint and not accepted* is
      # appended, one object per line — the replay queue. `specguard-ingest`
      # pointed at this file re-delivers genuine failed deliveries by
      # construction.
      attr_accessor :output_path
      # Where a keyless run (no `api_key` configured) is appended — a local
      # development record, not a replay queue. Setting this to the same value
      # as {#output_path} reproduces the pre-split single-file behaviour.
      attr_accessor :local_output_path
      # The SpecGuard installation to POST to, scheme and host only:
      # `https://specguard.example.com`. The `/api/v1/ingest` path is the
      # platform's contract, not a setting — with one exception: when
      # {#repository_id} is set the path is `/api/v1/repositories/<id>/ingest`
      # instead. `nil` when nothing said.
      attr_accessor :endpoint
      # The repository's SpecGuard API key. Present means "deliver over HTTP".
      #
      # Deliberately **not** format-checked. The platform mints `sgk_`-prefixed
      # keys today; a client that gated on that prefix would start rejecting
      # valid keys the day the platform rotated it, from a version of the gem
      # nobody can retroactively fix. Send whatever is configured and let a 401
      # be the answer.
      attr_accessor :api_key
      # The repository the run belongs to, sent as a path segment
      # (`/api/v1/repositories/<id>/ingest`). Needed by an `sga_` agent key,
      # which covers a set of repositories and so cannot name the run's
      # repository itself; under an `sgk_` key the platform ignores it. `nil`
      # when unset or blank, which keeps the plain `/api/v1/ingest` path.
      #
      # Deliberately **not** format-checked against the key prefix or a numeric
      # shape (same reasoning as {#api_key}): the platform's 400/403/404 is the
      # answer. {Transport} only refuses ids that are unsafe as a path segment.
      attr_accessor :repository_id
      # Seconds, applied to opening the connection and to reading the response.
      attr_accessor :timeout

      # @param env [#[]] the environment to seed defaults from. Injectable so
      #   the mapping can be tested without mutating the process's own ENV.
      # @param git [#commit_sha, #branch] the checkout to fall back to when no
      #   variable named the commit or the branch. Injectable for the same
      #   reason, and so a test does not silently pick up the sha or the branch
      #   of whatever repository it runs in.
      def initialize(env: ENV, git: GitCheckout)
        @commit_sha = first_present(env, COMMIT_SHA_KEYS) || blank_to_nil(git.commit_sha)
        # `||` short-circuits, which is the whole of "do not spawn a subprocess
        # when a provider already answered".
        @branch = first_present(env, BRANCH_KEYS) || blank_to_nil(git.branch)
        @run_id = first_present(env, RUN_ID_KEYS)
        @shard_id = resolve_shard_id(env)
        @output_path = first_present(env, OUTPUT_PATH_KEYS) || DEFAULT_OUTPUT_PATH
        @local_output_path = first_present(env, LOCAL_OUTPUT_PATH_KEYS) || DEFAULT_LOCAL_OUTPUT_PATH
        @endpoint = first_present(env, ENDPOINT_KEYS)
        @api_key = first_present(env, API_KEY_KEYS)
        @repository_id = first_present(env, REPOSITORY_ID_KEYS)
        @timeout = seconds(first_present(env, TIMEOUT_KEYS)) || DEFAULT_TIMEOUT_SECONDS
      end

      private

      # {SHARD_ID_KEYS} in order, first non-blank wins — except that a
      # {BLANK_MEANS_FIRST_SHARD_KEY} which is *set* counts as a hit even when
      # it is empty, and resolves to `"1"`.
      #
      # `parallel_tests` numbers its processes `''`, `'2'`, `'3'`, … , so its
      # first process is the one case where the empty string is a real answer
      # rather than "nothing said". Reading it as "nothing said" would leave
      # exactly one shard of a run anonymous while its siblings were
      # identified, and the platform would then double-count that shard alone
      # on a re-run — a wrong denominator that moves by a fifth of a suite and
      # points at nothing.
      #
      # `--first-is-1` / `PARALLEL_TEST_FIRST_IS_1` make `parallel_tests` emit
      # a literal `"1"` for that process, which the ordinary path already
      # handles and which lands on the same value, so both configurations agree
      # on what shard 1 is called.
      def resolve_shard_id(env)
        SHARD_ID_KEYS.each do |key|
          value = env[key]
          next if value.nil?

          stripped = value.to_s.strip
          return stripped unless stripped.empty?
          return "1" if key == BLANK_MEANS_FIRST_SHARD_KEY
        end

        nil
      end

      def first_present(env, keys)
        keys.each do |key|
          value = env[key].to_s.strip
          return value unless value.empty?
        end

        nil
      end

      def blank_to_nil(value)
        string = value.to_s.strip
        string.empty? ? nil : string
      end

      # A garbage `SPECGUARD_TIMEOUT` falls back to the default rather than
      # raising or, worse, being coerced to `0` by `String#to_i` — which
      # `Net::HTTP` reads as "time out immediately" and would turn a typo into
      # a run that never delivers anything.
      def seconds(value)
        parsed = Float(value, exception: false)
        return nil unless parsed&.finite? && parsed.positive?

        parsed
      end
    end
  end
end
