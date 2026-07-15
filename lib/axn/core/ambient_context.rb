# frozen_string_literal: true

require "axn/reflection/subfield_tree"

module Axn
  module Core
    # `ambient_context` is a reserved, always-present parent on every Axn. Its reader returns a Hash
    # ({} by default) that subfields extract from via `expects :x, on: :ambient_context`. Reads are
    # declaration-gated (a reader exists only for declared subfields), and the hash is filtered to the
    # declared ambient keys — along their declared PATHS (PRO-2909), so a deeply nested ambient
    # subfield resolves its value while the hash still never carries an undeclared sibling or a
    # process-wide dump of Current state.
    module AmbientContext
      PARENT = :ambient_context

      # Per-class cache slot for the ambient-scoped SubfieldTree: the subfield_configs array it was
      # built from plus the built tree. Validity is decided by comparing the array's IDENTITY (never
      # the value), mirroring ContractForSubfields#_resolved_subfields.
      AmbientSubfieldTreeCacheEntry = Data.define(:subfields, :value)

      def self.included(base)
        base.extend(ClassMethods)
      end

      module ClassMethods
        # The declared ambient sub-tree, used by `_filter_to_declared` to rebuild the filtered hash
        # along each declared path. Ambient subfields are deliberately ABSENT from the shared
        # `_resolved_subfields` tree — ambient is excluded from the input schema, and the executor /
        # contradiction / facade consumers rely on that absence — so this builds a SEPARATE tree from
        # the SAME `SubfieldTree.build` machinery (no re-derivation of path/alias resolution), scoped
        # to a synthetic `:ambient_context` root plus the ambient-rooted subfield configs. Cached by
        # `subfield_configs` identity: the store is copy-on-write via `+=` (same discipline as
        # `_resolved_subfields`), so any declaration rebuilds and an undeclaring subclass reuses the
        # superclass's tree.
        def _ambient_subfield_tree
          subfields = subfield_configs
          cached = @_axn_ambient_subfield_tree
          return cached.value if cached && cached.subfields.equal?(subfields)

          ambient = subfields.select { |c| _on_roots_at_ambient?(c.on) }
          value = Axn::Reflection::SubfieldTree.build([_synthetic_ambient_root], ambient)
          @_axn_ambient_subfield_tree = AmbientSubfieldTreeCacheEntry.new(subfields:, value:)
          value
        end

        # Declaration-time contradiction checks for the ambient subtree. Ambient configs are dropped
        # from the shared `_resolved_subfields` tree (it has no `:ambient_context` root), so the main
        # `SubfieldContradictions.check!` at the declaration site never sees them. Run the SAME checks
        # on the ambient-scoped CANDIDATE tree (prospective configs included, nothing committed — the
        # synthetic root plays the always-Hash ambient parent) so a nested ambient contract is rejected
        # at declaration exactly like its non-ambient twin (PRO-2909): e.g. `expects :request,
        # on: :ambient_context, type: String; expects :ip, on: :request` (a String parent can never
        # answer `ip`), or a nil-tolerant ambient parent with an unrescued required child.
        def _check_ambient_subfield_contradictions!(candidate_subfields)
          ambient = candidate_subfields.select { |c| _on_roots_at_ambient?(c.on) }
          return if ambient.empty?

          Axn::Reflection::SubfieldContradictions.check!([_synthetic_ambient_root], ambient)
        end

        private

        # The framework-supplied ambient parent, modeled for the ambient-scoped tree as an untyped
        # (always object-shaped) root reader — it never appears in provided_data or the input schema.
        def _synthetic_ambient_root
          Axn::Core::Contract::FieldConfig.new(field: PARENT, validations: {}, reader_as: PARENT)
        end
      end

      # Default ambient-context source: a live view over every registered `ActiveSupport::
      # CurrentAttributes`. Core filters the result down to each Axn's declared ambient keys
      # (see `_filter_to_declared`), so returning everything here is safe — undeclared keys are
      # never readable and never injected.
      def self.default_source
        return {} unless defined?(ActiveSupport::CurrentAttributes)

        ActiveSupport::CurrentAttributes.descendants.each_with_object({}) do |klass, acc|
          # When two CurrentAttributes classes declare the same attribute, last-descendant-wins
          # silently (by design per spec — core filters to declared keys downstream, so undeclared
          # collisions never surface).
          acc.merge!(klass.instance.attributes)
        end
      end

      # Instance reader used by ContractForSubfields.resolve_parent (public_send(:ambient_context)).
      #
      # A failing provider is memoized as an ERROR (not `{}`) and re-raised on every subsequent read.
      # This matters because automatic BEFORE-logging can be the FIRST read (a dynamic `sensitive:`
      # predicate reading an ambient subfield is evaluated while building the log filter) — and
      # `CallLogger` SWALLOWS logging errors. Memoizing `{}` there would hide the real failure from
      # inbound validation (which reads ambient_context next) and report a bogus "can't be blank"
      # instead of the provider's actual exception. Memoizing the error instead means the provider
      # still runs at most once, but the real error surfaces at the first NON-swallowed read.
      def ambient_context
        raise @__ambient_context_error if defined?(@__ambient_context_error)
        return @__ambient_context if defined?(@__ambient_context)

        begin
          @__ambient_context = _resolve_ambient_context
        rescue StandardError => e
          @__ambient_context_error = e
          raise
        end
      end

      private

      # Resolution chain: explicit `ambient_context:` kwarg (even when explicitly `nil`), else the
      # configured provider (or `default_source` when no provider is configured), else {}. Explicit
      # REPLACES the provider entirely — no merge — which requires distinguishing "key absent" from
      # "key present but nil"; a plain `nil` check can't tell those apart, since both read as `nil`.
      # The result is filtered to declared ambient subfield keys.
      def _resolve_ambient_context
        # No declared ambient subfield (at any depth) → skip provider resolution entirely (Bug Z1's
        # short-circuit). The ambient-scoped tree is the single source of "what roots at ambient", so
        # this stays correct for dotted/nested forms where `c.on` is not literally `:ambient_context`.
        return {} if self.class._ambient_subfield_tree.roots[PARENT].children.empty?

        provided = @__context.provided_data
        indifferent = provided.respond_to?(:with_indifferent_access) ? provided.with_indifferent_access : provided
        source = indifferent.key?(PARENT) ? (indifferent[PARENT] || {}) : _provider_source
        _filter_to_declared(source || {})
      end

      def _provider_source
        provider = Axn.config.ambient_context_provider
        provider ? provider.call : Axn::Core::AmbientContext.default_source
      end

      # Only the declared ambient LEAVES survive, each at its declared PATH — the hash never carries a
      # process-wide dump nor an undeclared sibling at any depth. Walks the ambient-scoped SubfieldTree
      # (see ClassMethods#_ambient_subfield_tree): a leaf's value is copied; a node with declared inner
      # structure is reconstructed from that structure only (never a whole sub-hash), so a deeply nested
      # `request[:ip]` resolves while `request[:token]` is dropped (PRO-2909).
      def _filter_to_declared(source)
        root = self.class._ambient_subfield_tree.roots[PARENT]
        return {} if root.nil?

        _filter_ambient_node(root, source)
      end

      # Rebuild the declared subtree rooted at `node`, reading from `source`. A node's declared immediate
      # keys come from BOTH its subfield-tree children AND its `shape:`-block members (PRO-2909); each is
      # preserved at its key and undeclared siblings are dropped. Recurses so nesting is filtered at every
      # depth (subfield-of-subfield and member-of-member alike).
      def _filter_ambient_node(node, source)
        indifferent = _ambient_indifferent(source)
        return {} unless indifferent.respond_to?(:key?)

        acc = {}
        node.children.each { |key, child| _reconstruct_ambient_child!(acc, key, child, indifferent) }
        # Shape members declared on this node's own configs are keys the subfield tree doesn't represent;
        # preserve each (a subfield child of the same key already covers it) so a shape-declared key isn't
        # dropped during reconstruction.
        _ambient_shape_members(node).each do |member|
          key = member.field.to_sym
          next if node.children.key?(key) || !indifferent.key?(key)

          acc[key] = _filter_ambient_shape_value(member, indifferent[key])
        end
        acc
      end

      # One subfield-tree child. A node with NO declared inner structure (no children and no shape
      # members) is a genuine leaf — copy its whole value (plus a `model:` node's `<field>_id`, whose
      # descendants read off the resolved RECORD, not a nested hash). Anything with declared inner
      # structure is reconstructed from a hash source; a non-hash source value is copied raw when the node
      # is DECLARED (so its own type validation can reject a malformed parent — PRO-2857 doctrine) and
      # omitted when the node is an IMPLICIT path segment (nothing validates it, and copying would only
      # leak undeclared ambient state).
      def _reconstruct_ambient_child!(acc, key, child, indifferent)
        if _ambient_model_node?(child) || (child.children.empty? && _ambient_shape_members(child).empty?)
          _copy_ambient_leaf!(acc, key, child, indifferent)
        elsif indifferent.key?(key)
          sub = indifferent[key]
          if sub.respond_to?(:to_hash)
            acc[key] = _filter_ambient_node(child, sub)
          elsif !child.implicit?
            acc[key] = sub
          end
        end
      end

      # A shape member's value: reconstruct from its OWN nested shape members when the member declares
      # them and the value is a hash (a member-of-a-member); otherwise copy it as-is (a scalar, array, or
      # object member has no declared string-keyed inner structure to filter).
      def _filter_ambient_shape_value(member, value)
        nested = member.validations.dig(:shape, :members)
        return value unless nested&.any? && value.respond_to?(:to_hash)

        indifferent = _ambient_indifferent(value)
        nested.each_with_object({}) do |m, acc|
          key = m.field.to_sym
          next unless indifferent.key?(key)

          acc[key] = _filter_ambient_shape_value(m, indifferent[key])
        end
      end

      # Copy a declared leaf's value. A `model:` subfield may be supplied either as a record (under the
      # leaf key) or as an id (under `<leaf>_id`, which the model subfield reader resolves from) —
      # preserve whichever key(s) the source actually supplies.
      def _copy_ambient_leaf!(acc, key, node, indifferent)
        acc[key] = indifferent[key] if indifferent.key?(key)
        return unless _ambient_model_node?(node)

        id_key = Internal::FieldConfig.model_id_key(key)
        acc[id_key] = indifferent[id_key] if indifferent.key?(id_key)
      end

      # A node with a `model:` route on any of its configs resolves to a RECORD — its value (record or
      # `<field>_id`) is copied whole, never reconstructed from children (they read off the record).
      def _ambient_model_node?(node)
        node.configs.any? { |c| c.validations[:model] }
      end

      # The `shape:`-block members declared across a node's configs (empty for an implicit node).
      def _ambient_shape_members(node)
        node.configs.flat_map { |c| Array(c.validations.dig(:shape, :members)) }
      end

      def _ambient_indifferent(source)
        source.respond_to?(:with_indifferent_access) ? source.with_indifferent_access : source
      end
    end
  end
end
