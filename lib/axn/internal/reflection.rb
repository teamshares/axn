# frozen_string_literal: true

require "axn/internal/reflection/schema"
require "axn/internal/reflection/values"
require "axn/internal/reflection/property_names"

module Axn
  module Internal
    # The layer that derives a JSON view of a contract: the JSON Schema behind
    # `input_schema`/`output_schema` (Schema), the JSON-safe rendering behind
    # Axn::Extensions::Serialization.render (Values), and the property-name rules both are judged
    # against (PropertyNames). PropertyNames is also reached directly from the contract's own
    # declaration walk (duplicate-name and unrenderable-name checks), not only from Schema.
    #
    # Building and validating a schema, and rendering a result, all run off the execution path — but
    # Schema and PropertyNames each keep one narrow judgment shared with it: ContractForSubfields'
    # model-field reader consults Schema.usable_id_token_default? once, to resolve an omitted
    # `<field>_id` when that field first resolves (the reader is memoized, so this never repeats within
    # one action instance), and CallLogger and the executor's validation-failure messages reuse
    # PropertyNames.renderable_label to name a field — but only when there is one to name: a logged call
    # with no context data, or a failure with no stranded nil ancestor, never reaches it. Values has no
    # such foothold — an axn's own `.call` never reaches it, only the calling app's explicit
    # Serialization.render and the contract's declaration-time duplicate-name check.
    #
    # Internal::ResolvedSubfields depends on this layer (composing a SubfieldTree with
    # Schema.derive_annotations) without being a member of it: deriving those annotations is its whole
    # purpose, and Core:: reads it on the runtime read path that this namespace's members otherwise
    # stay off of.
    #
    # Not an adapter surface: a gem building on axn reads a schema through `axn_class.input_schema` and
    # renders a result through Axn::Extensions::Serialization.render, reaching for nothing here.
    module Reflection
    end
  end
end
