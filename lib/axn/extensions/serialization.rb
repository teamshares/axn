# frozen_string_literal: true

# Declared rather than inherited from the top-level `axn` entrypoint's require order, for the reason
# axn/internal/reflection/values.rb gives about its own: the renderer is a runtime reference, so a standalone
# load of this file would NameError on the first call rather than at require time.
require "axn/internal/reflection/values"
require "axn/internal/reflection/property_names"
require "axn/internal/reflection/schema"
require "axn/internal/identity"
require "axn/internal/native_methods"

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
      # rendering, and (PRO-3284) a value whose own `as_json`/`to_h` displaces the member-keyed
      # projection its position in `output_schema` was reflected from — raises either way, since there
      # the schema and the body would actively disagree rather than merely being unpresentable.
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
        Axn::Internal::Reflection::Values.send(:serialize_exposed, result, configs, reject_opaque:,
                                                                                    guards: render_guards_for(action_class, configs))
      end

      # The render-time position map (PRO-3284), memoized beside `validate_outbound!`'s own verdict and on
      # the identical terms: keyed on the IDENTITY of `configs`, so a grown contract misses with no
      # invalidation hook to keep in sync, and skipped for a frozen class (whose configs cannot grow again
      # anyway). Building this once per class is the whole reason it exists — measured, rebuilding it on
      # every render costs roughly as much as the render itself — so an ordinary action with no Data/Struct
      # shape in its `exposes` gets nil back and pays nothing more per render than the identity check plus
      # one empty-array scan.
      #
      # `configs.equal?` alone is not the whole cache-validity question (Codex review, PR #296, round 4): a
      # DECLARED class that owned its own `as_json`/`to_h` at build time makes every position naming it
      # OPAQUE — no guard is built there at all — and if that method is later REMOVED (the class reopened,
      # not the config graph), `output_schema` immediately starts publishing the member-derived shape on its
      # next call (it re-validates every build), but a cached `nil`-guarded position can't retroactively gain
      # a guard object that was never constructed for it. `Schema.output_render_guards` therefore also hands
      # back `watched_classes` — every Data/Struct class it found opaque during the build — and a cache hit
      # additionally requires every one of those to STILL be opaque right now. This is intentionally
      # ONE-DIRECTIONAL: a class that GAINS an override after being guarded does not need this (`Values#
      # refuse_displaced_projection!` already re-checks the declared class live on every guarded value, so an
      # existing guard stands down safely rather than needing the whole plan rebuilt) — only "a position that
      # had no guard might now need one" can't be caught any other way.
      #
      # The SAME narrow consequence `validate_outbound!` states about a retained `shape:` graph mutated
      # after the first render — but stated plainly here rather than assumed identical, because the
      # OUTCOME differs: `validate_outbound!`'s stale verdict only delays a WARNING (`output_schema` is
      # rebuilt on every call and re-validates regardless), where a stale guard here means render can
      # SUCCEED where a fresh build would have refused — no other layer re-checks that. Reaching this
      # requires mutating axn's own SNAPSHOTTED shape graph (`_snapshot_declared_shape!` already deep-copies
      # away from whatever the caller declared with) IN PLACE, through `external_field_configs` directly —
      # the array itself is frozen and its `FieldConfig`/`ShapeConfig` elements are immutable `Data`, so the
      # only route in is reaching past both into a nested Hash nothing in the public DSL exposes a path to.
      # Accepted for the same reason `validate_outbound!`'s is: there is no invalidation signal cheaper than
      # the rebuild itself for an in-place mutation, and paying that rebuild unconditionally would cost every
      # ordinary render the ~2-3x this memo exists to avoid, to guard a route the supported API cannot reach.
      def render_guards_for(action_class, configs)
        # Bound ivar access (Codex review, PR #296, round 3), not a dispatched `instance_variable_get`/`set`:
        # `action_class` is a user-authored action class, so nothing stops it defining its own singleton
        # override of either — one returning a forged `[configs, nil]` would make the identity check
        # succeed and disable every displaced-projection guard silently, exactly what this feature exists
        # to prevent. `NativeMethods.ivar_get`/`ivar_set` read and write the real instance variable
        # regardless of what the class defines. The shape check below (`cached.is_a?(::Array) &&
        # cached.size == 3`) is a second, independent defense: it names a slot no other axn code writes
        # (`@_axn_render_guards`, following `validate_outbound!`'s own single-underscore class-ivar
        # precedent — `@_axn_config_sources`, `@_axn_config_overrides`, `@_axn_creating_action_class_for` are
        # all the same convention on the same kind of object), but an ACCIDENTAL same-named ivar from some
        # other source landing here fails safely into a rebuild rather than into `cached[1]` raising on a
        # value with the wrong shape.
        cached = Axn::Internal::NativeMethods.ivar_get(action_class, :@_axn_render_guards)
        if cached.is_a?(::Array) && cached.size == 3 && configs.equal?(cached[0]) &&
           cached[2].all? { |klass| Axn::Internal::Reflection::Values.displacing_projection(klass) }
          return cached[1]
        end

        guards, watched_classes = Axn::Internal::Reflection::Schema.output_render_guards(configs)
        unless Axn::Internal::NativeMethods.frozen?(action_class)
          Axn::Internal::NativeMethods.ivar_set(action_class, :@_axn_render_guards, [configs, guards, watched_classes])
        end
        guards
      end
      private_class_method :render_guards_for
    end
  end
end
