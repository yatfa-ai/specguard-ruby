# frozen_string_literal: true

# The version of the `specguard-ruby` gem — one number for every adapter the
# gem ships. It lived in `SpecGuard::RSpec::VERSION` while the gem itself was
# `specguard-rspec` and rspec was the only adapter; the rename to a
# language-scoped client (mirroring `specguard-ts` and `specguard-go`) made a
# framework-scoped version constant a lie, so the number moved here and the
# rspec module now points at it for back-compat.
module SpecGuard
  VERSION = "0.3.5"
end
