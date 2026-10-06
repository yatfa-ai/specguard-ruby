#!/usr/bin/env bash
# Bump the patch version, commit, push to main, and tag vX.Y.Z on what landed.
#
# Mirrors yatfa's script/bump-version.sh, adapted for a gem:
#   - the version source is lib/specguard/version.rb (the gemspec reads
#     SpecGuard::VERSION from it; lib/specguard/rspec/version.rb is a back-compat
#     alias that follows it), not a VERSION file
#   - release is tag-based like warden's: the GitHub Release and the pushed gem
#     both correspond to vX.Y.Z. There is no `prod` deploy-mirror branch —
#     nothing here is deployed to a cluster.
#
# Strategy carried over verbatim: must be on main with a clean tree, patch-only
# bump, commit "bump: X -> Y", pull --rebase + push with up to 3 retries.
#
# When run inside GitHub Actions (GITHUB_OUTPUT set), exports `version` and
# `tag` to the step's job outputs. Locally it just prints the new version.
set -e

VERSION_FILE="lib/specguard/version.rb"

# Ensure we're on the main branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$CURRENT_BRANCH" != "main" ]; then
    echo "Error: Not on main branch. Current branch: $CURRENT_BRANCH"
    exit 1
fi

# Check that no TRACKED file has uncommitted changes. Untracked files are not
# a reason to refuse: this runs in CI right after the suite, where
# ruby/setup-ruby's bundler-cache rewrites Gemfile.lock (untracked here, see
# .gitignore) and the suite itself may leave artefacts behind. What must be
# clean is the content the bump is about to commit on top of.
if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
    echo "Error: tracked files have uncommitted changes:"
    git status --porcelain --untracked-files=no
    exit 1
fi

if [ ! -f "$VERSION_FILE" ]; then
    echo "Error: $VERSION_FILE not found"
    exit 1
fi

CURRENT_VERSION=$(ruby -e 'require "./lib/specguard/rspec/version"; print SpecGuard::RSpec::VERSION')
echo "Current version: $CURRENT_VERSION"

# Bump patch version (0.2.0 -> 0.2.1)
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
echo "New version: $NEW_VERSION"

# A published gem version is immutable — RubyGems refuses a re-push and yanking
# does not free the number. Refuse locally rather than discovering it after a
# build, and refuse a reused tag for the same reason the release does.
if git rev-parse -q --verify "refs/tags/v$NEW_VERSION" >/dev/null || \
   git ls-remote --exit-code --tags origin "refs/tags/v$NEW_VERSION" >/dev/null 2>&1; then
    echo "Error: tag v$NEW_VERSION already exists — the version file and the tags disagree"
    exit 1
fi
if command -v curl >/dev/null 2>&1; then
    if curl -fsS --max-time 10 "https://rubygems.org/api/v1/versions/specguard-ruby.json" 2>/dev/null \
       | grep -q "\"number\":\"$NEW_VERSION\""; then
        echo "Error: specguard-ruby $NEW_VERSION is already published on RubyGems"
        exit 1
    fi
fi

# Rewrite the VERSION constant in place. A targeted sed on the one line, so the
# surrounding file (frozen_string_literal, module nesting) is untouched.
sed -i.bak -E "s/(VERSION = \")[0-9]+\.[0-9]+\.[0-9]+(\")/\1$NEW_VERSION\2/" "$VERSION_FILE"
rm -f "$VERSION_FILE.bak"
WROTE=$(ruby -e 'load "./lib/specguard/rspec/version.rb"; print SpecGuard::RSpec::VERSION')
if [ "$WROTE" != "$NEW_VERSION" ]; then
    echo "Error: $VERSION_FILE still reports $WROTE after the rewrite"
    exit 1
fi

# Create commit
git add "$VERSION_FILE"
git commit -m "bump: $CURRENT_VERSION -> $NEW_VERSION"

# Pull with rebase to incorporate any commits that landed on main since checkout,
# then push the branch and the tag. Retry up to 3 times to handle concurrent pushes.
#
# The tag is created INSIDE the loop, after `git push origin main` succeeds, and
# never before the rebase. `git pull --rebase` replays the bump commit onto the
# advanced main and gives it a new SHA; tags do not follow a rebase, so a tag
# created beforehand would name an abandoned object that is not an ancestor of
# main — while the workflow builds the gem from the post-rebase tree. A published
# gem version is immutable, so that divergence would be permanent.
#
# `-f` makes a retry idempotent when an earlier attempt created the local tag but
# failed to push it. It cannot clobber a published tag: the tag-reuse guard above
# already refused that case before any work started.
MAX_RETRIES=3
RETRY_COUNT=0
PUSH_SUCCESS=false

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if git pull --rebase origin main; then
        # HEAD is now the rebased bump commit — the object the tag must name.
        if git push origin main; then
            git tag -f "v$NEW_VERSION" HEAD
            if git push origin "v$NEW_VERSION"; then
                PUSH_SUCCESS=true
                break
            fi
        fi
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
        echo "Push failed, retrying ($RETRY_COUNT/$MAX_RETRIES)..."
        sleep 5
    fi
done

if [ "$PUSH_SUCCESS" = false ]; then
    echo "Error: Failed to push version bump after $MAX_RETRIES attempts"
    exit 1
fi

echo "Version bumped to $NEW_VERSION and pushed to main with tag v$NEW_VERSION"

# Export to GitHub Actions job outputs when run in CI
if [ -n "$GITHUB_OUTPUT" ]; then
    echo "version=$NEW_VERSION" >> "$GITHUB_OUTPUT"
    echo "tag=v$NEW_VERSION" >> "$GITHUB_OUTPUT"
fi
