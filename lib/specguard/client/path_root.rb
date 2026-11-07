# frozen_string_literal: true

require "open3"
require "pathname"

module SpecGuard
  module Client
    # The directory a run's row paths are relative to: the git toplevel of the
    # working directory, so a run started from a gem/engine subdirectory of a
    # monorepo (`gems/a`, `gems/b`) ships `gems/a/spec/util_spec.rb`, not
    # `spec/util_spec.rb`. Two packages each holding `spec/util_spec.rb` would
    # otherwise ship identical `file_path`/`id` values, and the platform's
    # per-run upsert keeps one writer's rows and drops the other's.
    #
    # This is the Ruby twin of specguard-ts's `resolveRunRoots()` (SPGD-2105).
    # Like that, it is two values, not one: the clients keep reading spec
    # SOURCE (annotation lookup) from the working directory — the cwd-relative
    # spelling — and only SHIP paths relative to the path root. Collapsing the
    # two would resolve a repo-relative spelling against the cwd and ship
    # every annotated spec of a subdirectory run as `unannotated`.
    #
    # Falls back to the working directory itself when git is absent, the
    # directory is not in a repository, or the reported toplevel does not
    # contain it (compared by real path, so a symlinked tmpdir such as macOS
    # `/var` vs `/private/var` does not read as "outside"). In that case —
    # and when the cwd *is* the toplevel — the answer is the cwd string
    # exactly as given, so output is byte-identical to a run with no path
    # root at all.
    module PathRoot
      module_function

      # The repository's top level, as a real path.
      # @param dir [String] where to ask git from
      # @return [String, nil] nil when git cannot say
      def toplevel(dir)
        out, _err, status = Open3.capture3("git", "rev-parse", "--show-toplevel", chdir: dir)
        return nil unless status.success?

        top = out.strip
        top.empty? ? nil : real_path(top)
      rescue SystemCallError
        # git not installed / not executable / `dir` unreadable.
        nil
      end

      # The path root for a run started in `cwd`.
      #
      # Returned in the spelling of `cwd` (an ancestor of it, so absolute paths
      # the test framework built through the same spelling still start with
      # it) whenever that spelling can be recovered; the real toplevel
      # otherwise.
      # @param cwd [String]
      # @return [String]
      def resolve(cwd)
        top = toplevel(cwd)
        return cwd if top.nil?

        real_cwd = real_path(cwd)
        return cwd if real_cwd == top
        return cwd unless real_cwd.start_with?(top.end_with?("/") ? top : "#{top}/")

        suffix = real_cwd.delete_prefix(top)
        cwd.end_with?(suffix) ? cwd.delete_suffix(suffix) : top
      end

      # The working directory relative to the path root; empty when they are
      # the same directory.
      def prefix(cwd, root)
        return "" if cwd == root

        cwd.delete_prefix("#{root}/")
      end

      # A path as the test framework spells it relative to the working
      # directory (or absolute, for a file outside it), re-expressed relative
      # to the path root. With an empty `prefix` the two roots coincide and
      # the path is returned untouched.
      #
      # An absolute path under the root loses the root; an absolute path
      # outside it, or a relative one that climbs out of it, keeps today's
      # spelling.
      def rebase(path, root:, prefix:)
        return path if prefix.empty?

        if path.start_with?("/")
          path.start_with?("#{root}/") ? path.delete_prefix("#{root}/") : path
        else
          joined = Pathname.new(File.join(prefix, path)).cleanpath.to_s
          joined.start_with?("../") || joined == ".." ? path : joined
        end
      end

      def real_path(path)
        File.realpath(path)
      rescue SystemCallError
        File.expand_path(path)
      end
    end
  end
end
