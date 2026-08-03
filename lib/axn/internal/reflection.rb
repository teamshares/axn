# frozen_string_literal: true

require "axn/internal/reflection/coercion"
require "axn/internal/reflection/schema"
require "axn/internal/reflection/resolved_subfields"
require "axn/internal/reflection/values"
require "axn/internal/reflection/property_names"

module Axn
  module Internal
    # Core-internal machinery for describing, checking, and rendering a contract: the JSON Schema behind
    # `input_schema`/`output_schema` (Schema), the JSON-safe rendering behind
    # Axn::Extensions::Serialization.render (Values), the inbound wire decoding a `coerce:` field runs during
    # validation (Coercion), and the subfield resolution a declaration is checked against (SubfieldTree,
    # SubfieldContradictions, ResolvedSubfields).
    #
    # Not an adapter surface: a gem building on axn reads a schema through `axn_class.input_schema` and renders
    # a result through Axn::Extensions::Serialization.render, reaching for nothing here. Members also differ in
    # when they run — Schema and Values are off the execution path, while Coercion runs inside validation — so
    # the name describes the family loosely rather than a guarantee they share.
    module Reflection
    end
  end
end
