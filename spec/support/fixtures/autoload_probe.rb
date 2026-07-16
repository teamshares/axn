# frozen_string_literal: true

# Sentinel fixture: records that it was loaded so specs can prove that registry pruning does NOT
# trigger this pending autoload. Never required directly — only via AutoloadProbe.autoload.
ENV["AXN_AUTOLOAD_PROBE_LOADED"] = "1"

module AutoloadProbe
  class Thing
    def self.probe = :loaded
  end
end
