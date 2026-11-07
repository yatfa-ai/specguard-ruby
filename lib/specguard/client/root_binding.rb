# frozen_string_literal: true

require_relative "path_root"

module SpecGuard
  module Client
    # The class-level root binding shared by the RSpec formatter and the
    # Minitest reporter: `repo_root`, `path_root` and `path_prefix`.
    #
    # Both clients carried the same three methods, differing only in their
    # comments, and every fix to the one-binding discipline had to land once
    # per client (SPGD-1408/1421 for Minitest, SPGD-1429 for RSpec, SPGD-2109
    # in both). One definition here means a binding fix cannot reach one
    # client and miss the other.
    #
    # Use with `extend`, never `include`: the methods run with the CLASS as
    # `self`, so the memos stay class-level ivars (`@repo_root`,
    # `@path_root_binding`) on each client. Specs that save, clear and restore
    # them on the client class depend on that.
    module RootBinding
      # `Dir.pwd` bound once — by the first client construction (whose
      # `#initialize` reads it, SPGD-1421 / SPGD-1429) or the first direct
      # read — never per row: a suite that changes the working directory after
      # the client was built would otherwise relativize one run's rows against
      # two different roots. The memo is what binds it — an unmemoized
      # `Dir.pwd` here re-reads the cwd on every read and is exactly the
      # two-root split the constructors' comments name, with both spellings
      # individually well-formed so nothing downstream can detect the drift.
      # The memo is also the ONE value the annotation lookup reads against:
      # `#initialize` hands it over, so the relativization root and the
      # lookup's read root cannot drift apart the way they did when each bound
      # `Dir.pwd` at its own moment.
      def repo_root
        @repo_root ||= Dir.pwd
      end

      # The directory every shipped row path is relative to (SPGD-2109): the
      # git toplevel of {#repo_root}, or {#repo_root} itself outside a
      # repository. Derived from the ONE bound {#repo_root} and probed once
      # per binding — the same one-binding discipline, so a run started from a
      # monorepo package subdirectory ships `gems/a/spec/x_spec.rb` rather
      # than a name every sibling package shares. {#repo_root} stays the READ
      # root (the annotation lookup resolves spec source against it); the two
      # are deliberately not one value.
      def path_root
        bound = repo_root
        @path_root_binding = nil unless @path_root_binding&.first == bound
        (@path_root_binding ||= [bound, SpecGuard::Client::PathRoot.resolve(bound)]).last
      end

      # {#repo_root} relative to {#path_root}; empty when they coincide.
      def path_prefix
        SpecGuard::Client::PathRoot.prefix(repo_root, path_root)
      end
    end
  end
end
