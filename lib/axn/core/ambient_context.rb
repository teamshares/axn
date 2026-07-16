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

        # A `shape:` on an ambient subfield validates the COPIED ambient value: a shape-carrying node
        # with no subfield children is a leaf in `_filter_ambient_node`, so its whole value is copied
        # and shape validates against it — no filter-merge. A `model:` node is ALSO a leaf there even
        # WITH subfield children: its value (record or `<field>_id`) is copied whole and its children
        # read off the RESOLVED RECORD, not a nested ambient hash, so a shape on a model node validates
        # fine against that copy too. A plain (non-model) shape node WITH subfield children is not a
        # leaf: the filter rebuilds it from those children alone, dropping every shape-only member, so
        # the shape can't be validated there. Reject that at declaration (candidate tree, nothing
        # committed — same pattern as `_check_ambient_subfield_contradictions!`), pointing at declaring
        # the nested structure ONE way. Order-independent: a child's `on:` requires its parent already
        # declared, so a shape-carrying parent is always seen with its children by the time this runs.
        def _check_ambient_shape_placement!(candidate_subfields)
          ambient = candidate_subfields.select { |c| _on_roots_at_ambient?(c.on) }
          return if ambient.empty?

          tree = Axn::Reflection::SubfieldTree.build([_synthetic_ambient_root], ambient)
          # `roots[PARENT]` is guaranteed present: `ambient` is non-empty (checked above), and every
          # config in it roots at `PARENT`, so `SubfieldTree.build` always creates that root node.
          _each_ambient_node(tree.roots[PARENT]) do |node|
            shape_config = node.configs.find { |c| c.validations.is_a?(Hash) && c.validations.key?(:shape) }
            next unless shape_config

            # An ambient value is framework-supplied, not caller input — so a violation can never be
            # user-facing, at any depth. The subfield's own `user_facing:` is already rejected upstream;
            # extend the same rule to shape members (which carry their own `user_facing:` since PRO-2925),
            # so an ambient shape can't smuggle a user-facing member classification.
            _reject_ambient_shape_user_facing_members!(shape_config)

            # Only a filter-leaf shape validates against the copied value; a non-`model:` node WITH subfield
            # children is rebuilt from those children alone, dropping shape-only members.
            next if node.children.empty? || _ambient_model_node?(node)

            raise ArgumentError,
                  "a `shape:` block on the ambient subfield `#{shape_config.field}` is only supported when it " \
                  "has no nested subfields — this node also has subfield children, so the ambient filter " \
                  "rebuilds it from those children alone and the shape's members can't be validated. Declare " \
                  "the nested structure ONE way: keep the `shape:` (validation only), or use subfields " \
                  "(`expects :<member>, on: :#{shape_config.field}`), which also give readers and `sensitive:`."
          end
        end

        # Reject `user_facing:` on any member of an ambient subfield's shape, recursing into nested shapes.
        # A duck-typed member without `#user_facing` (a raw `shape: { members: [...] }`) defaults to none.
        def _reject_ambient_shape_user_facing_members!(shape_config)
          _each_shape_member(shape_config.validations[:shape]) do |member|
            next unless member.respond_to?(:user_facing) && member.user_facing

            raise ArgumentError,
                  "`user_facing:` is not supported on a shape member of an `on: :ambient_context` subfield " \
                  "(ambient values are framework-supplied, not caller input — there is no caller to face)"
          end
        end

        # Yield every member of `shape`, recursing into each member's own nested shape.
        def _each_shape_member(shape, &block)
          return unless shape.is_a?(Hash)

          (shape[:members] || []).each do |member|
            yield member
            nested = member.validations[:shape] if member.respond_to?(:validations) && member.validations.is_a?(Hash)
            _each_shape_member(nested, &block) if nested
          end
        end

        # Depth-first walk of `node` and all its declared descendants, yielding each node.
        def _each_ambient_node(node, &block)
          yield node
          node.children.each_value { |child| _each_ambient_node(child, &block) }
        end

        # A node with a `model:` route on any of its configs resolves to a RECORD — its value (record or
        # `<field>_id`) is copied whole, never reconstructed from children (they read off the record).
        # Single-sourced here so the class-level placement check and the instance-level filter share
        # IDENTICAL leaf semantics (the instance method below delegates to this).
        def _ambient_model_node?(node)
          node.configs.any? { |c| c.validations[:model] }
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
      # (see ClassMethods#_ambient_subfield_tree): a leaf's value is copied whole (so a leaf's `shape:`,
      # if any, validates against the untouched copy); a node with declared children is reconstructed
      # from those children only (never a whole sub-hash), so a deeply nested `request[:ip]` resolves
      # while `request[:token]` is dropped (PRO-2909). A `shape:` on a node that ALSO has subfield
      # children is rejected at declaration (`_check_ambient_shape_placement!`), since that node isn't a
      # leaf here — its declared structure comes from the children alone and the shape can't be honored.
      def _filter_to_declared(source)
        root = self.class._ambient_subfield_tree.roots[PARENT]
        return {} if root.nil?

        _filter_ambient_node(root, source)
      end

      # Rebuild the declared subtree rooted at `node`, reading from `source`. A leaf node — no declared
      # children, OR a `model:` node (whose descendants read off the RESOLVED RECORD, not a nested ambient
      # hash, so the source only ever carries its record/`<field>_id`) — copies its value; any other node
      # WITH children is an intermediate, reconstructed from its source sub-hash keeping only declared
      # descendants. A non-hash value under a DECLARED intermediate is copied raw so the node's own type
      # validation can reject a malformed parent (PRO-2857 doctrine); under an IMPLICIT path segment it is
      # omitted (nothing validates it, and copying would only leak undeclared ambient state).
      def _filter_ambient_node(node, source)
        indifferent = source.respond_to?(:with_indifferent_access) ? source.with_indifferent_access : source
        return {} unless indifferent.respond_to?(:key?)

        node.children.each_with_object({}) do |(key, child), acc|
          if child.children.empty? || _ambient_model_node?(child)
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

      # Delegates to the class-level predicate (see `ClassMethods#_ambient_model_node?`) so the filter
      # and the declaration-time placement check share exactly one implementation.
      def _ambient_model_node?(node)
        self.class._ambient_model_node?(node)
      end
    end
  end
end
