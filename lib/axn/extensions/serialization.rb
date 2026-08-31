# frozen_string_literal: true

# Declared rather than inherited from the top-level `axn` entrypoint's require order, for the reason
# axn/internal/reflection/values.rb gives about its own: the renderer is a runtime reference, so a standalone
# load of this file would NameError on the first call rather than at require time.
require "axn/internal/reflection/values"
require "axn/internal/reflection/property_names"
require "axn/internal/identity"

module Axn
  module Extensions
    # The declared entry point for rendering a successful Result — the one serialization call an
    # adapter gem makes. Everything behind it is core's own: Axn::Internal::Reflection::Values holds the
    # rendering decisions, and a caller depending on one of them constrains core's routing.
    module Serialization
      module_function

      # A successful Result's exposures as a JSON-safe Hash keyed by wire key (a String), over the
      # action's declared `exposes`.
      #
      # The configs are DERIVED from the result rather than passed in. Rendering a subset is the only
      # thing an explicit list would allow, and a subset silently produces a body that no longer
      # matches the action's reflected output_schema — which is the promise this rendering keeps.
      #
      # `reject_opaque:` additionally rejects a value (or Hash key) that declares no rendering of its
      # own. Off by default, because such output is honest and complete, just not a shape its author
      # chose: whether that is a failure belongs to the transport, since an HTTP contract should not
      # ship it while an LLM tool result is better off ugly than failed. Everything unconditional — a
      # cycle, two names collapsing to one property, a non-finite Float, bytes with no UTF-8
      # rendering — raises either way.
      #
      # Raises Axn::Extensions::Serialization::UnserializableValue (an ArgumentError) naming the path to the
      # offending value, so an adapter's existing `rescue StandardError` maps it to an error response.
      def render(result, reject_opaque: false)
        # Read through a bound `Object#class` (`Internal::Identity.class_of`), not a dispatched
        # `.class` — `result.__action__` is a user-authored action instance, and nothing stops it
        # defining its own `#class` (axn's method-shadowing guards reserve `call`/`_run`/`initialize`,
        # not `class`). A dispatched `.class` returning a DIFFERENT class would fetch that OTHER
        # class's `external_field_configs` below and read those field names off THIS result instead
        # of its own — reproduced: a class with `def class = OtherToolClass` rendered a field
        # `OtherToolClass` declared and this action never exposed, silently returning `nil` for it
        # rather than raising.
        action_class = Axn::Internal::Identity.class_of(result.__action__)
        # The outbound property-name rules run before the first render of a class, not only before a schema:
        # a render-only adapter would otherwise learn about a collision from serialize_exposed's runtime
        # defense on a live call, which is a last line rather than a substitute for telling the author. Costs
        # one output-schema build on the first render and nothing after.
        Axn::Internal::Reflection::PropertyNames.validate_outbound!(action_class)

        configs = action_class.external_field_configs

        # `send` because serialize_exposed is private: this facade is its only caller, and that is
        # what makes `render` the rendering path rather than one of two.
        Axn::Internal::Reflection::Values.send(:serialize_exposed, result, configs, reject_opaque:)
      end
    end
  end
end
