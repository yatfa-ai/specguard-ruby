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
    # Both modes carry a fixed directory fence ({SKIPPED_DIRECTORIES}):
    # dependency, build-output, scratch and VCS directories are never
    # selected, so a bundled tree's `vendor/bundle/` gem specs are neither
    # reported on nor failed over — third-party code the user did not write.
    # The walk, which must keep working outside a repository, carries the
    # boundary as a name list; `--changed` applies the same name list to the
    # paths git hands back, because a tracked file is never subject to
    # `.gitignore` and the diff leg therefore has no fence of its own.
    # `--exclude-standard` additionally removes ignored *untracked* paths —
    # it stacks with the name list in `--changed` and is no substitute for it.
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
    # == Untracked files are selected too
    #
    # `git diff` cannot see a file that has never been `git add`ed — but "what
    # this branch changed, whether or not the change is committed yet" covers a
    # never-added file, and a mode that silently skipped it would ride the
    # branch's newest spec past the gate: in the mixed shape every real working
    # tree has (a tracked edit somewhere, the new spec still untracked), the
    # selection was non-empty without the new file, so the loud-empty machinery
    # never fired and the defect shipped behind a checked-count reporting
    # success.
    #
    # So the `--changed` name set is a union: the diff's paths plus ONE
    # `git ls-files --others --exclude-standard -z` call per selection, run at
    # the toplevel so its repo-root-relative output flows through the same
    # scoping as the diff's (from a subdirectory `ls-files` emits
    # cwd-relative paths, which would defeat it). `--exclude-standard` is the
    # untracked leg's boundary: `.gitignore`d paths — scratch directories,
    # vendored code, build output — never enter through it. It is a second
    # removal, not the selection's only fence: ignored *tracked* paths still
    # arrive on the diff leg (git never applies ignore rules to tracked
    # files), which is why the {SKIPPED_DIRECTORIES} fence applies to the
    # union as a whole. The two legs are disjoint by
    # construction (an untracked path is never a diff path), so the union
    # cannot double-count; {Stats.untracked} says how many of the selected
    # files arrived via the untracked leg, and the empty-reason ladder's
    # "nothing changed against <base>" can now only fire when the working tree
    # is genuinely clean. That `ls-files` call is the untracked leg's entire
    # added cost, and it is scoped to this mode — the "zero new git
    # invocations on the full-clone happy path" property SPGD-1035 established
    # belongs to the lazy shallow probe alone, not to `--changed` as a whole.
    module FileSelector
      # `test/**/*_test.rb` rather than `**/*_test.rb`: the `test/` directory
      # is where both Rails and Minitest itself put Minitest files, and
      # keeping the second convention scoped stops the walk from adopting
      # unrelated `*_test.rb` files elsewhere in the tree (fixture generators,
      # vendored code). `*_spec.rb` stays unscoped because `spec/` already has
      # no competitor convention to fence against.
      DEFAULT_GLOB = ["**/*_spec.rb", "test/**/*_test.rb"].freeze

      # A named-file default-walk fence, ported from this product's own
      # TypeScript answer (`specguard-ts` `src/lint/discover.ts`
      # `SKIPPED_DIRECTORIES`, widened by the Ruby ecosystem's members). Every
      # member is dependency, build-output, scratch or VCS material — code the
      # user did not write and cannot edit, whose specs must never be selected:
      #
      #   * `node_modules` — npm dependencies (the port's founding member).
      #   * `.git` — VCS internals; `Dir.glob` already skips hidden
      #     directories, so this is belt-and-braces, named so the fence reads
      #     complete beside its TypeScript twin.
      #   * `dist` — build output.
      #   * `.test-build` — this project family's own build/test scratch.
      #   * `coverage` — SimpleCov's default report directory.
      #   * `vendor` — a bundled Rails tree (`bundle install --deployment`)
      #     puts every gem under `vendor/bundle/`, each shipping its own
      #     specs; the measured failure this fence exists for.
      #   * `tmp` — Rails' scratch directory (caches, pids, sockets).
      #   * `log` — Rails' log directory.
      #
      # `--changed` applies this same list itself: a tracked file is never
      # subject to `.gitignore`, so `--exclude-standard` — which keeps
      # `.gitignore`d paths (scratch directories, vendored code, build
      # output) out of the untracked leg alone — cannot fence the diff leg
      # and is an additional removal, never a substitute. The walk has no
      # git to ask, because it must keep working outside a repository exactly
      # where `--changed` correctly refuses, so it carries the boundary as a
      # name list too. The list
      # is matched against whole directory SEGMENTS of the root-relative path
      # (see {skipped_directory?}), never as a substring — `spec/vendor_helpers/`
      # is project code — and never against the absolute path.
      SKIPPED_DIRECTORIES = %w[
        node_modules
        .git
        dist
        .test-build
        coverage
        vendor
        tmp
        log
      ].freeze

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
      # the real cause instead of guessing at the last one. The exception is
      # `untracked`, which filters nothing: it counts the selected files that
      # arrived via the untracked leg, so the report can say where a file the
      # diff never saw came from (an untracked spec outside `root` is counted
      # in `outside_root`, not here — this names files the run checked).
      Stats = Data.define(:changed, :spec_matches, :outside_root, :unreadable, :untracked) do
        def initialize(changed: 0, spec_matches: 0, outside_root: 0, unreadable: 0, untracked: 0)
          super
        end
      end

      # What a selection produced, plus enough context to report it honestly.
      #
      # `skipped` is the {SKIPPED_DIRECTORIES} fence count, carried by BOTH
      # selection modes — `:all`'s walk and `:changed`'s union alike; an
      # `:explicit` selection bypasses the fence and always reads 0 —
      # defaulted to 0 so every construction site is untouched. It
      # deliberately rides `Selection` rather than a new `Stats` member:
      # `Stats` is documented as the `--changed` empty-reason ladder ("why an
      # empty `--changed` selection is empty") and the fence is not an
      # emptiness explanation — it is report context for a selection that may
      # be perfectly full. `Selection` is what this file already uses to
      # carry per-mode context (`base`, `note`, `stats` are all
      # `--changed`-only and defaulted the same way), so the count follows
      # that precedent instead of widening `Stats`'s contract.
      Selection = Data.define(:files, :mode, :base, :note, :stats, :skipped) do
        def initialize(files:, mode:, base: nil, note: nil, stats: nil, skipped: 0)
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
      # convention, minus anything whose path runs through a
      # {SKIPPED_DIRECTORIES} directory. Hidden directories are not traversed
      # (no `File::FNM_DOTMATCH`), so `.git` and friends are skipped.
      #
      # The fence is decided on the path `Dir.glob(base: root)` yields —
      # already relative to `root` — never on an absolute path: fixture roots
      # (and the whole spec suite's) live under `Dir.mktmpdir`, i.e. inside a
      # directory *named* `tmp`, and a fence reading absolute paths would
      # drop every file in the tree. How many files the fence removed is
      # carried on the `Selection` (`skipped`) so the CLI can disclose the
      # narrowing instead of doing it silently.
      def select_all(root: Dir.pwd)
        candidates = Dir.glob(DEFAULT_GLOB, base: root).select { |f| File.file?(File.join(root, f)) }.sort
        kept, fenced = candidates.partition { |f| !skipped_directory?(f) }
        Selection.new(files: kept, mode: :all, skipped: fenced.length)
      end

      # Whether a root-relative path runs through a {SKIPPED_DIRECTORIES}
      # directory. Whole segments only — `File::SEPARATOR`-delimited — so a
      # directory merely *named after* a fenced word (`spec/vendor_helpers/`)
      # is not fenced, and the basename is excluded from the segment set: a
      # path's last component is the file itself, so `spec/tmpfile_spec.rb`
      # is selected whatever its name contains.
      def skipped_directory?(path)
        segments = path.split(File::SEPARATOR)
        segments.pop
        segments.any? { |segment| SKIPPED_DIRECTORIES.include?(segment) }
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

        files, stats, skipped = changed_files(resolved, root, is_shallow)

        Selection.new(files: files, mode: :changed, base: resolved,
                      note: base_note(resolved, base_kind, root, is_shallow), stats: stats,
                      skipped: skipped)
      end

      # Resolves git's repo-root-relative output into paths relative to `root`,
      # dropping (and counting) everything the scoping rules and the
      # {SKIPPED_DIRECTORIES} fence exclude. The
      # name set is the union of the diff leg and the untracked leg; each name
      # is tagged with its leg so {Stats.untracked} can attribute the selected
      # files the diff never saw. The legs are disjoint by construction (an
      # untracked path is never a diff path), so the plain union cannot
      # double-count and needs no dedup.
      # @return [[Array<String>, Stats, Integer]] the selected files, the
      #   filter stats, and how many files the directory fence removed.
      def changed_files(base, root, is_shallow)
        names = diff_names(base, root, is_shallow).map { |name| [name, false] }

        top = toplevel(root)
        names += untracked_names(top.empty? ? root : top).map { |name| [name, true] }

        specs = names.select { |(name, _)|
          CHANGED_PATTERNS.any? { |pattern| File.fnmatch?(pattern, name) }
        }

        prefix = directory_prefix(top.empty? ? root : top)
        root_prefix = directory_prefix(real_path(root))

        files = []
        outside = 0
        unreadable = 0
        untracked = 0
        skipped = 0
        specs.each do |(name, was_untracked)|
          absolute = prefix + name
          relative = strip_prefix(absolute, root_prefix)
          if relative.nil?
            outside += 1
          elsif !File.file?(absolute)
            unreadable += 1
          elsif skipped_directory?(relative)
            # The same {SKIPPED_DIRECTORIES} fence {select_all} applies,
            # decided on the root-relative path at the same grain. It sits
            # after the scoping arms so it counts a different exclusion and
            # never perturbs `outside_root`/`unreadable`; because the union
            # is already materialized here, one placement covers BOTH legs —
            # the diff leg (where `.gitignore` cannot act, git never applies
            # ignore rules to tracked files) and the untracked leg on a
            # repository that does not ignore its vendored tree.
            skipped += 1
          else
            files << relative
            untracked += 1 if was_untracked
          end
        end

        [files.sort,
         Stats.new(changed: names.length, spec_matches: specs.length,
                   outside_root: outside, unreadable: unreadable, untracked: untracked),
         skipped]
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

      # The untracked leg of `--changed`: every file git does not track, minus
      # what `--exclude-standard` excludes (`.gitignore`, `.git/info/exclude`,
      # the global excludes file). Run at the toplevel, where `ls-files` emits
      # repo-root-relative paths — from a subdirectory it emits cwd-relative
      # ones, which would break the root-scoping the diff leg's output goes
      # through. `-z` for the same reason as {diff_names}: NUL-separated and
      # never `core.quotePath`-quoted. Without `--directory` git lists the
      # files inside an untracked directory rather than the directory itself,
      # which is what the suffix filter wants. `ls-files` reads the working
      # tree and the index only — no history — so the leg works in a shallow
      # clone where the diff base barely exists. A failure degrades to an
      # empty leg rather than failing the run: the repository was already
      # verified, the tracked diff above remains the primary evidence, and a
      # half-readable working tree must not kill a gate that would otherwise
      # check every tracked spec.
      def untracked_names(chdir)
        out, ok = git(%w[ls-files --others --exclude-standard -z], chdir)
        ok ? out.split("\0").reject(&:empty?) : []
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
      # probe makes zero new git invocations of its own on the full-clone
      # happy path, and the memo caps it at one per run. (That zero is the
      # probe's, not the mode's: the untracked leg adds its one `ls-files`
      # call to every `--changed` selection, whatever the clone's depth.) An
      # unreadable answer (old git without the flag) reads as not shallow,
      # keeping today's messages exactly.
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
