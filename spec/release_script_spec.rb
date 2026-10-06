# frozen_string_literal: true

require "spec_helper"

# script/bump-version.sh is the release path's only RubyGems immutability guard.
# It queries the registry for the gem by name; after the specguard-rspec ->
# specguard-ruby rename the guard kept asking for the old (404) slug, and because
# the curl is `-f ... 2>/dev/null` that 404 silently meant "not published" for
# every version. Pin the slug to the gemspec so a future rename cannot go blind.
RSpec.describe "script/bump-version.sh RubyGems guard" do
  let(:root) { File.expand_path("..", __dir__) }
  let(:script) { File.read(File.join(root, "script", "bump-version.sh")) }
  let(:gem_name) { Gem::Specification.load(File.join(root, "specguard-ruby.gemspec")).name }

  it "queries the RubyGems versions endpoint for the gemspec's own gem name" do
    expect(script).to include("versions/#{gem_name}.json")
  end

  it "no longer mentions the renamed-away specguard-rspec slug" do
    expect(script).not_to include("specguard-rspec")
  end
end
