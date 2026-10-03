# frozen_string_literal: true

require "tmpdir"
require "specguard/rspec/formatter"

# Criterion 6: the formatter's settings, their ENV defaults, and the promise
# that nothing here can be the reason a suite fails.
RSpec.describe SpecGuard::Client::Configuration do
  # Never the real checkout. `commit_sha` and `branch` both now fall back to
  # git, and a spec that let that through would be asserting against whatever
  # commit and branch the suite happens to be running on — green on a laptop,
  # and green for the wrong reason.
  let(:no_git) { object_double(SpecGuard::Client::GitCheckout, commit_sha: nil, branch: nil) }

  describe "defaults, seeded from the environment" do
    # `env:` is injected rather than mutating the process's own ENV: these
    # examples would otherwise be order-dependent with anything else that reads
    # a variable, and would behave differently inside a GitHub Actions job
    # (where GITHUB_SHA really is set) than on a laptop.
    subject(:configuration) { described_class.new(env: env, git: no_git) }

    let(:env) { {} }

    context "with nothing set at all" do
      # @intent: { entity: "Configuration", action: "seed from an empty environment", behavior: "with nothing set the commit reports unknown rather than raising", layer: "unit" }
      it "reports an unknown commit rather than raising" do
        expect(configuration.commit_sha).to be_nil
      end

      # @intent: { entity: "Configuration", action: "seed from an empty environment", behavior: "with nothing set the branch reports unknown rather than raising", layer: "unit" }
      it "reports an unknown branch rather than raising" do
        expect(configuration.branch).to be_nil
      end

      # A laptop run has no build to belong to, and that is not a
      # misconfiguration — the platform reads a nil run id as "this run is its
      # own run" and gives it a `TestRun` of its own, exactly as before.
      # @intent: { entity: "Configuration", action: "seed from an empty environment", behavior: "with nothing set the run id reports unknown rather than raising", layer: "unit" }
      it "reports an unknown run id rather than raising" do
        expect(configuration.run_id).to be_nil
      end

      # The one field that cannot be nil: with no path there is no sink, and a
      # run that captured everything and wrote it nowhere is the failure mode
      # this whole slice exists to avoid.
      # @intent: { entity: "Configuration", action: "seed from an empty environment", behavior: "the replay queue output path keeps its default with nothing set", layer: "unit" }
      it "still knows where to write" do
        expect(configuration.output_path).to eq("log/test_results.jsonl")
      end

      # The keyless branch's sink is its own file, so the replay queue never
      # accumulates a laptop's ordinary local runs.
      # @intent: { entity: "Configuration", action: "seed from an empty environment", behavior: "the keyless local sink defaults to a path apart from the replay queue", layer: "unit" }
      it "defaults the local sink apart from the replay queue" do
        expect(configuration.local_output_path).to eq("log/test_results.local.jsonl")
      end

      # Transport is opt-in, and stays off until somebody supplies a
      # credential. A default endpoint would be worse than none: SpecGuard is
      # self-hostable, so there is no address that is right for everybody, and
      # guessing one means a misconfigured project POSTing its test names to
      # whatever answers at that name.
      # @intent: { entity: "Configuration", action: "seed from an empty environment", behavior: "with no endpoint and key the configuration speaks to nobody", layer: "unit" }
      it "speaks to nobody until an endpoint and a key are supplied" do
        expect(configuration).to have_attributes(endpoint: nil, api_key: nil)
      end

      # @intent: { entity: "Configuration", action: "seed from an empty environment", behavior: "the delivery timeout keeps its budget rather than inheriting the http default of sixty seconds", layer: "unit" }
      it "still has a timeout budget, so the default is never Net::HTTP's 60s" do
        expect(configuration.timeout).to eq(10)
      end
    end

    context "in a GitHub Actions job" do
      let(:env) { { "GITHUB_SHA" => "9f8e7d6", "GITHUB_REF_NAME" => "main", "GITHUB_RUN_ID" => "1234567890" } }

      # @intent: { entity: "Configuration", action: "read GitHub Actions", behavior: "in a job the commit and branch come from the workflow own variables", layer: "unit" }
      it "takes the commit and branch from the job's own variables" do
        expect(configuration).to have_attributes(commit_sha: "9f8e7d6", branch: "main")
      end

      # @intent: { entity: "Configuration", action: "read GitHub Actions", behavior: "the run id comes from the run id variable every shard of the job shares", layer: "unit" }
      it "takes the run id from GITHUB_RUN_ID, which every shard of the job shares" do
        expect(configuration.run_id).to eq("1234567890")
      end

      # The whole point of the field. Two matrix legs of one workflow run are
      # one run.
      # @intent: { entity: "Configuration", action: "read GitHub Actions", behavior: "every shard of one workflow run derives the same run id", layer: "unit" }
      it "gives every shard of one workflow run the same id" do
        shards = Array.new(4) { |index| described_class.new(env: env.merge("TEST_ENV_NUMBER" => index.to_s), git: no_git) }

        expect(shards.map(&:run_id).uniq).to eq(["1234567890"])
      end

      # Replaces an earlier example named "gives a re-run of the same commit a
      # different id, so it stays a separate run". That name asserted a fact
      # about GitHub Actions that is false — `GITHUB_RUN_ID` is documented as
      # *"This number does not change if you re-run the workflow run"* — while
      # the body only re-fed a different value and checked it came back out,
      # which `first_present` cannot fail. The name was the load-bearing part
      # and it was wrong, so both halves are replaced here.
      #
      # This is the real behaviour, and it is wanted: a re-run keeps the run id,
      # so a retried shard lands back on the run it belongs to rather than
      # forming a new run holding only the shards that were retried.
      # @intent: { entity: "Configuration", action: "read GitHub Actions", behavior: "a re-run of the same workflow keeps the same run id because the attempt is not part of it", layer: "unit" }
      it "keeps the run id across a re-run of the same workflow run, because the attempt is not part of it" do
        attempt_two = described_class.new(env: env.merge("GITHUB_RUN_ATTEMPT" => "2"), git: no_git)

        expect(attempt_two.run_id).to eq(configuration.run_id)
      end

      # The other half of that: it is `shard_id`, not the run id, that lets the
      # platform tell a re-delivery from a new slice.
      # @intent: { entity: "Configuration", action: "read GitHub Actions", behavior: "each shard keeps a stable shard id across a re-run so a retried shard replaces itself", layer: "unit" }
      it "keeps each shard's own id stable across that re-run, so a retried shard replaces itself" do
        first = described_class.new(env: env.merge("SPECGUARD_SHARD_ID" => "3"), git: no_git)
        retried = described_class.new(
          env: env.merge("SPECGUARD_SHARD_ID" => "3", "GITHUB_RUN_ATTEMPT" => "2"), git: no_git
        )

        expect(retried).to have_attributes(run_id: first.run_id, shard_id: first.shard_id)
      end

      # A genuinely different run — a nightly, a later push — gets a different
      # id from GitHub, which is the case the run id really does separate.
      # @intent: { entity: "Configuration", action: "read GitHub Actions", behavior: "a different workflow run derives a different run id", layer: "unit" }
      it "gives a different workflow run a different id" do
        nightly = described_class.new(env: env.merge("GITHUB_RUN_ID" => "1234567891"), git: no_git)

        expect(nightly.run_id).not_to eq(configuration.run_id)
      end
    end

    describe "the shard identity" do
      # @intent: { entity: "Configuration", action: "derive the shard identity", behavior: "with nothing sharding the suite the shard id stays nil", layer: "unit" }
      it "is nil when nothing shards the suite" do
        expect(described_class.new(env: {}, git: no_git).shard_id).to be_nil
      end

      # The trap this resolver exists for. `parallel_tests` numbers its
      # processes '', '2', '3', … — the first is a *set but empty* variable, so
      # a first-non-blank rule skips it and leaves exactly one shard of the run
      # anonymous while its siblings are named. That shard alone then
      # double-counts on a re-run: a denominator wrong by a fifth of the suite,
      # pointing at nothing.
      # @intent: { entity: "Configuration", action: "derive the shard identity", behavior: "the blank first process of parallel tests reads as shard one rather than absent", layer: "unit" }
      it "reads the blank first process of parallel_tests as shard 1 rather than as absent" do
        expect(described_class.new(env: { "TEST_ENV_NUMBER" => "" }, git: no_git).shard_id).to eq("1")
      end

      # @intent: { entity: "Configuration", action: "derive the shard identity", behavior: "every parallel tests process number yields its own distinct shard id", layer: "unit" }
      it "gives every parallel_tests process a distinct shard id" do
        shards = ["", "2", "3", "4"].map do |number|
          described_class.new(env: { "TEST_ENV_NUMBER" => number }, git: no_git).shard_id
        end

        expect(shards).to eq(%w[1 2 3 4])
      end

      # `--first-is-1` / PARALLEL_TEST_FIRST_IS_1 make parallel_tests emit a
      # literal "1" for that process. Both configurations have to agree on what
      # shard 1 is called, or turning the flag on would split one shard in two.
      # @intent: { entity: "Configuration", action: "derive the shard identity", behavior: "the first-is-one flag lands on the same shard id the blank default produces", layer: "unit" }
      it "lands --first-is-1 on the same shard id as the blank default" do
        blank = described_class.new(env: { "TEST_ENV_NUMBER" => "" }, git: no_git)
        explicit = described_class.new(env: { "TEST_ENV_NUMBER" => "1" }, git: no_git)

        expect(explicit.shard_id).to eq(blank.shard_id)
      end

      {
        "GitLab parallel: / Knapsack Pro" => "CI_NODE_INDEX",
        "CircleCI parallelism:" => "CIRCLE_NODE_INDEX",
        "Buildkite parallelism:" => "BUILDKITE_PARALLEL_JOB"
      }.each do |runner, key|
        # @intent: { entity: "Configuration", action: "derive the shard identity", behavior: "each supported runner takes its shard index from that runner own variable", layer: "unit" }
        it "takes the shard index from #{key} on #{runner}" do
          expect(described_class.new(env: { key => "0" }, git: no_git).shard_id).to eq("0")
        end
      end

      # @intent: { entity: "Configuration", action: "derive the shard identity", behavior: "the explicit shard variable wins, which is how a matrix names its legs", layer: "unit" }
      it "lets SPECGUARD_SHARD_ID win, which is how a GitHub Actions matrix names its legs" do
        env = { "TEST_ENV_NUMBER" => "2", "SPECGUARD_SHARD_ID" => "matrix-leg-3" }

        expect(described_class.new(env: env, git: no_git).shard_id).to eq("matrix-leg-3")
      end

      # GITHUB_JOB is the job's id as written in the workflow YAML, so every leg
      # of a matrix reads the same value. Were it in the key list, all N shards
      # would claim to be one shard and the run would keep only whichever
      # finished last — a *smaller* denominator than the bug this ticket fixes.
      # @intent: { entity: "Configuration", action: "derive the shard identity", behavior: "the job variable is never mistaken for a shard index", layer: "unit" }
      it "does not mistake GITHUB_JOB for a shard index" do
        expect(described_class.new(env: { "GITHUB_JOB" => "rspec" }, git: no_git).shard_id).to be_nil
      end
    end

    # Criterion 5. `commit_sha` is the one envelope field the platform refuses a
    # run over (`Ingest::Payload#validate_commit_sha` → 400, every example
    # discarded), so a key list that only knew GitHub meant the *default*
    # outcome on four of the five providers this gem is likely to meet was total
    # telemetry loss. Asserted per provider, so a failure names the one that
    # regressed rather than moving a count.
    {
      "GitLab CI" => { sha: "CI_COMMIT_SHA", branch: "CI_COMMIT_REF_NAME", run: "CI_PIPELINE_ID" },
      "CircleCI" => { sha: "CIRCLE_SHA1", branch: "CIRCLE_BRANCH", run: "CIRCLE_WORKFLOW_ID" },
      "Buildkite" => { sha: "BUILDKITE_COMMIT", branch: "BUILDKITE_BRANCH", run: "BUILDKITE_BUILD_ID" },
      "Jenkins" => { sha: "GIT_COMMIT", branch: "GIT_BRANCH", run: "BUILD_TAG" }
    }.each do |provider, keys|
      context "on #{provider}" do
        let(:env) { { keys[:sha] => "9f8e7d6", keys[:branch] => "release/2.0", keys[:run] => "build-77" } }

        # @intent: { entity: "Configuration", action: "read other providers", behavior: "on each supported provider the commit resolves from that provider sha variable", layer: "unit" }
        it "resolves the commit from #{keys[:sha]}" do
          expect(configuration.commit_sha).to eq("9f8e7d6")
        end

        # @intent: { entity: "Configuration", action: "read other providers", behavior: "on each supported provider the branch resolves from that provider branch variable", layer: "unit" }
        it "resolves the branch from #{keys[:branch]}" do
          expect(configuration.branch).to eq("release/2.0")
        end

        # Without this the provider's shards have no way to say they are one
        # run, and a 20,000-example suite lands as one `TestRun` per shard —
        # each holding a fraction of the denominator, and the dashboard picking
        # whichever finished last.
        # @intent: { entity: "Configuration", action: "read other providers", behavior: "on each supported provider the run id resolves from that provider run variable", layer: "unit" }
        it "resolves the run id from #{keys[:run]}" do
          expect(configuration.run_id).to eq("build-77")
        end
      end
    end

    # GitHub's variables win over the rest not because GitHub is special but
    # because a fixed order is the only thing that makes the answer predictable
    # when a job exports several — a GitLab runner inside a GitHub-mirrored
    # repo, say. `SPECGUARD_` is first everywhere, which is the override that
    # settles any of it.
    context "when several providers' variables are present at once" do
      let(:env) { { "GITHUB_SHA" => "github", "CI_COMMIT_SHA" => "gitlab", "CIRCLE_SHA1" => "circle" } }

      # @intent: { entity: "Configuration", action: "read other providers", behavior: "when several providers variables are present at once the documented order decides, not chance", layer: "unit" }
      it "resolves them in the documented order rather than at random" do
        expect(configuration.commit_sha).to eq("github")
      end
    end

    context "when the project overrides the provider" do
      let(:env) do
        {
          "SPECGUARD_COMMIT_SHA" => "deadbeef",
          "GITHUB_SHA" => "9f8e7d6",
          "SPECGUARD_BRANCH" => "release/2.0",
          "GITHUB_REF_NAME" => "main",
          "SPECGUARD_RUN_ID" => "our-own-build-id",
          "GITHUB_RUN_ID" => "1234567890",
          "SPECGUARD_OUTPUT_PATH" => "tmp/specguard.jsonl"
        }
      end

      # @intent: { entity: "Configuration", action: "honour overrides", behavior: "the specguard-prefixed variable beats the provider own variable", layer: "unit" }
      it "prefers the SPECGUARD_ variable over the provider's" do
        expect(configuration).to have_attributes(commit_sha: "deadbeef", branch: "release/2.0")
      end

      # The escape hatch that matters most here: a runner that shards a suite
      # itself, or one on a provider not in the list, can still tell the
      # platform which shards belong together.
      # @intent: { entity: "Configuration", action: "honour overrides", behavior: "an explicitly supplied run id beats the provider one", layer: "unit" }
      it "prefers an explicitly supplied run id over the provider's" do
        expect(configuration.run_id).to eq("our-own-build-id")
      end

      # @intent: { entity: "Configuration", action: "honour overrides", behavior: "a configured output path is honoured over the default", layer: "unit" }
      it "honours a configured output path" do
        expect(configuration.output_path).to eq("tmp/specguard.jsonl")
      end

      # @intent: { entity: "Configuration", action: "honour overrides", behavior: "a configured local sink path is honoured without disturbing the replay queue path", layer: "unit" }
      it "honours a configured local output path without disturbing the replay queue" do
        local = described_class.new(env: env.merge("SPECGUARD_LOCAL_OUTPUT_PATH" => "tmp/local.jsonl"), git: no_git)

        expect(local).to have_attributes(
          output_path: "tmp/specguard.jsonl",
          local_output_path: "tmp/local.jsonl"
        )
      end
    end

    describe "the transport settings" do
      let(:env) do
        {
          "SPECGUARD_ENDPOINT" => "https://specguard.example.com",
          "SPECGUARD_API_KEY" => "sgk_abc123",
          "SPECGUARD_TIMEOUT" => "2.5"
        }
      end

      # @intent: { entity: "Configuration", action: "read transport settings", behavior: "the endpoint, key and timeout all read from the environment", layer: "unit" }
      it "reads the endpoint, the key and the timeout from the environment" do
        expect(configuration).to have_attributes(
          endpoint: "https://specguard.example.com",
          api_key: "sgk_abc123",
          timeout: 2.5
        )
      end

      # @intent: { entity: "Configuration", action: "read transport settings", behavior: "the repository id is read from the environment and stripped", layer: "unit" }
      it "reads and strips SPECGUARD_REPOSITORY_ID" do
        configuration = described_class.new(env: env.merge("SPECGUARD_REPOSITORY_ID" => " 42 "), git: no_git)

        expect(configuration.repository_id).to eq("42")
      end

      [nil, "", "   "].each do |blank|
        # @intent: { entity: "Configuration", action: "read transport settings", behavior: "an unset or blank repository id is nil so the plain ingest path is kept", layer: "unit" }
        it "reads #{blank.inspect} as no repository id" do
          environment = blank.nil? ? env : env.merge("SPECGUARD_REPOSITORY_ID" => blank)

          expect(described_class.new(env: environment, git: no_git).repository_id).to be_nil
        end
      end

      # `String#to_i` reads "ten" as 0, and Net::HTTP reads a 0 timeout as
      # "give up immediately" — so the naive coercion turns a typo into a run
      # that silently never delivers anything, which is the exact failure this
      # slice exists to remove.
      ["ten", "0", "-5", "  ", "NaN"].each do |value|
        # @intent: { entity: "Configuration", action: "read transport settings", behavior: "an unparseable timeout value falls back to the default rather than being trusted", layer: "unit" }
        it "falls back to the default rather than trusting #{value.inspect}" do
          configuration = described_class.new(env: env.merge("SPECGUARD_TIMEOUT" => value), git: no_git)

          expect(configuration.timeout).to eq(10)
        end
      end

      # @intent: { entity: "Configuration", action: "read transport settings", behavior: "a nonsense timeout never raises during configuration", layer: "unit" }
      it "does not raise on a nonsense timeout, whatever else it does" do
        expect { described_class.new(env: { "SPECGUARD_TIMEOUT" => "ten" }, git: no_git) }
          .not_to raise_error
      end
    end

    # CI providers routinely export "" for a variable that does not apply to
    # the current event — a pull_request build has no GITHUB_REF_NAME branch in
    # some configurations. Taking that literally would put an empty string in
    # the envelope, which reads as a real answer and is not one.
    context "when a variable is exported but blank" do
      let(:env) { { "SPECGUARD_COMMIT_SHA" => "  ", "GITHUB_SHA" => "9f8e7d6", "SPECGUARD_OUTPUT_PATH" => "" } }

      # @intent: { entity: "Configuration", action: "treat blank exports as unset", behavior: "a variable exported but blank falls through to the next source like an unset one", layer: "unit" }
      it "treats blank as unset and falls through to the next source" do
        expect(configuration.commit_sha).to eq("9f8e7d6")
      end

      # @intent: { entity: "Configuration", action: "treat blank exports as unset", behavior: "a blank output path falls back to the default rather than writing to an empty name", layer: "unit" }
      it "falls back to the default path rather than writing to \"\"" do
        expect(configuration.output_path).to eq("log/test_results.jsonl")
      end

      # @intent: { entity: "Configuration", action: "treat blank exports as unset", behavior: "a blank local path falls back to its default rather than writing to an empty name", layer: "unit" }
      it "falls back to the default local path rather than writing to \"\"" do
        blank_local = described_class.new(env: { "SPECGUARD_LOCAL_OUTPUT_PATH" => "" }, git: no_git)

        expect(blank_local.local_output_path).to eq("log/test_results.local.jsonl")
      end

      # An empty run id is worse than none: it is a *key*, and every unrelated
      # run exporting the same empty string would accumulate onto one row.
      # @intent: { entity: "Configuration", action: "treat blank exports as unset", behavior: "a blank run id is treated as no run id at all", layer: "unit" }
      it "treats a blank run id as no run id at all" do
        expect(described_class.new(env: { "GITHUB_RUN_ID" => "" }, git: no_git).run_id).to be_nil
      end
    end

    # A blank `SPECGUARD_API_KEY` is how a CI job spells "this fork has no
    # secret". Read literally it is a *present* key, which would send the run
    # to a guaranteed 401 instead of the local sink.
    context "when the API key is exported but blank" do
      let(:env) { { "SPECGUARD_API_KEY" => "", "SPECGUARD_ENDPOINT" => "https://specguard.example.com" } }

      # @intent: { entity: "Configuration", action: "treat blank exports as unset", behavior: "an api key exported but blank is treated as no key at all", layer: "unit" }
      it "treats it as no key at all" do
        expect(configuration.api_key).to be_nil
      end
    end

    # @intent: { entity: "Configuration", action: "normalise values", behavior: "surrounding whitespace a shell heredoc adds is stripped from values", layer: "unit" }
    it "strips surrounding whitespace, which a shell here-doc adds easily" do
      configuration = described_class.new(env: { "SPECGUARD_BRANCH" => "  main\n" }, git: no_git)

      expect(configuration.branch).to eq("main")
    end
  end

  # Criterion 5's tail: the run nobody's CI provider named. Without this, a
  # laptop run, a hand-rolled container and any provider not on the list above
  # all produce a blank `commit_sha` — which the platform rejects outright — and
  # a blank `branch`, which it accepts and renders as "not reported" on every
  # single row.
  describe "the git fallback" do
    let(:git) { object_double(SpecGuard::Client::GitCheckout, commit_sha: "cafebabe", branch: "release/2.0") }

    # @intent: { entity: "Configuration", action: "fall back to git", behavior: "when no variable named the commit the checkout is asked", layer: "unit" }
    it "asks the checkout when no variable named the commit" do
      expect(described_class.new(env: {}, git: git).commit_sha).to eq("cafebabe")
    end

    # @intent: { entity: "Configuration", action: "fall back to git", behavior: "when no variable named the branch the checkout is asked", layer: "unit" }
    it "asks the checkout when no variable named the branch" do
      expect(described_class.new(env: {}, git: git).branch).to eq("release/2.0")
    end

    # The subprocess is the expensive thing here, and it is pure loss when a CI
    # provider already published the answer.
    # @intent: { entity: "Configuration", action: "fall back to git", behavior: "a variable that already answered the commit stops git being asked", layer: "unit" }
    it "does not ask when a variable already answered" do
      described_class.new(env: { "GITHUB_SHA" => "9f8e7d6" }, git: git)

      expect(git).not_to have_received(:commit_sha)
    end

    # The same, for the field this fallback was added to. Both halves of the
    # `||` matter: the left one answers, and the right one must not even run.
    # @intent: { entity: "Configuration", action: "fall back to git", behavior: "a variable that already answered the branch stops git being asked", layer: "unit" }
    it "does not ask for the branch when a variable already answered" do
      described_class.new(env: { "GITHUB_REF_NAME" => "main" }, git: git)

      expect(git).not_to have_received(:branch)
    end

    # @intent: { entity: "Configuration", action: "fall back to git", behavior: "when git has no commit answer either the commit reports unknown", layer: "unit" }
    it "reports an unknown commit when git has no answer either" do
      expect(described_class.new(env: {}, git: no_git).commit_sha).to be_nil
    end

    # A detached checkout reaches here as a nil from {GitCheckout.branch}, and
    # nil is what the envelope should carry. See the detached-HEAD example in
    # the `GitCheckout` block below for why that is not the string "HEAD".
    # @intent: { entity: "Configuration", action: "fall back to git", behavior: "when git has no branch answer either the branch reports unknown", layer: "unit" }
    it "reports an unknown branch when git has no answer either" do
      expect(described_class.new(env: {}, git: no_git).branch).to be_nil
    end

    # @intent: { entity: "Configuration", action: "fall back to git", behavior: "a blank answer from git counts as no answer for the commit", layer: "unit" }
    it "treats a blank answer from git as no answer" do
      blank = object_double(SpecGuard::Client::GitCheckout, commit_sha: "  \n", branch: "  \n")

      expect(described_class.new(env: {}, git: blank).commit_sha).to be_nil
    end

    # @intent: { entity: "Configuration", action: "fall back to git", behavior: "a blank answer from git counts as no branch", layer: "unit" }
    it "treats a blank branch from git as no branch" do
      blank = object_double(SpecGuard::Client::GitCheckout, commit_sha: "  \n", branch: "  \n")

      expect(described_class.new(env: {}, git: blank).branch).to be_nil
    end
  end

  # == The third exhaustiveness claim in README's "What SpecGuard collects"
  #
  # That section's payload key set is pinned in `formatter_spec.rb` and its
  # request-header set in `transport_spec.rb`. The third promise is this one:
  # the envelope table names, variable by variable, everything the formatter
  # reads off your machine, and the "No environment" bullet below it closes the
  # list — *these and no others*.
  #
  # A closed list is what a security review actually acts on, and it is the
  # claim that rots most quietly here. Adding a provider to any list below is a
  # one-line change with no visible consequence: nothing else in this file
  # compares a whole list — every other example sets one variable and asserts
  # one resolved value — so a seventh branch key, or a new `SPECGUARD_`
  # -prefixed switch, ships green with the README still promising the old set.
  #
  # The drift is measured rather than hypothetical. This disclosure was first
  # written naming 9 of the 23 provider variables, and nothing in the suite
  # objected; a reader caught it by hand. `eq` over the whole structure is the
  # shape that cannot stay quiet — it fails and names both the list and the
  # variable that appeared.
  #
  # Order is asserted deliberately, not incidentally. The README does not just
  # list these variables, it states their precedence ("`SPECGUARD_RUN_ID` if
  # you set it, else …"), so a reordering is a documentation defect exactly as
  # much as an addition is, and `eq` over an Array catches both.
  #
  # **If this just failed, you changed what the gem reads from the
  # environment.** Update the envelope table and the "No environment" bullet in
  # README's "What SpecGuard collects" *first*, then update this list. The
  # section is named rather than cited by line number on purpose — a line
  # reference rots the first time anything above it moves.
  describe "the disclosed environment surface" do
    # Pinned before the contents, because the hash in the next example can only
    # ever speak for the lists it names. A brand-new `*_KEYS` constant, read in
    # `#initialize` alongside the others, is invisible to that example and to
    # every other one in this file — so the *set of lists* is a claim in its
    # own right, and the cheapest half of "and no others" to hold.
    # @intent: { entity: "Configuration", action: "disclose the env surface", behavior: "no key is read beyond the ones the readme accounts for", layer: "unit" }
    it "reads no key list beyond the ones the README accounts for" do
      expect(described_class.constants.grep(/_KEYS\z/).sort).to eq(
        %i[API_KEY_KEYS BRANCH_KEYS COMMIT_SHA_KEYS ENDPOINT_KEYS
           LOCAL_OUTPUT_PATH_KEYS OUTPUT_PATH_KEYS REPOSITORY_ID_KEYS RUN_ID_KEYS SHARD_ID_KEYS
           TIMEOUT_KEYS]
      )
    end

    # @intent: { entity: "Configuration", action: "disclose the env surface", behavior: "exactly the variables the readme discloses are read, and no others", layer: "unit" }
    it "reads exactly the variables the README discloses, and no others" do
      expect(
        "commit_sha" => described_class::COMMIT_SHA_KEYS,
        "branch" => described_class::BRANCH_KEYS,
        "ci_run_id" => described_class::RUN_ID_KEYS,
        "shard_id" => described_class::SHARD_ID_KEYS,
        "endpoint" => described_class::ENDPOINT_KEYS,
        "api_key" => described_class::API_KEY_KEYS,
        "repository_id" => described_class::REPOSITORY_ID_KEYS,
        "output_path" => described_class::OUTPUT_PATH_KEYS,
        "local_output_path" => described_class::LOCAL_OUTPUT_PATH_KEYS,
        "timeout" => described_class::TIMEOUT_KEYS
      ).to eq(
        "commit_sha" => %w[SPECGUARD_COMMIT_SHA GITHUB_SHA CI_COMMIT_SHA
                           CIRCLE_SHA1 BUILDKITE_COMMIT GIT_COMMIT],
        "branch" => %w[SPECGUARD_BRANCH GITHUB_REF_NAME CI_COMMIT_REF_NAME
                       CIRCLE_BRANCH BUILDKITE_BRANCH GIT_BRANCH],
        "ci_run_id" => %w[SPECGUARD_RUN_ID GITHUB_RUN_ID CI_PIPELINE_ID
                          CIRCLE_WORKFLOW_ID BUILDKITE_BUILD_ID BUILD_TAG],
        "shard_id" => %w[SPECGUARD_SHARD_ID TEST_ENV_NUMBER CI_NODE_INDEX
                         CIRCLE_NODE_INDEX BUILDKITE_PARALLEL_JOB],
        "endpoint" => %w[SPECGUARD_ENDPOINT],
        "api_key" => %w[SPECGUARD_API_KEY],
        "repository_id" => %w[SPECGUARD_REPOSITORY_ID],
        "output_path" => %w[SPECGUARD_OUTPUT_PATH],
        "local_output_path" => %w[SPECGUARD_LOCAL_OUTPUT_PATH],
        "timeout" => %w[SPECGUARD_TIMEOUT]
      )
    end

    # The tail of the `commit_sha` and `branch` cells: when no variable
    # answered, the table says the value comes from these exact commands. The
    # `-q` is load-bearing rather than cosmetic — it is what makes a detached
    # checkout report `null` instead of the string `HEAD`, which is the
    # behaviour the same cell promises — so the disclosed command is pinned
    # with it.
    # @intent: { entity: "Configuration", action: "disclose the env surface", behavior: "the git fallback uses exactly the commands the readme discloses", layer: "unit" }
    it "falls back to exactly the git commands the README discloses" do
      expect(
        "commit_sha" => SpecGuard::Client::GitCheckout::COMMIT_SHA_COMMAND,
        "branch" => SpecGuard::Client::GitCheckout::BRANCH_COMMAND
      ).to eq(
        "commit_sha" => %w[git rev-parse HEAD],
        "branch" => %w[git symbolic-ref --short -q HEAD]
      )
    end
  end
