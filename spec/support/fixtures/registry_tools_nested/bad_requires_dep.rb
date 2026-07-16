# frozen_string_literal: true

# Requires a valid sibling tool (registering NestedDep::Good), defines its OWN tool class, and
# THEN raises. ensure_loaded! must roll back only THIS file's class (NestedBad::Partial), leaving
# the required dependency (NestedDep::Good) registered (spec/axn/tools/registry_spec.rb).
require_relative "dep_good"

module NestedBad
  class Partial
    include Axn
    tool

    def call = nil
  end
end

raise "boom after requiring dep"
