# frozen_string_literal: true

# Deliberately raises LoadError (not a StandardError) at load time to prove ensure_loaded!
# isolates per-file failures even when the failure is a LoadError, not just a StandardError
# (spec/axn/tools/registry_spec.rb).
require "definitely_missing_dependency_xyz"