end

# The fallback's own contract, exercised against the real `git` binary. Its
# three properties are all failure-shaped, which is why they are pinned here
# rather than left to the injected double every other example uses.
RSpec.describe SpecGuard::Client::GitCheckout do
  before { described_class.reset! }

  after { described_class.reset! }

  # @intent: { entity: "GitProbe", action: "read the checkout", behavior: "the probe reports the commit the checkout is on", layer: "unit" }
  it "reports the commit this checkout is on" do
    expect(described_class.commit_sha).to match(/\A[0-9a-f]{40}\z/)
  end

  # @intent: { entity: "GitProbe", action: "read the checkout", behavior: "the reported commit agrees with what git itself prints", layer: "unit" }
  it "agrees with git itself" do
    expect(described_class.commit_sha).to eq(`git rev-parse HEAD`.strip)
  end

  # One subprocess per process, not one per read. `Configuration.new` is built
  # lazily and rebuilt by every `reset_configuration!`, so an unmemoized answer
  # would fork git on a schedule nobody controls.
  # @intent: { entity: "GitProbe", action: "memoize answers", behavior: "the commit question is asked once and the answer remembered", layer: "unit" }
  it "asks git once and remembers the answer" do
    allow(IO).to receive(:popen).and_call_original

    3.times { described_class.commit_sha }

    expect(IO).to have_received(:popen).once
  end

  # @intent: { entity: "GitProbe", action: "memoize answers", behavior: "the branch question is asked once and remembered separately", layer: "unit" }
  it "asks git once for the branch and remembers that answer too" do
    allow(IO).to receive(:popen).and_call_original

    3.times { described_class.branch }

    expect(IO).to have_received(:popen).once
  end

  # The two questions need two commands and two memo slots. Sharing either
  # would make whichever was asked first answer for both — silently, and with a
  # value of the wrong shape.
  # @intent: { entity: "GitProbe", action: "memoize answers", behavior: "each question keeps its own memo so one answer never stands in for both", layer: "unit" }
  it "keeps a memo per question rather than one answer standing in for both" do
    allow(IO).to receive(:popen).and_call_original

    2.times { described_class.commit_sha }
    2.times { described_class.branch }

    expect(IO).to have_received(:popen).twice
  end

  # @intent: { entity: "GitProbe", action: "memoize answers", behavior: "a nil commit answer is remembered rather than retried", layer: "unit" }
  it "remembers a nil answer too, rather than retrying a question that failed" do
    allow(IO).to receive(:popen).and_raise(Errno::ENOENT, "git")

    3.times { described_class.commit_sha }

    expect(described_class.commit_sha).to be_nil
    expect(IO).to have_received(:popen).once
  end

  # @intent: { entity: "GitProbe", action: "memoize answers", behavior: "a nil branch answer is remembered rather than retried", layer: "unit" }
  it "remembers a nil branch too, rather than retrying a question that failed" do
    allow(IO).to receive(:popen).and_raise(Errno::ENOENT, "git")

    3.times { described_class.branch }

    expect(described_class.branch).to be_nil
    expect(IO).to have_received(:popen).once
  end

  # `reset!` clearing only one of the two memos is the leak this pins: the
  # examples below chdir into a directory that is not a checkout, and a branch
  # memoized inside *this* repository would survive the move and be asserted
  # against there.
  # @intent: { entity: "GitProbe", action: "reset the memos", behavior: "a reset clears both memos so the next read really re-asks", layer: "unit" }
  it "clears both memos, so a reset really does re-ask" do
    allow(IO).to receive(:popen).and_call_original
    described_class.commit_sha
    described_class.branch

    described_class.reset!
    described_class.commit_sha
    described_class.branch

    expect(IO).to have_received(:popen).exactly(4).times
  end

  describe "outside a git checkout" do
    around do |example|
      Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
    end

    # Not a `git init`'d directory: mktmpdir lands under /tmp, which is not
    # inside this repository, so `git rev-parse` really does fail here.
    # @intent: { entity: "GitProbe", action: "survive a missing checkout", behavior: "outside a git checkout the commit answers nil rather than raising", layer: "unit" }
    it "answers nil rather than raising" do
      expect(described_class.commit_sha).to be_nil
    end

    # @intent: { entity: "GitProbe", action: "survive a missing checkout", behavior: "outside a git checkout the branch answers nil rather than raising", layer: "unit" }
    it "answers nil for the branch rather than raising" do
      expect(described_class.branch).to be_nil
    end

    # "fatal: not a git repository (or any of the parent directories): .git" is
    # git's, and a telemetry tool that graffitis somebody's CI log with it has
    # already failed. Captured at the file-descriptor level because the child
    # process writes to fd 2 directly — reassigning `$stderr` would not see it.
    # @intent: { entity: "GitProbe", action: "survive a missing checkout", behavior: "a failing commit lookup says nothing at all on stderr", layer: "unit" }
    it "says nothing at all on stderr while failing" do
      expect { described_class.commit_sha }.not_to output.to_stderr_from_any_process
    end

    # @intent: { entity: "GitProbe", action: "survive a missing checkout", behavior: "a failing branch lookup says nothing at all on stderr", layer: "unit" }
    it "says nothing at all on stderr while failing to name a branch" do
      expect { described_class.branch }.not_to output.to_stderr_from_any_process
    end
  end

  # Criteria 1 and 2, against the real `git` binary — the only place the
  # detached-HEAD answer can actually be observed, because it is the *command*
  # that is on trial and a double would just agree with whichever one was
  # written.
  #
  # A fixture checkout, never this one: the suite's own repository is on
  # whatever branch a developer or CI left it on, and under `actions/checkout`
  # that is a detached HEAD — precisely the case below. Asserting against it
  # would be green for the wrong reason on a laptop and red for one in CI.
  describe "in a checkout of its own" do
    around do |example|
      Dir.mktmpdir { |dir| Dir.chdir(dir) { example.run } }
    end

    before do
      git!("init", "--quiet", ".")
      git!("config", "user.email", "spec@example.com")
      git!("config", "user.name", "SpecGuard Spec")
      git!("config", "commit.gpgsign", "false")
      File.write("README", "fixture\n")
      git!("add", "README")
      git!("commit", "--quiet", "--message", "the one commit")
      git!("branch", "--move", "release/2.0")
      described_class.reset!
    end

    # Whatever `git init` chose to call the initial branch is renamed above, so
    # this asserts a name the example itself set rather than a default that
    # moved from `master` to `main` between git versions.
    # @intent: { entity: "GitProbe", action: "read a real checkout", behavior: "in a real checkout the probe reports the branch the checkout is on", layer: "unit" }
    it "reports the branch the checkout is on" do
      expect(described_class.branch).to eq("release/2.0")
    end

    # @intent: { entity: "GitProbe", action: "read a real checkout", behavior: "in a real checkout the commit still resolves, though a different command answers it", layer: "unit" }
    it "still reports the commit, which is asked with a different command" do
      expect(described_class.commit_sha).to match(/\A[0-9a-f]{40}\z/)
    end

    # ⭐ The whole reason `symbolic-ref` is the command and `rev-parse
    # --abbrev-ref` is not. `--abbrev-ref` exits **0** on a detached HEAD and
    # prints the literal string "HEAD", which the platform would store, render
    # in its Branch column and group by — indistinguishable from a repository
    # that genuinely has a branch called `HEAD`. `actions/checkout` detaches by
    # default, so that wrong answer would be the *common* one.
    #
    # nil is the honest answer, and the platform already renders it as "not
    # reported".
    context "when the checkout is detached, as actions/checkout leaves it by default" do
      before do
        git!("checkout", "--quiet", "--detach", "HEAD")
        described_class.reset!
      end

      # @intent: { entity: "GitProbe", action: "read a real checkout", behavior: "a detached checkout reports no branch at all rather than the literal head string", layer: "unit" }
      it "reports no branch at all, rather than the literal string \"HEAD\"" do
        expect(described_class.branch).to be_nil
      end

      # Guards the assertion above against passing vacuously: it would also read
      # `nil` if the fixture were not a checkout at all, or if `git` were
      # missing — in which case it would be pinning nothing.
      # @intent: { entity: "GitProbe", action: "read a real checkout", behavior: "the detached checkout genuinely still knows its commit, proving the branch nil is real", layer: "unit" }
      it "is genuinely a detached checkout that still knows its commit" do
        expect(described_class.commit_sha).to match(/\A[0-9a-f]{40}\z/)
      end
    end

    def git!(*args)
      return if system("git", *args, out: File::NULL, err: File::NULL)

      raise "fixture setup failed: git #{args.join(' ')}"
    end
  end

  # `Errno::ENOENT` is raised by `IO.popen` itself, before any child exists —
  # the shape a `$?.success?` check alone would sail straight past.
  # @intent: { entity: "GitProbe", action: "survive a missing binary", behavior: "with no git binary at all the commit answers nil", layer: "unit" }
  it "answers nil when there is no git binary at all" do
    allow(IO).to receive(:popen).and_raise(Errno::ENOENT, "No such file or directory - git")

    expect(described_class.commit_sha).to be_nil
  end

  # @intent: { entity: "GitProbe", action: "survive a missing binary", behavior: "with no git binary at all the branch answers nil", layer: "unit" }
  it "answers nil for the branch when there is no git binary at all" do
    allow(IO).to receive(:popen).and_raise(Errno::ENOENT, "No such file or directory - git")

    expect(described_class.branch).to be_nil
  end

  # @intent: { entity: "GitProbe", action: "survive a missing binary", behavior: "a lookup blowing up in a way a bare rescue would miss still answers nil for the commit", layer: "unit" }
  it "answers nil when the lookup blows up in a way a bare rescue would miss" do
    allow(IO).to receive(:popen).and_raise(NotImplementedError, "nope")

    expect(described_class.commit_sha).to be_nil
  end

  # @intent: { entity: "GitProbe", action: "survive a missing binary", behavior: "the same non-standard failure answers nil for the branch too", layer: "unit" }
  it "answers nil for the branch when the lookup blows up in a way a bare rescue would miss" do
    allow(IO).to receive(:popen).and_raise(NotImplementedError, "nope")

    expect(described_class.branch).to be_nil
  end
