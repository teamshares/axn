# frozen_string_literal: true

require "axn/core/validation/fields"
require "axn/reflection/resolved_subfields"
require "axn/reflection/schema"
require "axn/reflection/subfield_contradictions"

module Axn
  module Core
    module ContractForSubfields
      # The per-class cache slot for the resolved-subfield artifact: the config arrays it was built
      # from plus the built value. Validity is decided by comparing the arrays' IDENTITY, never the
      # value — see ClassMethods#_resolved_subfields.
      ResolvedSubfieldsCacheEntry = Data.define(:fields, :subfields, :value)

      def self.included(base)
        base.class_eval do
          # Copy-on-write, frozen at every assignment (see Contract's stores).
          class_attribute :subfield_configs, default: [].freeze

          extend ClassMethods
        end
      end

      # Resolves the parent value a subfield config is read from — CANONICALLY: through the DEEPEST
      # reader-bearing ancestor on the chain up to the `on:` target (`public_send` of that reader —
      # memoized, model-resolving, alias-aware), then raw Extract digs for any remaining implicit
      # segments. Both spellings of the same wire path (`on: :b` and `on: "a.b"`) therefore resolve
      # identically: if `:b` is a declared subfield, its reader supplies the value either way (for a
      # `model:` subfield, the resolved record). Shared by the subfield readers and the inbound
      # validation runner so all consumers agree. An ambient config isn't indexed (its parent
      # resolves per-invocation), so it falls back to the reader-plus-digs recipe on its `on:` string.
      # Malformed hops read as absent via FieldResolvers.extract_or_nil (one doctrine: the bad
      # value's own validation classifies it, PRO-2857).
      def self.resolve_parent(action, config)
        path = action.class._resolved_subfields.index[config]
        return _resolve_parent_by_recipe(action, config.on, permit_method_call: config.method_call) if path.nil?

        reader_index = deepest_reader_index(path)
        return _resolve_parent_by_recipe(action, config.on, permit_method_call: config.method_call) if reader_index.nil?

        value = action.public_send(_deepest_reader_name(config, path, reader_index))
        (reader_index...path.parent_index).each do |i|
          # Every hop below the deepest reader is an IMPLICIT intermediate (a declared node bears a
          # reader, so it would be the reader public_sent above — never dig-crossed here). So the
          # resolving config's `method_call:` governs the whole dig uniformly: `method_call: true`
          # permits dispatch across every implicit hop on this expectation's path (PRO-2926).
          value = Axn::Core::FieldResolvers.extract_or_nil(field: path.ancestors[i].last.to_s, provided_data: value,
                                                           permit_method_call: config.method_call)
        end
        value
      end

      # The chain index of the deepest reader-bearing ancestor at-or-before the `on:` target — the
      # node resolve_parent public_sends; the hops AFTER it are the ones the runtime actually digs.
      # Shared with the unanswerable-segment declaration check (SubfieldContradictions) so the two
      # can't disagree about which segments are dig-read. Nil when no ancestor bears a reader (the
      # recipe fallback path).
      def self.deepest_reader_index(path)
        (0..path.parent_index).select { |i| _reader_config(path.ancestors[i].first) }.max
      end

      # The node's reader-bearing config, if any. Every declared config generates a reader, so this is
      # the node's first config; an implicit node has no configs and returns nil.
      def self._reader_config(node)
        node.configs.first
      end

      # The reader to public_send at the deepest reader-bearing ancestor. When that ancestor is the
      # config's `on:` ANCHOR (the on: root's node), the reader is the one config.on names — which
      # disambiguates a MERGED anchor node (two routes to one wire path, distinct readers via `as:`) so a
      # descendant resolves through the route it actually anchored on, not the node's first-declared
      # config. A deeper reused declared intermediate (e.g. a `model:` hop crossed by a dotted `on:`) is
      # single-config in practice, so its own node reader is used. `anchor_index` is the on: root node's
      # chain index (parent_index minus the dotted-`on:` segments below the anchor).
      def self._deepest_reader_name(config, path, reader_index)
        anchor_index = path.parent_index - (config.on.to_s.split(".").size - 1)
        return config.on.to_s.split(".").first.to_sym if reader_index == anchor_index

        _reader_config(path.ancestors[reader_index].first).reader_as
      end

      # Fallback for configs outside the tree (ambient): read the `on:` root via its reader, dig the
      # rest raw. The resolving config's `method_call:` applies to those raw dig segments (the untree'd
      # analog of the per-hop implicit-intermediate rule in resolve_parent, PRO-2926).
      def self._resolve_parent_by_recipe(source, on, permit_method_call: false)
        root, *rest = on.to_s.split(".")
        value = source.public_send(root)
        return value if rest.empty?

        Axn::Core::FieldResolvers.extract_or_nil(field: rest.join("."), provided_data: value, permit_method_call:)
      end

      # THE subfield value read — readers and validation share it: leaf-extract from the canonically
      # resolved parent, then value-level default fallback (PRO-2889). A declared default: guarantees
      # the RESOLVED value is never nil-by-omission even when the wire write-back couldn't apply it (a
      # refused chain under a model:/non-object parent, a parent record whose attribute is nil, a
      # malformed parent). No wire data is written here and the parent's own value stays untouched, so
      # a nil-tolerant parent remains genuinely nil.
      def self.resolve_value(action, config)
        # Memoize on the action INSTANCE, keyed by config identity — mirrors the reader memoization
        # that already covers configs WITH a generated reader, extending it to the reader-less callers
        # this seam serves (validation's no-reader branch and resolve_model_via_sibling_id's
        # dotted-sibling path). Without it a reader-less config re-resolves once per ActiveModel
        # validator, re-running a Proc default each time — a Proc default must resolve at most once per
        # call. A config with a reader already memoizes, so this second layer is harmless there.
        # `key?` presence (not truthiness) so a nil/false resolved value memoizes too.
        cache = if action.instance_variable_defined?(:@__resolve_value_cache)
                  action.instance_variable_get(:@__resolve_value_cache)
                else
                  action.instance_variable_set(:@__resolve_value_cache, {}.compare_by_identity)
                end
        return cache[config] if cache.key?(config)

        parent = resolve_parent(action, config)
        value = Axn::Core::FieldResolvers.extract_or_nil(field: config.field, provided_data: parent,
                                                         permit_method_call: config.method_call)
        # coerce:/preprocess:/default: all resolve here, on the read path (non-materializing, value-level
        # — the model PRO-2889 established for subfield defaults). No wire write-back and the parent's own
        # value stays untouched, so axn never mutates a caller-supplied object during resolution.
        value = _apply_read_path_transforms(action, config, value, parent)
        value = Axn::Internal::FieldConfig.resolve_default(action, config) if value.nil? && config.applied_default?
        cache[config] = value
      end

      # coerce → preprocess, applied to a resolved subfield value on the read path (the top-level pass
      # order, minus default: which the caller applies after). Preprocess is skipped when the parent is
      # absent (nil): an absent subfield has no value to transform, matching the write-back's
      # drop-on-nil-parent. coerce_value no-ops on a nil/non-String value, so coercion needs no guard.
      def self._apply_read_path_transforms(action, config, value, parent)
        coerce_input_types = Axn::Configuration.resolve_override_for(action.class, :coerce_input_types)
        value = Axn::Reflection::Coercion.coerce_config_value(value, config, coerce_input_types:)
        value = Axn::Internal::FieldConfig.resolve_preprocess(action, config, value) if config.preprocess && !parent.nil?
        value
      end

      # When a model subfield resolves nil AND the raw wire data carried no id token, a sibling
      # `<field>_id` subfield's VALUE-LEVEL resolution (its own reader — which applies its default:)
      # supplies the lookup token, and the model resolves from it. This is the model-flavored half of
      # value-level defaults: the id the resolver consults is the id user code reads. Only fires when
      # the raw id is absent (a present id that failed its lookup must not be silently overridden — a
      # failed lookup stays nil). The sibling `<field>_id` lives beside the model leaf under the leaf's
      # own WIRE parent — the `on:` target (`parent_node`), since a field name is a single wire key.
      def self.resolve_model_via_sibling_id(action, config, options, parent_value)
        raw_id = Axn::Core::FieldResolvers.extract_or_nil(
          field: Axn::Internal::FieldConfig.model_id_key(config.field), provided_data: parent_value,
          permit_method_call: config.method_call
        )
        return nil unless raw_id.nil?

        path = action.class._resolved_subfields.index[config]
        return nil if path.nil?

        id_key = Axn::Internal::FieldConfig.model_id_key(config.field)
        sibling = path.parent_node.children[id_key.to_sym]
        # Select the sibling config with the SAME predicate the declaration credits
        # (Schema.sibling_id_rescued? → usable_id_token_default?), so a merged id node — several routes
        # on one `<field>_id` wire key — resolves the route the credit relied on. A blank default IS
        # applied at runtime but is blank-guarded by the model resolver, so it is not a usable token:
        # picking it by applied_default? alone (blank route declared first) would supply no id and
        # silently defeat the rescue the declaration accepted.
        sibling_config = sibling&.configs&.find { |c| Axn::Reflection::Schema.usable_id_token_default?(c) }
        return nil if sibling_config.nil?

        # The sibling reads through its own reader (the canonical, memoized path).
        sibling_value = action.public_send(sibling_config.reader_as)
        return nil if sibling_value.nil?

        # Synthetic resolve: the Model resolver reads `<field>_id` from a hash keyed by that same id key.
        Axn::Core::FieldResolvers.resolve(type: :model, field: config.field, options:, provided_data: { id_key => sibling_value })
      end

      module ClassMethods
        # The class's canonical resolved-subfield structure (PRO-2883), built lazily and cached on
        # the class. Cache validity is decided by IDENTITY of the two config arrays: both are
        # copy-on-write class_attributes mutated exclusively via `+=`, so any declaration — on this
        # class or a subclass — mints new arrays and the stale entry misses on `equal?`. That gives
        # invalidation with no explicit hooks (a future mutation site is auto-covered), no
        # nil-memoization footgun (validity never consults the value), and free copy-on-write
        # subclass inheritance (an undeclaring subclass reads the superclass's arrays and builds an
        # identical artifact once). The artifact is deep-frozen and published in a single ivar
        # write, so a first-call race between threads is benign.
        def _resolved_subfields
          fields = internal_field_configs
          subfields = subfield_configs
          cached = @_axn_resolved_subfields
          return cached.value if cached && cached.fields.equal?(fields) && cached.subfields.equal?(subfields)

          value = Axn::Reflection::ResolvedSubfields.build(fields, subfields)
          @_axn_resolved_subfields = ResolvedSubfieldsCacheEntry.new(fields:, subfields:, value:)
          value
        end

        def _expects_subfields( # rubocop:disable Metrics/ParameterLists
          *fields,
          on:,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          default: nil,
          preprocess: nil,
          sensitive: false,
          metadata: {},
          reader_names: {},
          user_facing: false,
          method_call: false,
          **validations
        )
          # `on:` may be a dotted path (e.g. "address.billing"); the *root* segment must be declared.
          # It's resolved by calling the parent's reader (`resolve_parent` → public_send), so it must
          # name a reader — i.e. the alias when the parent was declared with `as:`/`prefix:`, not the
          # underlying wire key (which has no reader of its own once renamed).
          root = on.to_s.split(".").first.to_sym
          unless root == Axn::Core::AmbientContext::PARENT || (internal_field_configs + subfield_configs).map(&:reader_as).include?(root)
            raise ArgumentError,
                  "expects called with `on: #{on}`, but no such reader exists " \
                  "(are you sure you've declared a field — or alias — named :#{root}?)"
          end

          # An ambient subfield's value is framework-supplied (the ambient provider /
          # CurrentAttributes), not caller input — there is no user to face, so reclassifying its
          # violation as user-facing is a category error.
          if user_facing && _on_roots_at_ambient?(on)
            raise ArgumentError,
                  "`user_facing:` is not supported for an ambient_context subfield " \
                  "(ambient values are framework-supplied, not caller input)"
          end

          # Deep ambient nesting — a dotted `on:` rooted at ambient (`on: "ambient_context.request"`),
          # a dotted subfield NAME on an ambient parent (`expects "request.ip", on: :ambient_context`),
          # and a subfield nested UNDER an ambient subfield (`expects :ip, on: :request`) — is fully
          # supported (PRO-2909): runtime resolution walks these, and `_filter_to_declared` rebuilds the
          # filtered ambient hash along each declared PATH, so a nested leaf resolves while undeclared
          # siblings are dropped. `default:`/`preprocess:`/`coerce:` resolve on the same non-mutating read
          # path (`resolve_value`) as every other subfield, so they apply here too — no write-back to
          # `provided_data` is involved. `user_facing:` stays rejected (above): an ambient value is
          # framework-supplied, so there is no caller to face regardless of resolution mechanism.

          _parse_subfield_configs(*fields, on:, allow_blank:, allow_nil:, optional:, preprocess:, sensitive:, default:,
                                           metadata:, reader_names:, user_facing:, method_call:, **validations).tap do |configs|
            duplicated = _duplicate_fields(subfield_configs, configs)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(', ')}" if duplicated.any?

            # Validate reader-name uniqueness up front (no side effects), so this error — like the checks
            # above (the dotted-name model: and model-batch-id rejections in _parse_subfield_configs) —
            # leaves the class untouched.
            _validate_subfield_reader_names!(configs)

            # Contradiction-only contracts raise BEFORE any class mutation (PRO-2889): the candidate
            # tree includes the prospective configs, so a new required descendant that kills an
            # already-declared tolerance is caught at the declaration that completes it. The shared tree
            # drops ambient configs, so the ambient subtree is checked separately on its own scoped tree
            # (PRO-2909) — same candidate set, same checks.
            Axn::Reflection::SubfieldContradictions.check!(internal_field_configs, subfield_configs + configs)
            _check_ambient_subfield_contradictions!(subfield_configs + configs)
            _check_ambient_shape_placement!(subfield_configs + configs)

            # Every declaration check has passed; NOW mutate the class. Deferring both the config commit
            # AND reader generation to here (after all checks) means a rescued declaration error — a Rails
            # reload path, metaprogrammed construction, a test — never leaves the class carrying an orphaned
            # config or generated reader, so a corrected retry starts clean.
            # Copy-on-write + freeze: `<<` would mutate the superclass's contract, and
            # identity-keyed caching relies on replacement.
            self.subfield_configs = (subfield_configs + configs).freeze
            _define_subfield_readers!(configs)
          end
        end

        private

        # True when on:'s chain ultimately roots at :ambient_context — directly (`on: :ambient_context`),
        # via a dotted path, or by pointing at another subfield that itself roots at ambient.
        def _on_roots_at_ambient?(on)
          seen = []
          segment = on.to_s.split(".").first.to_sym
          loop do
            return true if segment == Axn::Core::AmbientContext::PARENT
            return false if seen.include?(segment)

            seen << segment
            parent = subfield_configs.find { |c| c.reader_as == segment }
            return false unless parent

            segment = parent.on.to_s.split(".").first.to_sym
          end
        end

        def _parse_subfield_configs( # rubocop:disable Metrics/ParameterLists
          *fields,
          on:,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          preprocess: nil,
          sensitive: false,
          default: nil,
          metadata: {},
          reader_names: {},
          user_facing: false,
          method_call: false,
          **validations
        )
          # A subfield is the on:-carrying case of the shared top-level config builder; with the ambient
          # coerce/shape guards and the dotted-name model guard gone, no per-config post-check remains.
          _parse_field_configs(*fields, on:, allow_blank:, allow_nil:, optional:, preprocess:, sensitive:, default:,
                                        metadata:, reader_names:, user_facing:, method_call:, **validations)
        end

        # Reader-name uniqueness across the prospective batch and everything already defined — a pure
        # pre-check (no methods defined) run before any reader is generated, so a duplicate raises before
        # the class is mutated. Every declared subfield gets a reader (canonical `on:` resolution
        # public_sends the deepest reader-bearing ancestor, so a silently-skipped reader would resolve the
        # wrong value), so a collision is always a declaration error — resolved by renaming, never by
        # suppression.
        def _validate_subfield_reader_names!(configs)
          seen = []
          configs.each do |config|
            reader = config.reader_as
            if method_defined?(reader) || seen.include?(reader)
              raise ArgumentError,
                    "expects does not support duplicate sub-keys (i.e. `#{reader}` is already defined) — " \
                    "rename this subfield's reader, e.g. `expects :#{config.field}, on: #{config.on.inspect}, " \
                    "as: :#{config.on.to_s.tr('.', '_')}_#{config.field}` (or use prefix: for several at once)"
            end

            seen << reader
          end
        end

        # Generate the readers for an already-validated, already-committed batch of subfield configs.
        # Called only after every declaration check has passed, so it performs side effects without raising.
        #
        # Two passes: all EXPLICIT primary readers first, then all auto-generated COMPANIONS (boolean `?`
        # predicates, model `<field>_id` readers). A companion defers — with a debug breadcrumb, via
        # `_reader_name_available?` — to any explicit reader of the same name; deferring the whole companion
        # pass until every primary exists makes that yielding order-independent, matching top-level `expects`.
        # Interleaving the two (a companion generated before a later same-named primary) would let the
        # primary silently clobber the companion.
        def _define_subfield_readers!(configs)
          # The two passes must NOT be combined: every primary reader has to exist before any companion is
          # generated, so a companion defers to an explicit same-named reader regardless of order (see above).
          # rubocop:disable Style/CombinableLoops
          configs.each { |c| _define_subfield_reader(c) }
          configs.each { |c| _define_subfield_companion_readers(c) }
          # rubocop:enable Style/CombinableLoops
        end

        # `reader` is the accessor's name (may be aliased via as:/prefix:); the wire key it extracts
        # from the `on:` parent is the config's own field (resolve_value reads it).
        def _define_subfield_reader(config)
          reader = config.reader_as

          # Reader-name uniqueness is validated up front by _validate_subfield_reader_names! before any
          # reader is generated, so there is no duplicate to guard against here.

          if config.validations.key?(:model)
            _define_subfield_model_reader(config)
          else
            Axn::Internal::Memoization.define_memoized_reader_method(self, reader) do
              Axn::Core::ContractForSubfields.resolve_value(self, config)
            end
          end
        end

        # Auto-generated companion readers for a config: the boolean `?` predicate and the model
        # `<field>_id` reader. Defined in a second pass (see _define_subfield_readers!) so each yields to
        # any explicit same-named reader regardless of declaration order.
        def _define_subfield_companion_readers(config)
          _define_boolean_predicate_reader(config.reader_as) if config.boolean?
          return unless config.validations.key?(:model)

          _define_subfield_model_id_reader(config, _subfield_model_options(config))
        end

        # Syntactic-sugar processing for a subfield `model:`, keyed on the field name so a defaulted
        # `klass` derives from it (`widget` → `Widget`).
        def _subfield_model_options(config)
          Axn::Validators::ModelValidator.apply_syntactic_sugar(config.validations[:model], [config.field])
        end

        def _define_subfield_model_reader(config)
          reader = config.reader_as
          source_field = config.field
          processed_options = _subfield_model_options(config)

          Axn::Internal::Memoization.define_memoized_reader_method(self, reader) do
            # Create a data source that contains the subfield data for the resolver
            subfield_data = Axn::Core::ContractForSubfields.resolve_parent(self, config)

            record = Axn::Core::FieldResolvers.resolve(
              type: :model,
              field: source_field,
              options: processed_options,
              provided_data: subfield_data,
              permit_method_call: config.method_call,
            )
            # When the raw wire data carried no id, a sibling `<field>_id` subfield's value-level
            # default supplies the lookup token so the record still resolves (PRO-2889).
            record ||= Axn::Core::ContractForSubfields.resolve_model_via_sibling_id(self, config, processed_options, subfield_data)
            # A nil-resolving model subfield falls back to a record-supplying default (validated by
            # ModelValidator like any record) — the same value-level rule as plain subfields.
            record.nil? && config.applied_default? ? Axn::Internal::FieldConfig.resolve_default(self, config) : record
          end
        end

        # The subfield analog of `_define_model_id_reader`: reads the raw `<field>_id` from the `on:`
        # parent and otherwise shares the top-level reader's semantics via `_define_model_id_reader_from`.
        def _define_subfield_model_id_reader(config, processed_options)
          by_primary_key = processed_options[:finder] == :find
          _define_model_id_reader_from(reader: config.reader_as, source_field: config.field, by_primary_key:) do |id_key|
            parent = Axn::Core::ContractForSubfields.resolve_parent(self, config)
            Axn::Core::FieldResolvers.extract_or_nil(field: id_key, provided_data: parent, permit_method_call: config.method_call)
          end
        end
      end
    end
  end
end
