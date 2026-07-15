# frozen_string_literal: true

# Deliberately raises a StandardError at load time to prove ensure_loaded! isolates
# per-file failures in the require-fallback path (spec/axn/tools/registry_spec.rb).
raise "boom"