end

RSpec.describe SpecGuard do
  after { described_class.reset_configuration! }

  # The framework-neutral entry point a Minitest consumer configures through.
  # `SpecGuard::RSpec.configure` is the documented RSpec spelling and must hand
  # back the SAME object, not a second configuration that the reporter ignores.
  # @intent: { entity: "SpecGuard.configure", action: "share the configuration with SpecGuard::RSpec", behavior: "SpecGuard.configure and SpecGuard::RSpec.configure operate on one and the same configuration object, and a reset through either drops both", layer: "unit" }
  it "shares one configuration object with SpecGuard::RSpec" do
    described_class.configure { |config| config.branch = "feature/neutral" }

    expect(SpecGuard::RSpec.configuration).to equal(described_class.configuration)
    expect(SpecGuard::RSpec.configure).to equal(described_class.configure)
    expect(SpecGuard::RSpec.configuration.branch).to eq("feature/neutral")

    SpecGuard::RSpec.reset_configuration!
    expect(described_class.configuration.branch).not_to eq("feature/neutral")
  end

  # @intent: { entity: "SpecGuard.configure", action: "hand over the configuration", behavior: "configure yields the Client::Configuration and returns it with or without a block", layer: "unit" }
  it "yields and returns the Client::Configuration" do
    yielded = nil
    returned = described_class.configure { |config| yielded = config }

    expect(yielded).to be_a(SpecGuard::Client::Configuration)
    expect(returned).to equal(yielded)
    expect(described_class.configure).to equal(yielded)
  end
