# frozen_string_literal: true

# Loaded only via Axn::Tools::Registry.ensure_loaded! in the failed-fixture rollback test,
# alongside a sibling file that registers an Axn class then raises AFTER the class body.
module GoodFailedFixture
  class Ok
    include Axn
    tool

    def call = nil
  end
end
