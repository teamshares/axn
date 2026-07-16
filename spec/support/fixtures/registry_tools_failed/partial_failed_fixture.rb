# frozen_string_literal: true

# Defines and registers an Axn `tool` class, THEN raises after the class body — proving
# ensure_loaded! rolls back classes registered by a file that fails later in the same require
# (spec/axn/tools/registry_spec.rb).
module FailedFixture
  class PartialTool
    include Axn
    tool

    def call = nil
  end
end

raise "boom after class body"
