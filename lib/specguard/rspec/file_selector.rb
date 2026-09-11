# frozen_string_literal: true

require "open3"

module SpecGuard
  module RSpec
    # Chooses which spec files the linter reads.
    #
    # Two modes: every Ruby test file under the working directory (the
    # default), or only those in the current diff (`--changed`). Both modes
    # recognize the two Ruby test-framework naming conventions — RSpec's
    # `*_spec.rb` and Minitest's `*_test.rb` — so a suite is visible to the
    # linter whichever framework wrote it. The default walk scopes Minitest
    # files to `test/` (the directory both Rails and `minitest` own as the
    # convention), while `--changed` filters on the file-name suffix alone: a
    # diff names paths, not directories, and a changed test file is a test
    # file wherever the author put it.
    #
    # == Why `--changed` is not `git diff --name-only`
    #
    # The Client Gem spec words `--changed` as "files in the current diff (via
    # `git diff --name-only`)". Taken literally that is **broken in CI**: bare
    # `git diff --name-only` compares the *working tree against the index*, and
    # CI checks out a commit and leaves the tree clean. It therefore matches
    # nothing, the linter selects zero files, finds zero annotations, and exits
    # 0 — the CI gate the tool exists to provide, silently a no-op.
    #
    # So the diff base is an explicit decision, made here and documented here
    # rather than inherited by accident:
    #
    #   * `--changed` diffs against the **merge base with the default branch**
    #     (`origin/HEAD`, falling back to `origin/main`/`origin/master` and then
    #     their local counterparts). On a feature branch that is exactly "what
    #     this branch changed", whether or not the change is committed yet —
    #     `git diff <base>` with no second commit compares the base against the
    #     *working tree*, so it covers both.
    #   * `--changed=<base>` overrides it, for a CI system that knows better
    #     (a PR's target ref, say).
    #
    # **This still legitimately selects zero files**, and that is not a bug to
    # be fixed by a cleverer base: on a default-branch build after a merge,
    # `HEAD == origin/main`, so the merge base *is* HEAD and nothing differs.
    # There is no diff base that makes "what changed on this build" non-empty
    # there.
    #
    # A **shallow** checkout — the depth-1 clone CI defaults to
    # (`actions/checkout@v4`) — reaches the same thin base by a third road the
    # ref-resolution above cannot see: every `DEFAULT_BRANCH_REFS` probe
    # *resolves* (the fetched tip is in the clone), but the history behind it
    # is not, so the merge base with the default branch is outside the clone
    # and `merge-base` collapses onto HEAD. The notes below therefore consult
    # `git rev-parse --is-shallow-repository` — lazily and memoized, only
    # where the answer changes the message — and in a shallow clone say that,
    # never "default-branch build".
    #
    # That is why the load-bearing requirement is the **loud empty selection**,
    # not the base. The caller must never be unable to tell "checked 12 files,
    # found no annotations" from "checked 0 files" — {Selection} carries the
    # count, the emptiness, and {Stats} explaining *which* filter emptied it, so
    # the CLI can say so on stderr, accurately. A confidently wrong reason is
    # worse than a quiet one: a human who reads "nothing in the diff matched a
    # test file" stops looking — and on a Minitest-only repository the silence
    # must not be explained in RSpec vocabulary the tree does not use. The exit
    # code is not the lever: the spec fixes 0 for "no annotations".
    #
    # == Scope: `--changed` selects changed specs **under `root`**
    #
    # The second explicit decision. `git diff --name-only` emits paths relative
    # to the **repository root**, not to the process's working directory, so the
    # two are only the same when you happen to stand at the top level. Selecting
    # by raw git output would make `--changed` repo-scoped while the default
    # mode is cwd-scoped (`Dir.glob` under `root`) — the same invocation would
    # mean different things in the two modes.
    #
    # `--changed` is therefore **cwd-scoped, to match the default mode**: git's
    # repo-relative paths are resolved against `git rev-parse --show-toplevel`,
    # anything outside `root` is dropped, and what survives is returned relative
    # to `root` — exactly the shape {select_all} returns. Running from
    # `<repo>/sub` selects the changed specs under `sub`, and *counts the ones
    # it dropped* (`stats.outside_root`) so an empty selection can say "3
    # changed spec files, all outside this directory" instead of the falsehood
    # "nothing in the diff matched".
    #
    # Paths come back from `git diff -z`: NUL-separated, and therefore never
    # quoted. Without `-z`, `core.quotePath` (on by default) renders
    # `spec/café_spec.rb` as the literal characters `"spec/caf\303\251_spec.rb"`,
    # quotes and all, which no longer names a file — an accented spec file would
    # be silently dropped and then misreported as "nothing changed".
    #
    # Known limitation: `git diff` cannot see **untracked** files, so a brand
    # new spec file that has not been `git add`ed is not selected. In CI (a
    # clean checkout of a commit) that cannot arise; locally the loud empty
    # selection is what surfaces it.
    module FileSelector
      # `test/**/*_test.rb` rather than `**/*_test.rb`: the `test/` directory
      # is where both Rails and Minitest itself put Minitest files, and
      # keeping the second convention scoped stops the walk from adopting
      # unrelated `*_test.rb` files elsewhere in the tree (fixture generators,
      # vendored code). `*_spec.rb` stays unscoped because `spec/` already has
      # no competitor convention to fence against.
      DEFAULT_GLOB = ["**/*_spec.rb", "test/**/*_test.rb"].freeze

      # The `--changed` counterparts of {DEFAULT_GLOB}: git hands back paths,
      # so the filter is a match over the whole path rather than a glob walk,
      # and the suffix alone decides. Deliberately not directory-scoped — a
      # changed Minitest file outside `test/` is still this client's business
      # in the one mode that answers "what did this branch touch".
      CHANGED_PATTERNS = ["*_spec.rb", "*_test.rb"].freeze

      # Ordered probes for the default branch when no explicit base is given.
      DEFAULT_BRANCH_REFS = %w[origin/HEAD origin/main origin/master main master].freeze

      # Why an empty `--changed` selection is empty. Every count is a filter
      # this class applied, in the order it applied them, so the CLI can name
      # the real cause instead of guessing at the last one.
      Stats = Data.define(:changed, :spec_matches, :outside_root, :unreadable) do
        def initialize(changed: 0, spec_matches: 0, outside_root: 0, unreadable: 0)
          super
        end
      end

      # What a selection produced, plus enough context to report it honestly.
      Selection = Data.define(:files, :mode, :base, :note, :stats) do
        def initialize(files:, mode:, base: nil, note: nil, stats: nil)
          super
        end

        def empty?
          files.empty?
        end

        def count
          files.length
        end
      end

      module_function

      # @param changed [Boolean] restrict to files in the diff
      # @param base [String, nil] explicit diff base; nil means "work it out"
      # @param root [String] directory to select within
      # @return [Selection]
      # @raise [UsageError] when `--changed` is used outside a git repository.
      #   Typed rather than a crash or a silent empty set: the exit-code
      #   contract makes this a misuse (2), and the CLI maps it later.
      def select(changed: false, base: nil, root: Dir.pwd)
        changed ? select_changed(base: base, root: root) : select_all(root: root)
      end

      # Every test file under `root`, recursively, in either naming
      # convention. Hidden directories are not traversed (no
      # `File::FNM_DOTMATCH`), so `.git` and friends are skipped.
      def select_all(root: Dir.pwd)
        files = Dir.glob(DEFAULT_GLOB, base: root).select { |f| File.file?(File.join(root, f)) }.sort
        Selection.new(files: files, mode: :all)
      end

      def select_changed(base: nil, root: Dir.pwd)
        unless git_repository?(root)
          raise UsageError, "--changed requires a git repository; #{root} is not inside one"
        end

        resolved, base_kind = base ? [base, :explicit] : default_base(root)
        unless resolved
          raise UsageError,
                "--changed could not determine a diff base (no #{DEFAULT_BRANCH_REFS.join(', ')} " \
                "and no HEAD commit); pass --changed=<base> explicitly"
        end

        # One memoized probe per run, shared by the two message branches that
        # consult it (a failed diff, a thin base note).
        is_shallow = shallow_probe(root)

        files, stats = changed_files(resolved, root, is_shallow)

        Selection.new(files: files, mode: :changed, base: resolved,
                      note: base_note(resolved, base_kind, root, is_shallow), stats: stats)
      end

      # Resolves git's repo-root-relative output into paths relative to `root`,
      # dropping (and counting) everything the two scoping rules exclude.
      # @return [[Array<String>, Stats]]
      def changed_files(base, root, is_shallow)
        names = diff_names(base, root, is_shallow)
        specs = names.select { |name| CHANGED_PATTERNS.any? { |pattern| File.fnmatch?(pattern, name) } }

        top = toplevel(root)
        prefix = directory_prefix(top.empty? ? root : top)
        root_prefix = directory_prefix(real_path(root))

        files = []
        outside = 0
        unreadable = 0
        specs.each do |name|
          absolute = prefix + name
          relative = strip_prefix(absolute, root_prefix)
          if relative.nil?
            outside += 1
          elsif !File.file?(absolute)
            unreadable += 1
          else
            files << relative
          end
        end

        [files.sort,
         Stats.new(changed: names.length, spec_matches: specs.length,
                   outside_root: outside, unreadable: unreadable)]
      end

      # `--diff-filter=d` drops deleted paths — `git diff --name-only` lists
      # them, and they then fail to open. `-z` makes the output machine-readable:
      # NUL-separated and never `core.quotePath`-quoted, so a non-ASCII path
      # survives intact and a path containing a newline cannot split a record.
      def diff_names(base, root, is_shallow)
        out, ok = git(%W[diff -z --name-only --diff-filter=d #{base} --], root)
        unless ok
          if is_shallow.call
            # SPGD-1035: in a shallow checkout the overwhelmingly likely cause
            # is that <base> is simply not in the clone's history (git's own
            # stderr says `fatal: bad object` / `unknown revision`), and the
            # fix is a fetch — a cause the bare message never named, leaving
            # "bad ref" and "shallow history" indistinguishable. Non-shallow
            # failures keep the original message.
            raise UsageError,
                  "--changed could not diff against #{base.inspect}: this checkout is shallow and " \
                  "#{base.inspect} is not in its history — fetch it (fetch-depth: 0, or " \
                  "git fetch origin #{base}) or pass a base the checkout contains"
          end
          raise UsageError, "--changed could not diff against #{base.inspect}"
        end

        out.split("\0").reject(&:empty?)
      end

      # The repository's top level — what `git diff`'s paths are relative to.
      # Empty when git cannot say, in which case the caller falls back to `root`
      # (the top level *is* root for the common case of running from there).
      def toplevel(root)
        out, ok = git(%w[rev-parse --show-toplevel], root)
        ok ? real_path(out.strip) : ""
      end

      # The merge base of HEAD with the default branch.
      # @return [[String, Symbol], nil] the base and how it was arrived at
      #   (`:merge_base`, or `:head_fallback` when no default-branch ref exists),
      #   or nil when there is no HEAD at all (a repository with no commits).
      def default_base(root)
        head, ok = git(%w[rev-parse --verify --quiet HEAD], root)
        return nil unless ok && !head.strip.empty?

        DEFAULT_BRANCH_REFS.each do |ref|
          resolved, found = git(%W[rev-parse --verify --quiet #{ref}], root)
          next unless found && !resolved.strip.empty?

          merge_base, ok = git(%W[merge-base HEAD #{ref}], root)
          return [merge_base.strip, :merge_base] if ok && !merge_base.strip.empty?
        end

        # Detached from any known default branch: fall back to HEAD, which
        # selects uncommitted work only. Better than selecting everything.
        [head.strip, :head_fallback]
      end

      # Explains a base that can only produce a thin selection, and — the point
      # of `base_kind` — distinguishes the two ways that happens. Both leave the
      # base at HEAD, but "this is a default-branch build" is normal and "no
      # default branch could be found" means `--changed` has quietly degraded to
      # `git diff HEAD`, i.e. the working-tree-vs-HEAD no-op this class exists
      # to avoid. Reporting the first when the second is true would be a
      # confidently wrong explanation.
      #
      # SPGD-1035: a shallow (depth-limited) checkout reproduces both thin
      # shapes with a third cause those two stories miss — the merge base with
      # the default branch is not in the clone's history at all — so whenever
      # the repo IS shallow the note tells that story and names the remedy
      # (fetch the default branch, or pass a base the checkout contains),
      # retiring the "default-branch build" guess for shallow repos in both
      # shapes.
      def base_note(resolved, base_kind, root, is_shallow)
        shallow_remedy =
          "fetch the default branch (fetch-depth: 0) or pass --changed=<base> naming a base this checkout contains"
        case base_kind
        when :head_fallback
          if is_shallow.call
            return "this checkout is a shallow (depth-limited) clone and no default-branch ref " \
                   "(#{DEFAULT_BRANCH_REFS.join(', ')}) is in its history, so the diff base fell " \
                   "back to HEAD; --changed can only select uncommitted changes here — #{shallow_remedy}"
          end

          "no default-branch ref (#{DEFAULT_BRANCH_REFS.join(', ')}) could be found, so the diff base " \
            "fell back to HEAD; --changed can only select uncommitted changes here"
        when :merge_base
          head, ok = git(%w[rev-parse HEAD], root)
          return nil unless ok && head.strip == resolved

          if is_shallow.call
            return "this checkout is a shallow (depth-limited) clone, so the merge base with the " \
                   "default branch is not in its history and the diff base is HEAD itself — only " \
                   "uncommitted changes can be selected; #{shallow_remedy}"
          end

          "the diff base is HEAD itself (this looks like a default-branch build), " \
            "so only uncommitted changes can be selected"
        end
      end

      # Memoized per-run `git rev-parse --is-shallow-repository` probe.
      # SPGD-1035: shallowness is consulted only in the branches where it
      # changes the message (a derived base of HEAD, a failed diff), so the
      # full-clone happy path makes zero new git invocations and the memo caps
      # the probe at one per run. An unreadable answer (old git without the
      # flag) reads as not shallow, keeping today's messages exactly.
      # @return [Proc] zero-argument; true iff git reports a shallow repository
      def shallow_probe(root)
        cached = nil
        lambda do
          if cached.nil?
            out, ok = git(%w[rev-parse --is-shallow-repository], root)
            cached = ok && out.strip == "true"
          end
          cached
        end
      end

      def git_repository?(root)
        out, ok = git(%w[rev-parse --is-inside-work-tree], root)
        ok && out.strip == "true"
      end

      # Runs git without a shell and without inheriting stderr into our output.
      # @return [[String, Boolean]] stdout and whether git exited 0
      def git(args, root)
        out, _err, status = Open3.capture3("git", *args, chdir: root)
        [out, status.success?]
      rescue SystemCallError
        # git not installed / not executable.
        ["", false]
      end

      # Symlink-resolved, so a `root` reached through a symlink still compares
      # equal to the physical path git reports.
      def real_path(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
      end

      def directory_prefix(path)
        path.end_with?(File::SEPARATOR) ? path : path + File::SEPARATOR
      end

      # Byte-wise, so a path git returned that is not valid in the prefix's
      # encoding cannot raise Encoding::CompatibilityError mid-selection. The
      # result is handed back in the path's own encoding.
      # @return [String, nil] `absolute` relative to `prefix`, or nil if outside
      def strip_prefix(absolute, prefix)
        bytes = absolute.b
        head = prefix.b
        return nil unless bytes.start_with?(head)

        bytes[head.bytesize..].force_encoding(absolute.encoding)
      end
    end
  end
end