end

RSpec.describe SpecGuard::RSpec do
  after { described_class.reset_configuration! }

  describe ".configure" do
    # @intent: { entity: "SpecGuard::RSpec.configure", action: "hand over the configuration", behavior: "the configure block receives the configuration object to set fields on", layer: "unit" }
    it "hands the block the configuration to set" do
      described_class.configure { |config| config.branch = "feature/telemetry" }

      expect(described_class.configuration.branch).to eq("feature/telemetry")
    end

    # @intent: { entity: "SpecGuard::RSpec.configure", action: "hand over the configuration", behavior: "calling configure with no block returns the configuration so it can be read", layer: "unit" }
    it "returns the configuration, so it can be read without a block" do
      expect(described_class.configure).to equal(described_class.configuration)
    end

    # @intent: { entity: "SpecGuard::RSpec.configure", action: "hand over the configuration", behavior: "calling configure with no block at all does not raise", layer: "unit" }
    it "does not raise when called with no block at all" do
      expect { described_class.configure }.not_to raise_error
    end

    # One configuration per process. Two objects would mean a `spec_helper.rb`
    # configuring one while the formatter reads the other — the settings would
    # simply be ignored, silently.
    # @intent: { entity: "SpecGuard::RSpec.configure", action: "hand over the configuration", behavior: "successive configure calls keep configuring the same object", layer: "unit" }
    it "keeps configuring the same object across calls" do
      described_class.configure { |config| config.commit_sha = "abc" }
      described_class.configure { |config| config.branch = "main" }

      expect(described_class.configuration).to have_attributes(commit_sha: "abc", branch: "main")
    end
  end

  describe ".reset_configuration!" do
    # @intent: { entity: "SpecGuard::RSpec.configure", action: "reset the configuration", behavior: "dropping the memoized configuration makes the next read re-seed from the environment", layer: "unit" }
    it "drops the memoized configuration so the next read re-seeds from ENV" do
      described_class.configure { |config| config.branch = "throwaway" }

      expect { described_class.reset_configuration! }
        .to change { described_class.configuration.branch }.from("throwaway")
    end
  end
end
