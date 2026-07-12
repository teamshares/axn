# frozen_string_literal: true

require "axn/core/validation/subfields"
require "axn/reflection/subfield_contradictions"

module Axn
  module Core
    module ContractForSubfields
      # `reader_as` is the generated accessor's name; it defaults to `field` (the subfield key) but
      # `as:`/`prefix:` decouple them — the reader is renamed while the value is still extracted by
      # the wire-key `field` from the `on:` parent.
      SubfieldConfig = Data.define(:field, :validations, :on, :sensitive, :preprocess, :default, :metadata, :reader_as) do
        def description = metadata[:description]
      end

      def self.included(base)
        base.class_eval do
          class_attribute :subfield_configs, default: []
          # Reader names axn actually generated for subfields (via `_define_subfield_reader`). Consulted
          # by the readerless-parent guard, which must distinguish an axn-generated reader from any
          # inherited public method of the same name (e.g. :class, :hash). Copy-on-write like
          # `subfield_configs` so subclasses inherit the superclass's generated names.
          class_attribute :_generated_subfield_reader_names, default: []

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
        def _expects_subfields( # rubocop:disable Metrics/ParameterLists, Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity, Metrics/AbcSize
          *fields,
          on:,
          readers: true,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          default: nil,
          preprocess: nil,
          sensitive: false,
          metadata: {},
          reader_names: {},
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

          # `resolve_parent` reads the root via `public_send(root)`, so the root must have a reader that
          # axn actually generated. A top-level field always has one (contract.rb forbids readerless
          # top-level `expects`); a subfield parent has one only when declared with the default
          # `readers: true`. A `readers: false` subfield matches the `reader_as` list above (its config
          # exists) but defined no method, so `public_send` either raises NoMethodError or — when the
          # name shadows an inherited method like :class/:hash — silently invokes that method and reads
          # the wrong object, all while reflection still advertises the nested path. Consult the record
          # of readers axn generated rather than `method_defined?`, which can't tell an axn reader from
          # an inherited public method. (A dotted parent name also defines no reader, but its `reader_as`
          # never matches a root segment, so it's already caught by the no-such-reader check above and
          # never reaches here. Ambient roots resolve per-invocation, not via a generated reader, so
          # they're exempt.) The parent is always declared before the subfield, so its reader — when
          # requested — is already recorded by now.
          root_has_reader = internal_field_configs.map(&:reader_as).include?(root) ||
                            _generated_subfield_reader_names.include?(root)
          if root != Axn::Core::AmbientContext::PARENT && !root_has_reader
            raise ArgumentError,
                  "expects called with `on: #{on}`, but :#{root} was declared with `readers: false` — " \
                  "a subfield parent must have a reader for the runtime to resolve " \
                  "(drop `readers: false` on :#{root}, or name a readable parent)"
          end

          # `user_facing:` is a top-level-only contract: it reclassifies a violation of *that field*
          # into a user-facing failure, but subfields are always dev-facing. Declaring a subfield on a
          # user-facing parent mixes the two — a violation of the parent and an independent subfield
          # violation can't both settle as one outcome cleanly — so reject it. (A subfield must be
          # declared after its parent, so checking here catches the combination in either order.)
          if _on_roots_at_user_facing_field?(on)
            raise ArgumentError,
                  "expects called with `on: #{on}`, but :#{root} (or its root) is declared `user_facing:` — " \
                  "user_facing: is for top-level fields without nested subfield expectations"
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

          # default:/preprocess: write into the parent, and sensitive: relies on the log filter
          # matching config.on to a top-level field — none of which support an arbitrary nested
          # path yet. A parent is nested whether reached via a dotted path ("address.billing") or by
          # pointing `on:` at another subfield (whose value lives inside its own parent, not at the
          # top level). Reject the combination explicitly rather than silently ignoring it (use .nil?
          # for default/preprocess so an explicit `default: false`/`nil` is still caught).
          nested_parent = on.to_s.include?(".") || subfield_configs.map(&:reader_as).include?(root)
          if nested_parent && (!default.nil? || !preprocess.nil? || sensitive)
            raise ArgumentError,
                  "`default:`/`preprocess:`/`sensitive:` are not supported with a nested `on:` (got on: #{on.inspect})"
          end

          _parse_subfield_configs(*fields, on:, readers:, allow_blank:, allow_nil:, optional:, preprocess:, sensitive:, default:,
                                           metadata:, reader_names:, **validations).tap do |configs|
            duplicated = _duplicate_fields(subfield_configs, configs)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(', ')}" if duplicated.any?

            # NOTE: avoid <<, which would update value for parents and children
            self.subfield_configs += configs

            # Reject contradiction-only contracts (families 1–3) once the new configs are in the tree. Built
            # fresh (not cached) — this is class-load time, off the runtime hot path. Family 4 is a local
            # check in _parse_subfield_configs.
            tree = Axn::Reflection::SubfieldTree.build(internal_field_configs, subfield_configs)
            if (contradiction = Axn::Reflection::SubfieldContradictions.detect(tree))
              raise ArgumentError, contradiction.message
            end
          end
        end

        private

        # Walk an `on:` reader path back to its ultimate top-level field and report whether that field
        # is declared `user_facing:`. `on:` names a reader, which may be dotted ("payload.meta") or
        # rooted at another subfield; only top-level fields can carry `user_facing:`, so recurse
        # through any intervening subfield to the top-level config.
        def _on_roots_at_user_facing_field?(on)
          root = on.to_s.split(".").first
          top = internal_field_configs.find { |c| c.reader_as.to_s == root }
          return !!top.user_facing if top

          sub = subfield_configs.find { |c| c.reader_as.to_s == root }
          sub ? _on_roots_at_user_facing_field?(sub.on) : false
        end

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
          readers:,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          preprocess: nil,
          sensitive: false,
          default: nil,
          metadata: {},
          reader_names: {},
          **validations
        )
          # Handle optional: true by setting allow_blank: true
          allow_blank ||= optional

          _parse_field_validations(*fields, allow_nil:, allow_blank:, **validations).map do |field, parsed_validations|
            if parsed_validations.dig(:type, :coerce)
              raise ArgumentError,
                    "coerce: is not supported on subfields (top-level `expects` fields only; " \
                    "an adapter can coerce deeper by walking the schema)."
            end

            # A dotted field NAME (e.g. "org.company") generates no reader (see
            # `_define_subfield_reader`'s early return), so `model:`'s id→record lookup —
            # which is wired onto the generated reader — never runs, and the advertised
            # `<leaf>_id` is unconsumable. The working spelling swaps which half is dotted:
            # a dotted `on:` with a single-level name (`expects :company, on: "payload.org"`)
            # still gets a reader. Point the error at that spelling.
            if parsed_validations.key?(:model) && field.to_s.include?(".")
              *parents, leaf = field.to_s.split(".")
              working_on = ([on] + parents).join(".")
              raise ArgumentError,
                    "a dotted-name model: subfield (#{fields.map(&:to_s).inspect} with on: #{on}) has no consumable id — " \
                    "a dotted subfield name generates no reader, so the id-to-record lookup never runs. " \
                    "Use the reader spelling instead: expects :#{leaf}, on: \"#{working_on}\", model: ..."
            end

            reader = reader_names[field] || field
            SubfieldConfig.new(field:, validations: parsed_validations, on:, sensitive:, preprocess:, default:, metadata:, reader_as: reader).tap do |config|
              if readers
                _define_subfield_reader(reader, field, on:, validations: parsed_validations)
                _define_boolean_predicate_reader(reader) if Axn::Internal::FieldConfig.boolean?(config)
              end
            end
          end
        end

        # `reader` is the accessor's name (may be aliased via as:/prefix:); `source_field` is the
        # wire key extracted from the `on:` parent.
        def _define_subfield_reader(reader, source_field, on:, validations:)
          # Don't create top-level readers for nested fields
          return if source_field.to_s.include?(".")

          raise ArgumentError, "expects does not support duplicate sub-keys (i.e. `#{reader}` is already defined)" if method_defined?(reader)

          # Record the generated name (copy-on-write so subclasses inherit) for the readerless-parent guard.
          self._generated_subfield_reader_names += [reader]

          Axn::Internal::Memoization.define_memoized_reader_method(self, reader) do
            Axn::Core::FieldResolvers.resolve(type: :extract, field: source_field,
                                              provided_data: Axn::Core::ContractForSubfields.resolve_parent(self, on))
          end

          _define_subfield_model_reader(reader, source_field, validations[:model], on:) if validations.key?(:model)
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

          _define_subfield_model_id_reader(reader, source_field, processed_options, on:)
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
