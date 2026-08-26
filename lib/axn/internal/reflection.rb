# frozen_string_literal: true

require "axn/internal/reflection/pattern"
require "axn/internal/reflection/schema"
require "axn/internal/reflection/values"
require "axn/internal/reflection/property_names"

module Axn
  module Internal
    # The layer that derives a JSON view of a contract: the JSON Schema behind
    # `input_schema`/`output_schema` (Schema), the JSON-safe rendering behind
    # Axn::Extensions::Serialization.render (Values), the property-name rules both are judged
    # against (PropertyNames), and the Ruby-Regexp-to-ECMA-262 translation behind a `format:` field's
    # emitted `pattern` (Pattern).
    #
    # PropertyNames is also reached directly from the contract's own
    # declaration walk (duplicate-name and unrenderable-name checks, and the subfield-contradiction
    # check's dead-tolerance diagnosis in Core::Contract::SubfieldContradictions), not only from Schema.
    #
    # Building and validating a schema, and rendering a result, all run off the execution path — but
    # Schema and PropertyNames each keep narrow judgments shared with it: Schema.usable_id_token_default?
    # is reached from three distinct runtime call sites — the model field's own reader (via
    # resolve_model_via_id), its `<field>_id` companion reader, and the executor's model-consistency
    # check — and each bounds it to at most one evaluation per action instance on its own terms: the
    # first two through their reader's own memoization, the third by running inside inbound validation's
    # single pass rather than a repeated one. CallLogger, the executor's validation-failure messages, the
    # shape validator's runtime member-validation errors, Core::Context::FacadeInspector#rendered_field_name,
    # and Core::SchemaReflection#_schema_name_label all reuse PropertyNames.renderable_label to name a
    # field. Most of those are conditional — a logged call with no context data, a failure with no
    # stranded nil ancestor, a shape member that reads and validates cleanly, or a class with no dropped
    # deep subfield (and, for that last one, only once per class even when there is one) never reaches
    # it. FacadeInspector's is not: `result.inspect` calls it for every declared field on every result,
    # success included, with no condition to short-circuit. Values has no such foothold — an axn's own
    # `.call` never reaches it, only the calling app's explicit Serialization.render and the contract's
    # declaration-time duplicate-name check.
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
