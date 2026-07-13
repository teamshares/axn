# frozen_string_literal: true

require "axn/core/validation/subfields"
require "axn/reflection/resolved_subfields"

module Axn
  module Core
    module ContractForSubfields
      # The per-class cache slot for the resolved-subfield artifact: the config arrays it was built
      # from plus the built value. Validity is decided by comparing the arrays' IDENTITY, never the
      # value — see ClassMethods#_resolved_subfields.
      ResolvedSubfieldsCacheEntry = Data.define(:fields, :subfields, :value)

      def self.included(base)
        base.class_eval do
          class_attribute :subfield_configs, default: []

          extend ClassMethods
        end
      end

      # Resolves the parent value an `on:` points at. `on:` may be a single field/subfield
      # (e.g. :address) or a dotted path (e.g. "address.billing") — the root segment is read via
      # its reader and any remaining segments are dug out via the Extract resolver. Shared by the
      # subfield reader and the inbound validation runner so both treat paths identically.
      def self.resolve_parent(source, on)
        root, *rest = on.to_s.split(".")
        value = source.public_send(root)
        return value if rest.empty?

        Axn::Core::FieldResolvers.resolve(type: :extract, field: rest.join("."), provided_data: value)
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

          # Deep/dotted ambient nesting (`on: "ambient_context.request"`) passes the root check above
          # and `resolve_parent` can walk it at runtime, but `AmbientContext#_filter_to_declared` only
          # keeps configs whose `on.to_sym == :ambient_context` exactly — a dotted ambient parent's
          # data is silently stripped, so the subfield would always read from `{}`. Deep ambient nesting
          # is deferred (PRO-2844/PRO-2845), so reject this at declaration rather than fail silently.
          # Checked unconditionally (regardless of
          # preprocess:/default:) since the underlying gap is in ambient resolution, not those options.
          if root == Axn::Core::AmbientContext::PARENT && on.to_s.include?(".")
            raise ArgumentError,
                  "a dotted `on:` path rooted at :ambient_context (got #{on.inspect}) is not supported — " \
                  "declare a single-level `on: :ambient_context` subfield (deep ambient nesting is deferred; see PRO-2844/PRO-2845)"
          end

          # A dotted subfield NAME on an ambient parent (`expects "request.ip", on: :ambient_context`)
          # denotes deep extraction (FieldResolvers::Extract reads ambient_context[:request][:ip]), but
          # `_filter_to_declared` only preserves the exact declared key, so the nested source is stripped
          # and the subfield always reads nil. Deep ambient nesting is deferred (PRO-2844/PRO-2845), so
          # reject at declaration rather than fail silently. (Dotted names on a NON-ambient parent are a
          # supported runtime extraction path and are left alone here.)
          if root == Axn::Core::AmbientContext::PARENT && fields.any? { |f| f.to_s.include?(".") }
            dotted = fields.select { |f| f.to_s.include?(".") }
            raise ArgumentError,
                  "a dotted subfield name (got #{dotted.map(&:to_s).inspect}) on an `on: :ambient_context` subfield " \
                  "denotes deep ambient nesting, which is not supported — declare a single-level ambient subfield " \
                  "(deep ambient nesting is deferred; see PRO-2844/PRO-2845)"
          end

          # A subfield nested UNDER an ambient subfield (`expects :ip, on: :request` where `:request` is an
          # `on: :ambient_context` subfield) would make _filter_to_declared copy the whole parent hash into
          # ambient_context, leaking undeclared nested keys (e.g. request[:token]) into exception context —
          # and the nested child can't be marked sensitive:. Deep ambient nesting is deferred (PRO-2844/2845),
          # so reject anything that roots at :ambient_context other than a direct single-level subfield.
          if on.to_sym != Axn::Core::AmbientContext::PARENT && _on_roots_at_ambient?(on)
            raise ArgumentError,
                  "a subfield nested under :ambient_context (on: #{on.inspect}) is not supported — declare a " \
                  "single-level `on: :ambient_context` subfield (deep ambient nesting is deferred; see PRO-2844/PRO-2845)"
          end

          # An `on: :ambient_context` subfield's value comes from the ambient provider / CurrentAttributes
          # per-invocation, not from `@context.provided_data[parent]` — but `default:`/`preprocess:` are
          # applied by mutating `provided_data[parent]` (see Executor#apply_defaults_for_subfields! /
          # #apply_inbound_preprocessing_for_subfields!), which the per-invocation resolution never reads,
          # so both would silently fail to affect the resolved value. `sensitive:` is filter-only and
          # unaffected — it's relied on for ambient_context observability, so it must stay allowed.
          if root == Axn::Core::AmbientContext::PARENT && (!default.nil? || !preprocess.nil?)
            raise ArgumentError,
                  "`default:`/`preprocess:` are not supported for an `on: :ambient_context` subfield " \
                  "(the ambient parent is resolved per-invocation, not read from provided_data) — " \
                  "compute defaults/preprocessing in your ambient_context_provider or a before hook. `sensitive:` is supported."
          end

          _parse_subfield_configs(*fields, on:, allow_blank:, allow_nil:, optional:, preprocess:, sensitive:, default:,
                                           metadata:, reader_names:, user_facing:, **validations).tap do |configs|
            duplicated = _duplicate_fields(subfield_configs, configs)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(', ')}" if duplicated.any?

            # Validate reader-name uniqueness up front (no side effects), so this error — like the checks
            # above (the dotted-name model: and model-batch-id rejections in _parse_subfield_configs) —
            # leaves the class untouched.
            _validate_subfield_reader_names!(configs)

            # Every declaration check has passed; NOW mutate the class. Deferring both the config commit
            # AND reader generation to here (after all checks) means a rescued declaration error — a Rails
            # reload path, metaprogrammed construction, a test — never leaves the class carrying an orphaned
            # config or generated reader, so a corrected retry starts clean.
            # NOTE: avoid <<, which would update value for parents and children.
            self.subfield_configs += configs
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
          **validations
        )
          # A model: batch that also names a model field's own `<field>_id` companion (e.g.
          # `expects :company, :company_id, on:, model:`) can never work: model: applies to EVERY field in
          # the batch, so the `<field>_id` is itself a model: subfield (it would require `<field>_id_id` and
          # reject a raw id), and it collides with the raw-id reader the model: field already generates. A
          # model: subfield exposes its own `<field>_id` reader for the raw id, so the explicit one is both
          # redundant and broken. (Declaring the id in a separate expects doesn't help either — the generated
          # `<field>_id` reader already exists, so it trips the duplicate-reader guard.)
          if validations.key?(:model)
            batch = fields.map(&:to_sym)
            if (model_field = batch.find { |f| batch.include?(Axn::Internal::FieldConfig.model_id_key(f)) })
              id_key = Axn::Internal::FieldConfig.model_id_key(model_field)
              raise ArgumentError,
                    "a model: subfield batch (#{fields.map(&:to_s).inspect} with on: #{on}) names both " \
                    ":#{model_field} and its own id companion :#{id_key} — but model: applies to every field " \
                    "in the batch, so :#{id_key} becomes a second model: subfield (requiring :#{id_key}_id) " \
                    "rather than the raw id. The model: subfield :#{model_field} already generates a " \
                    ":#{id_key} reader for the raw id; drop the explicit :#{id_key}."
            end
          end

          # The config-building itself is the shared top-level path (a subfield is the on:-carrying
          # case); the checks below are pure reads of the built configs, raised before anything commits.
          _parse_field_configs(*fields, on:, allow_blank:, allow_nil:, optional:, preprocess:, sensitive:, default:,
                                        metadata:, reader_names:, user_facing:, **validations).each do |config|
            _reject_ambient_coerce!(config)
            _reject_dotted_model_name!(config, fields:)
          end
        end

        # An ambient subfield's value is resolved per-invocation, never read from provided_data —
        # which is the only place coercion writes — so a `coerce:` there would silently never
        # apply. Reject it like ambient default:/preprocess:.
        def _reject_ambient_coerce!(config)
          return unless config.validations.dig(:type, :coerce)
          return unless config.on.to_s.split(".").first.to_sym == Axn::Core::AmbientContext::PARENT

          raise ArgumentError,
                "`coerce:` is not supported for an `on: :ambient_context` subfield " \
                "(the ambient parent is resolved per-invocation, not read from provided_data)"
        end

        # A dotted field NAME (e.g. "org.company") generates no reader (see
        # `_define_subfield_reader`'s early return), so `model:`'s id→record lookup —
        # which is wired onto the generated reader — never runs, and the advertised
        # `<leaf>_id` is unconsumable. The working spelling swaps which half is dotted:
        # a dotted `on:` with a single-level name (`expects :company, on: "payload.org"`)
        # still gets a reader. Point the error at that spelling.
        def _reject_dotted_model_name!(config, fields:)
          return unless config.validations.key?(:model) && config.field.to_s.include?(".")

          *parents, leaf = config.field.to_s.split(".")
          working_on = ([config.on] + parents).join(".")
          raise ArgumentError,
                "a dotted-name model: subfield (#{fields.map(&:to_s).inspect} with on: #{config.on}) has no consumable id — " \
                "a dotted subfield name generates no reader, so the id-to-record lookup never runs. " \
                "Use the reader spelling instead: expects :#{leaf}, on: \"#{working_on}\", model: ..."
        end

        # Reader-name uniqueness across the prospective batch and everything already defined — a pure
        # pre-check (no methods defined) run before any reader is generated, so a duplicate raises before
        # the class is mutated. A dotted field name generates no reader, so it can't collide.
        def _validate_subfield_reader_names!(configs)
          seen = []
          configs.each do |config|
            next if config.field.to_s.include?(".")

            reader = config.reader_as
            if method_defined?(reader) || seen.include?(reader)
              raise ArgumentError, "expects does not support duplicate sub-keys (i.e. `#{reader}` is already defined)"
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
          configs.each { |c| _define_subfield_reader(c.reader_as, c.field, on: c.on, validations: c.validations) }
          configs.each { |c| _define_subfield_companion_readers(c) }
          # rubocop:enable Style/CombinableLoops
        end

        # `reader` is the accessor's name (may be aliased via as:/prefix:); `source_field` is the
        # wire key extracted from the `on:` parent.
        def _define_subfield_reader(reader, source_field, on:, validations:)
          # Don't create top-level readers for nested fields
          return if source_field.to_s.include?(".")

          # Reader-name uniqueness is validated up front by _validate_subfield_reader_names! before any
          # reader is generated, so there is no duplicate to guard against here.

          if validations.key?(:model)
            _define_subfield_model_reader(reader, source_field, validations[:model], on:)
          else
            Axn::Internal::Memoization.define_memoized_reader_method(self, reader) do
              Axn::Core::FieldResolvers.resolve(type: :extract, field: source_field,
                                                provided_data: Axn::Core::ContractForSubfields.resolve_parent(self, on))
            end
          end
        end

        # Auto-generated companion readers for a config: the boolean `?` predicate and the model
        # `<field>_id` reader. Defined in a second pass (see _define_subfield_readers!) so each yields to
        # any explicit same-named reader regardless of declaration order.
        def _define_subfield_companion_readers(config)
          return if config.field.to_s.include?(".")

          _define_boolean_predicate_reader(config.reader_as) if config.boolean?
          return unless config.validations.key?(:model)

          processed_options = Axn::Validators::ModelValidator.apply_syntactic_sugar(config.validations[:model], [config.field])
          _define_subfield_model_id_reader(config.reader_as, config.field, processed_options, on: config.on)
        end

        def _define_subfield_model_reader(reader, source_field, options, on:)
          # Apply the same syntactic sugar processing as the main contract system
          processed_options = Axn::Validators::ModelValidator.apply_syntactic_sugar(options, [source_field])

          Axn::Internal::Memoization.define_memoized_reader_method(self, reader) do
            # Create a data source that contains the subfield data for the resolver
            subfield_data = Axn::Core::ContractForSubfields.resolve_parent(self, on)

            Axn::Core::FieldResolvers.resolve(
              type: :model,
              field: source_field,
              options: processed_options,
              provided_data: subfield_data,
            )
          end
        end

        # The subfield analog of `_define_model_id_reader`: reads the raw `<field>_id` from the `on:`
        # parent and otherwise shares the top-level reader's semantics via `_define_model_id_reader_from`.
        def _define_subfield_model_id_reader(reader, source_field, processed_options, on:)
          by_primary_key = processed_options[:finder] == :find
          _define_model_id_reader_from(reader:, source_field:, by_primary_key:) do |id_key|
            parent = Axn::Core::ContractForSubfields.resolve_parent(self, on)
            Axn::Core::FieldResolvers.resolve(type: :extract, field: id_key, provided_data: parent)
          end
        end
      end
    end
  end
end
