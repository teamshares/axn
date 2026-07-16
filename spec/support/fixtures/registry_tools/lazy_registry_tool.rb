# frozen_string_literal: true

# Loaded only via Axn::Tools::Registry.ensure_loaded! in the require-fallback test.
module RegistryFixtures
  class LazyRegistryTool
    include Axn
    tool

    def call = nil
  end
end
