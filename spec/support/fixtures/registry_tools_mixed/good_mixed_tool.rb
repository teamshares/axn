# frozen_string_literal: true

# Loaded only via Axn::Tools::Registry.ensure_loaded! in the mixed-fixture regression test,
# alongside a sibling file that raises at load time.
module RegistryFixturesMixed
  class GoodMixedTool
    include Axn
    tool

    def call = nil
  end
end
