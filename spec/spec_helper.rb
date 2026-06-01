# frozen_string_literal: true
#
# This spec_helper is intentionally minimal. The module is tested with
# `regent test`, which ships its own embedded RSpec-like DSL on Artichoke
# Ruby. The supported expectations are:
#
#   is_expected.to compile
#   is_expected.to contain_<resource_type>('<title>').with(<attrs>)
#
# rspec-puppet helpers like `with_all_deps`, `that_requires`,
# `and_raise_error`, and `not_to` are NOT available under regent and
# must not be used in spec files for this module.
