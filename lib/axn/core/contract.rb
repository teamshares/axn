# frozen_string_literal: true

require "date"

require "active_support/core_ext/enumerable"
require "active_support/core_ext/module/delegation"
require "active_support/core_ext/object/blank"

require "axn/core/validation/fields"
require "axn/core/flow/handlers/invoker"
require "axn/result"
require "axn/core/context/internal"

module Axn
  module Core
    module Contract
      def self.included(base)
        base.class_eval do
          # Copy-on-write stores, frozen at every assignment: declaration replaces the array (`+`,
          # never `<<` — which would now raise FrozenError rather than silently mutating the
          # superclass's contract), so the per-class resolved-subfield cache can key on array
          # identity and concurrent readers always see an immutable snapshot.
          class_attribute :internal_field_configs, :external_field_configs, default: [].freeze

          extend ClassMethods
          include InstanceMethods
        end
      end

      # Every top-level reader and boolean predicate alias is defined in this file, so reflection can
      # verify a Symbol condition still resolves to the framework-generated reader — an alias shares
      # its source_location with the aliased definition, so a user method of the same name (a
      # pre-existing predicate target that suppressed generation, or a plain reader redefined after
      # `expects`) reports a different source and is rejected (declarative-emission would otherwise
      # condition on the wire value while runtime evaluates the user method — the looser direction).
      GENERATED_READER_SOURCE_PATH = __FILE__

      # Optionality is shared by FieldConfig and ShapeConfig (axn-mcp derives `required` from BOTH —
      # field configs and nested shape members — through the same predicate).
      module FieldOptionality
        # A field is optional when it carries no `presence: true` validation, or any validator
        # tolerates blank.
        def optional?
          return true unless validations.key?(:presence) && validations[:presence] == true

          validations.values.any? { |v| v.is_a?(Hash) && v[:allow_blank] == true }
        end
      end

      # The one config type for every declared inbound/outbound field, top-level or subfield — a
      # top-level field is just the depth-0 case (`on: nil`). `reader_as` is the name of the
      # generated accessor method; it defaults to `field` (the wire key), but `expects ..., as:`/
      # `prefix:` decouple them so the caller-facing contract stays `field` while the in-action
      # reader gets its own name. `on:` names the parent reader a subfield is extracted from;
      # `user_facing:` reclassifies a violation of the field into a user-facing failure.
      # `method_call:` opts a subfield into the sharp path — resolving a segment by INVOKING it as a
      # method (Array methods, PORO readers, Data behavioral methods) rather than reading declared
      # data; it is threaded to the resolver as `permit_method_call:` (PRO-2898).
      FieldConfig = Data.define(:field, :validations, :default, :preprocess, :sensitive, :metadata, :reader_as, :user_facing, :on, :method_call) do
        def initialize(field:, validations:, reader_as:, default: nil, preprocess: nil, sensitive: false, metadata: {}, user_facing: false, on: nil,
                       method_call: false)
          super
        end

        def description = metadata[:description]

        def subfield? = !on.nil?

        include FieldOptionality

        # Whether the field is declared `type: :boolean` (drives the generated `?` predicate reader).
        def boolean?
          Array(validations.dig(:type, :klass)) == [:boolean]
        end

        # Whether the declared default is applied at runtime: any non-nil default counts (`default:
        # false` on a boolean is meaningful), matching top-level defaults' key-absence semantics.
        # Schema reflection keys off the same rule, so a declared falsey default is emitted and
        # relaxes requiredness exactly when the runtime would apply it.
        def applied_default?
          !default.nil?
        end
      end

      # One member declared inside a structured field's block (`field :name, ...`).
      # Nested members live in validations[:shape][:members], so the tree is uniform
      # at every depth and walked by both ShapeValidator (runtime) and axn-mcp (schema).
      # `method_call:` opts the member into the sharp path — reading it by INVOKING it as a method
      # on the element being validated (a non-`Data` PORO reader or an Array method) rather than
      # reading declared data (Hash keys, Struct/OpenStruct/Data members). It is threaded to the
      # member's validation read as `permit_method_call:`, the shape-block analog of a subfield's
      # `method_call:` (PRO-2907).
      ShapeConfig = Data.define(:field, :validations, :metadata, :method_call, :sensitive, :user_facing) do
        def initialize(field:, validations:, metadata: {}, method_call: false, sensitive: false, user_facing: false)
          super
        end

        include FieldOptionality

        def description = metadata[:description]
      end

      # Collector for the `field ...` calls inside a structured field's block.
      class ShapeBuilder
        attr_reader :declarations

        def initialize
          @declarations = []
        end

        def field(name, **opts, &block)
          @declarations << [name, opts, block]
        end
      end

      module ClassMethods
        # rubocop:disable Metrics/ParameterLists
        def expects(
          *fields,
          on: nil,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          default: nil,
          preprocess: nil,
          sensitive: false,
          as: nil,
          prefix: nil,
          user_facing: false,
          method_call: false,
          **,
          &block
        )
          # Canonicalize the wire key to a symbol up front so everything downstream — config.field,
          # reader names, duplicate detection, the inbound read path — is symbol-keyed by construction.
          # `expects "note"` and `expects :note` are the same field; a dotted subfield key (`"a.b"`)
          # symbolizes harmlessly (it's only ever compared/split via `.to_s`). See PRO-2790.
          fields = fields.map(&:to_sym)

          fields.each do |field|
            raise ContractViolation::ReservedAttributeError, field if RESERVED_FIELD_NAMES_FOR_EXPECTATIONS.include?(field.to_s)
          end

          # A field's wire key always names a single key; the nested-path capability lives entirely in a
          # dotted `on:` (`expects :b, on: "a"`). A dotted field NAME is therefore never valid — reject it
          # unconditionally, pointed at the dotted-`on:` spelling (PRO-2926). A dotted `on:` VALUE is fine.
          _reject_dotted_field_name!(fields, on:)

          _validate_user_facing!(user_facing)

          # `method_call:` governs how a SUBFIELD's segment is resolved from its parent (invoke vs.
          # read). A top-level field reads its literal wire key from the context Hash — it never
          # method-dispatches — so `method_call: true` without `on:` could never take effect; reject
          # it rather than accept a silently-inert option (matching the ambient default:/coerce:
          # rejections). `method_call: false` is the default, so it's a harmless no-op anywhere.
          if method_call && on.blank?
            raise ArgumentError,
                  "`method_call: true` is only meaningful on a subfield (declared with `on:`) — a top-level field " \
                  "reads its wire key and never invokes a method. Add `on:` to name the parent, or drop `method_call:`."
          end

          reader_names = _resolve_reader_names(fields, as:, prefix:)
          _validate_reader_names!(reader_names)

          validations, metadata = _partition_field_options(fields, **)
          validations[:shape] = _build_shape(fields, validations:, &block) if block

          if on.present?
            return _expects_subfields(*fields, on:, allow_blank:, allow_nil:, optional:, default:, preprocess:, sensitive:, metadata:,
                                               reader_names:, user_facing:, method_call:, **validations)
          end

          _parse_field_configs(*fields, allow_blank:, allow_nil:, optional:, default:, preprocess:, sensitive:, metadata:,
                                        reader_names:, user_facing:, **validations).tap do |configs|
            duplicated = _duplicate_fields(internal_field_configs, configs)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(', ')}" if duplicated.any?

            # Every declaration check has passed; NOW mutate the class (matching _expects_subfields'
            # validate-before-commit ordering), so a rescued declaration error never leaves the class
            # carrying an orphaned config or generated reader. Copy-on-write + freeze: `<<` would
            # mutate the superclass's contract, and identity-keyed caching relies on replacement.
            self.internal_field_configs = (internal_field_configs + configs).freeze
            _define_field_readers!(configs)
          end
        end
        # rubocop:enable Metrics/ParameterLists

        def exposes(
          *fields,
          allow_blank: false,
          allow_nil: false,
          optional: false,
          default: nil,
          sensitive: false,
          **,
          &block
        )
          # Symbolize the wire key (see `expects`) so exposes shares the same symbol-keyed contract.
          fields = fields.map(&:to_sym)

          fields.each do |field|
            raise ContractViolation::ReservedAttributeError, field if RESERVED_FIELD_NAMES_FOR_EXPOSURES.include?(field.to_s)
          end

          # exposes has no `on:`/subfields, so a dotted name has no valid meaning at all (see expects).
          _reject_dotted_field_name!(fields, on: nil, kind: "exposes")

          validations, metadata = _partition_field_options(fields, **)

          validations[:shape] = _build_shape(fields, validations:, outbound: true, &block) if block

          _parse_field_configs(*fields, allow_blank:, allow_nil:, optional:, default:, preprocess: nil, sensitive:, metadata:, **validations).tap do |configs|
            if configs.any? { |c| c.validations.dig(:type, :coerce) }
              raise ArgumentError, "coerce: is not supported on exposes (outbound fields are serialized, not coerced)."
            end

            duplicated = _duplicate_fields(external_field_configs, configs)
            raise Axn::DuplicateFieldError, "Duplicate field(s) declared: #{duplicated.join(', ')}" if duplicated.any?

            # Copy-on-write + freeze (see internal_field_configs above).
            self.external_field_configs = (external_field_configs + configs).freeze
          end
        end

        def inspection_filter
          @__inspection_filter ||= ActiveSupport::ParameterFilter.new(sensitive_fields)
        end

        def sensitive_fields
          _static_sensitive_fields
        end

        # Every config whose `sensitive:` participates in redaction: the declared inbound/outbound fields
        # and subfields, plus (recursively) the members of any shape block they carry. Shape members live
        # in validations[:shape][:members] at every depth, so the walk is uniform — a sensitive member at
        # any nesting level contributes its name to the ParameterFilter set (which redacts by key name at
        # any depth, array elements included). Single-sources the traversal for all three collectors.
        def _sensitive_candidate_configs
          (internal_field_configs + external_field_configs + subfield_configs)
            .flat_map { |config| _flatten_sensitive_candidates(config) }
        end

        def _flatten_sensitive_candidates(config)
          members = config.validations.dig(:shape, :members) || []
          [config, *members.flat_map { |member| _flatten_sensitive_candidates(member) }]
        end

        def _static_sensitive_fields
          _sensitive_candidate_configs
            .select { |c| _config_sensitive(c) == true }
            .flat_map { |c| _sensitive_field_keys(c) }
        end

        def _has_dynamic_sensitive_fields?
          @_has_dynamic_sensitive_fields ||= _sensitive_candidate_configs.any? do |config|
            sensitive = _config_sensitive(config)
            sensitive.is_a?(Proc) || sensitive.is_a?(Symbol)
          end
        end

        def _resolve_sensitive_fields(action_instance)
          return _static_sensitive_fields unless _has_dynamic_sensitive_fields?

          _sensitive_candidate_configs
            .select { |config| _resolve_sensitive_value(_config_sensitive(config), action_instance) }
            .flat_map { |c| _sensitive_field_keys(c) }
        end

        # A shape member's contract is duck-typed — ShapeValidator requires only #field/#validations,
        # and `shape: { members: [...] }` may be supplied raw with member objects that implement no
        # more than that. `#sensitive` is optional (absent on such a raw member), so read it defensively
        # and treat a missing reader as `false`, mirroring how the validator treats a missing
        # #method_call as not opted in.
        def _config_sensitive(config)
          config.respond_to?(:sensitive) ? config.sensitive : false
        end

        # A sensitive `model:` field also redacts its generated `<field>_id` alias (the id is as
        # sensitive as the record). Non-model fields contribute only their own key.
        def _sensitive_field_keys(config)
          keys = [config.field]
          keys << Internal::FieldConfig.model_id_key(config.field) if config.validations[:model]
          keys
        end

        def _resolve_sensitive_value(sensitive, action_instance)
          case sensitive
          when true, false
            sensitive
          when Symbol
            !!action_instance.send(sensitive)
          when Proc
            !!action_instance.instance_exec(&sensitive)
          else
            !!sensitive
          end
        end

        def _build_instance_filter(action_instance)
          ActiveSupport::ParameterFilter.new(_resolve_sensitive_fields(action_instance))
        end

        def _declared_fields(direction)
          raise ArgumentError, "Invalid direction: #{direction}" unless direction.nil? || %i[inbound outbound].include?(direction)

          configs = case direction
                    when :inbound then internal_field_configs
                    when :outbound then external_field_configs
                    else (internal_field_configs + external_field_configs)
                    end

          configs.map(&:field)
        end

        # Internal method for filtering context data by direction
        # Used by instance methods (inputs_for_logging, outputs_for_logging) and async exception reporting
        # When action_instance is provided, dynamic sensitive fields are resolved against that instance.
        def _context_slice(data:, direction: nil, action_instance: nil)
          filter = if action_instance && _has_dynamic_sensitive_fields?
                     _build_instance_filter(action_instance)
                   else
                     inspection_filter
                   end
          sliced = _mask_unfilterable_shapes(data.slice(*_declared_fields(direction)), action_instance)
          filter.filter(sliced)
        end

        # Per-element `sensitive:` redaction works by adding the member's key name to an
        # `ActiveSupport::ParameterFilter`, which redacts Hash keys at any depth — so a member inside a
        # Hash (or an Array of Hashes) is filtered precisely, siblings preserved. But the filter only
        # descends into Hashes: an object-backed shape value (a Data/Struct/PORO), or a malformed non-Hash
        # value where a Hash was expected (which reaches logging before inbound validation can reject it),
        # is opaque to it and would print whole. So for every field/subfield whose shape carries a
        # sensitive member, this walks to the shaped value and replaces a non-Hash value in a
        # member-bearing position with the mask — over-redacting the whole value (its non-sensitive
        # siblings included) rather than risk leaking the secret. Applied to logs, exception context,
        # and `inspect`.
        def _mask_unfilterable_shapes(data, action_instance)
          return data unless data.is_a?(Hash)

          _sensitive_shape_paths(action_instance).reduce(data) do |acc, (wire_path, shape)|
            _mask_value_at_path(acc, wire_path, shape, action_instance)
          end
        end

        # Single-field entry — inspect renders one field at a time. Reuses the whole-hash pass on a
        # one-key hash so a subfield shape rooted under `field` is masked at its nested position too.
        def _mask_unfilterable_shape_value(field, value, action_instance)
          _mask_unfilterable_shapes({ field => value }, action_instance)[field]
        end

        # `[(wire_path, shape)]` for every field/subfield whose shape carries a sensitive member. A
        # top-level field's path is `[field]`; a subfield's is its resolved wire path (from the
        # SubfieldTree cache), so a shape declared on a subfield — `expects :person, on: :payload, …
        # do … end` — is masked at `payload[:person]`, not just where a top-level shape lives.
        def _sensitive_shape_paths(action_instance)
          (internal_field_configs + external_field_configs + subfield_configs).filter_map do |config|
            shape = config.validations.is_a?(Hash) ? config.validations[:shape] : nil
            next unless shape.is_a?(Hash) && _shape_has_sensitive_member?(shape, action_instance)

            wire_path = config.subfield? ? _resolved_subfields.index[config]&.wire_path : [config.field]
            next unless wire_path

            [wire_path, shape]
          end
        end

        # Walk `wire_path` through `value` — Hash keys in either symbol or string form (extraction
        # accepts both), mapping across arrays — and mask the shaped value at the leaf. Every present
        # key form is masked (see `_present_key_variants`); an absent key is left alone. A non-Hash,
        # non-Array intermediate with path still remaining is an object-backed parent (a `method_call:`
        # subfield reads the sensitive shape off it) that ParameterFilter can't descend into — mask it
        # wholesale rather than leak the sensitive member nested inside; a nil/scalar intermediate is
        # preserved (nothing to reach or leak).
        def _mask_value_at_path(value, wire_path, shape, action_instance)
          return _mask_shape_value(value, shape, action_instance) if wire_path.empty?
          return value.map { |element| _mask_value_at_path(element, wire_path, shape, action_instance) } if value.is_a?(Array)
          return _mask_opaque_or_preserve(value) unless value.is_a?(Hash)

          _present_key_variants(value, wire_path.first).reduce(value) do |acc, key|
            acc.merge(key => _mask_value_at_path(acc[key], wire_path.drop(1), shape, action_instance))
          end
        end

        # A non-Hash/Array value in a member-bearing position. `nil` is preserved — it is valid absent
        # data (a nil-tolerant shape) with nothing to leak, and masking it would make absent data look
        # redacted. Anything else is malformed for a shaped field (which expects a Hash/object with
        # members) and ParameterFilter can't redact into it: a structured object could expose the member
        # via `inspect`, and a bare scalar could itself BE the sensitive value the caller mis-supplied
        # (`items: ["111-11-1111"]`). Both reach logging before validation rejects them, so mask.
        def _mask_opaque_or_preserve(value)
          value.nil? ? value : SENSITIVE_FILTERED_MASK
        end

        # Every form of `key` present in `hash` — the key as-is, its string form, and its symbol form.
        # Extraction accepts symbol and string keys (reading symbol-first) and a member/wire-path name
        # may be declared in either form, so a single logical key can appear under more than one form in
        # the same Hash; mask them all, since every form is logged and any could hold the secret.
        def _present_key_variants(hash, key)
          [key, key.to_s, key.to_s.to_sym].uniq.select { |variant| hash.key?(variant) }
        end

        # Whether a shape tree carries a `sensitive:` member anywhere (direct, or in a nested shape).
        # A nil action_instance (async reporting, no instance to resolve a dynamic predicate against)
        # counts only static `sensitive: true`, matching the static `inspection_filter` used there.
        def _shape_has_sensitive_member?(shape, action_instance)
          (shape[:members] || []).any? do |member|
            _member_sensitive?(member, action_instance) ||
              (_member_shape(member) && _shape_has_sensitive_member?(_member_shape(member), action_instance))
          end
        end

        def _member_sensitive?(member, action_instance)
          sensitive = _config_sensitive(member)
          return sensitive == true if action_instance.nil?

          _resolve_sensitive_value(sensitive, action_instance)
        end

        def _member_shape(member)
          return nil unless member.respond_to?(:validations) && member.validations.is_a?(Hash)

          shape = member.validations[:shape]
          shape.is_a?(Hash) ? shape : nil
        end

        # Dispatch on the shape's container — the value must match it, or it's malformed (and reaches
        # logging before validation rejects it, so its arbitrary contents could leak). An `Array` shape
        # maps each element (member-bearing); a `Hash` shape filters the Hash's member keys; a class
        # (Data/Struct/PORO) shape reads members off an object ParameterFilter can't descend into. Any
        # value whose type doesn't match the container is masked wholesale rather than treated as a lone
        # valid element/Hash — only declared member keys would be filtered, leaking arbitrary siblings.
        # `nil` (valid absent data) is preserved throughout via `_mask_opaque_or_preserve`.
        def _mask_shape_value(value, shape, action_instance)
          container = shape[:container]
          if container == Array
            return value.map { |element| _mask_shape_element(element, shape, action_instance) } if value.is_a?(Array)

            return _mask_opaque_or_preserve(value)
          end
          return _mask_shape_element(value, shape, action_instance) if container == Hash

          _mask_opaque_or_preserve(value)
        end

        # A non-Hash value where members are expected is opaque to ParameterFilter → mask it whole. A Hash
        # keeps its own keys (ParameterFilter redacts the sensitive ones); only recurse into a nested-shape
        # member's value when that nested shape actually carries a sensitive member, to avoid needless
        # masking of an unrelated non-Hash deeper down. The member key is matched in either symbol or
        # string form, since extraction accepts both.
        def _mask_shape_element(element, shape, action_instance)
          return _mask_opaque_or_preserve(element) unless element.is_a?(Hash)

          (shape[:members] || []).each_with_object(element.dup) do |member, masked|
            nested = _member_shape(member)
            next unless nested && _shape_has_sensitive_member?(nested, action_instance)

            _present_key_variants(masked, member.field).each do |key|
              masked[key] = _mask_shape_value(masked[key], nested, action_instance)
            end
          end
        end

        private

        # A true duplicate is the SAME wire key declared under the SAME parent route — keyed on the
        # `[on, field]` pair, against `existing` configs AND within `new_configs` itself (`expects :foo,
        # "foo"` is a single batch, so its collision is intra-batch). Keys are symbol-canonical at
        # declaration (PRO-2790), so `:note` and `"note"` are already the same field. For a top-level
        # field `on:` is nil, so this reduces to wire-key identity. Two SUBFIELDS that share a leaf wire
        # key but differ by `on:` are NOT duplicates: they are either two routes to one wire path (a
        # merged node) or two distinct nested fields sharing a leaf key — both legitimate, and both
        # gated separately on reader-name uniqueness (`_validate_subfield_reader_names!`, resolved with
        # `as:`). Declaring a genuine duplicate is rejected because two validations would run on one
        # field, the generated reader would be clobbered, and per-field config would collapse
        # ambiguously. Returns the offending wire-key names.
        def _duplicate_fields(existing, new_configs)
          # `on:` is normalized with `to_s` so `:payload` and `"payload"` (and any symbol/string spelling
          # of the same dotted path) name the same route — matching how the SubfieldTree splits `on:` —
          # rather than slipping two configs onto one wire slot on a spelling difference.
          key_for = ->(c) { [c.on.to_s, c.field] }
          taken = existing.map(&key_for)
          seen = []
          new_configs.select do |c|
            key = key_for.call(c)
            collides = taken.include?(key) || seen.include?(key)
            seen << key
            collides
          end.map(&:field)
        end

        # Map each declared field to the name of its generated reader. Without `as:`/`prefix:` the
        # reader is named for the wire key (identity). `as:` renames a single field's reader;
        # `prefix:` is sugar that prepends to every field's reader (literal concatenation, so the
        # caller supplies the separator). The wire key (`field`) stays canonical regardless.
        #
        # Wire keys are never dotted (dotted field NAMES are rejected upstream by
        # _reject_dotted_field_name!), so a reader name is only ever renamed, never path-derived:
        # `as:` renames a single field, `prefix:` prepends to each. The one dotted constraint left is on
        # the `as:` VALUE itself — a reader name still can't be dotted.
        def _resolve_reader_names(fields, as:, prefix:)
          return fields.to_h { |f| [f, f] } if as.nil? && prefix.nil?

          raise ArgumentError, "`as:` and `prefix:` cannot be combined" if as && prefix

          if as
            raise ArgumentError, "`as:` can only be provided when declaring a single field (use prefix: for several)" if fields.size > 1
            raise ArgumentError, "`as:` reader name may not be dotted (#{as.inspect} would not name a method)" if as.to_s.include?(".")

            { fields.first => as.to_sym }
          else
            fields.to_h { |f| [f, :"#{prefix}#{f}"] }
          end
        end

        # A field's wire key names one key; the nested-path capability lives entirely in a dotted `on:`
        # (`expects :b, on: "a"`). A dotted field NAME is therefore never a valid declaration — reject it
        # everywhere (top-level, subfield, or exposes) and point at the dotted-`on:` spelling. (A dotted
        # `on:` VALUE is orthogonal and fine; only the field NAME is constrained.)
        def _reject_dotted_field_name!(fields, on:, kind: "a top-level field")
          dotted = fields.select { |f| f.to_s.include?(".") }
          return if dotted.empty?

          if kind == "exposes"
            raise ArgumentError,
                  "a dotted field name (#{dotted.map(&:to_s).inspect}) is not valid for exposes " \
                  "(outbound fields have no nested-path reader)"
          end

          *parents, leaf = dotted.first.to_s.split(".")
          suggested_on = [on, *parents].map(&:to_s).reject(&:empty?).join(".")
          raise ArgumentError,
                "a dotted field name (#{dotted.map(&:to_s).inspect}) is not supported — name the leaf and move the " \
                "path into `on:` (e.g. `expects :#{leaf}, on: #{suggested_on.inspect}`). A dotted `on:` pulls a value " \
                "out of a nested structure; a field's own name is always a single wire key."
        end

        # Renamed readers must clear the same reserved-name bar as wire keys (identity readers are
        # already reserved-checked against their wire key in `expects`), and no two declarations may
        # resolve to the same reader name.
        def _validate_reader_names!(reader_names)
          reader_names.reject { |field, reader| field == reader }.each_value do |reader|
            raise ContractViolation::ReservedAttributeError, reader if RESERVED_FIELD_NAMES_FOR_EXPECTATIONS.include?(reader.to_s)
          end

          # A collision is a *new* reader name already claimed by an existing config under a different
          # wire key. A same-wire-key clash is a genuine duplicate field, reported downstream with a
          # clearer DuplicateFieldError, so it's excluded here. Checking every new reader (not just
          # aliases) catches alias-vs-plain clashes in either declaration order — e.g.
          # `expects :bar, as: :foo` then `expects :foo`, which would otherwise silently clobber the
          # `bar` reader. Intra-call duplicates (distinct fields → same reader) are caught too.
          # Only configs that actually generated a reader can be collided with. A dotted-key subfield
          # defines no method, so its name stays free; consult the method table rather than every
          # config so those readerless declarations don't manufacture phantom collisions.
          existing = (internal_field_configs + subfield_configs)
                     .select { |c| method_defined?(c.reader_as) }
                     .to_h { |c| [c.reader_as, c.field] }
          collisions = reader_names.filter_map { |field, reader| reader if existing.key?(reader) && existing[reader] != field }
          collisions |= reader_names.values.tally.select { |_, count| count > 1 }.keys
          raise ArgumentError, "Reader name collision: #{collisions.uniq.join(', ')}" if collisions.any?
        end

        # `user_facing:` reclassifies a violation of this field from a dev-facing exception into a
        # user-facing failure (see Executor). Its value doubles as the surfaced message: `true` uses
        # the field's own validation message; a String overrides it; a Symbol names an action method
        # and a Proc computes it from the InboundValidationError — the full `error`/`fail!`/`fails_on`
        # handler shape. Anything else is a programmer error, so reject it at declaration.
        def _validate_user_facing!(user_facing)
          return if [false, true].include?(user_facing) || user_facing.is_a?(String) || user_facing.is_a?(Symbol) ||
                    Axn::Core::Flow::Handlers::Invoker.callable?(user_facing)

          raise ArgumentError,
                "user_facing: must be true, a String, a Symbol, or a Proc (got #{user_facing.inspect})"
        end

        RESERVED_FIELD_NAMES_FOR_EXPECTATIONS = %w[
          fail! ok?
          inspect default_error
          each_pair
          default_success
          action_name
          inputs
          ambient_context
        ].freeze

        RESERVED_FIELD_NAMES_FOR_EXPOSURES = %w[
          fail! ok?
          inspect each_pair default_error
          ok error success message
          result
          outcome
          exception
          elapsed_time
          finalized?
          __action__
          standalone
          inputs
          ambient_context
        ].freeze

        KNOWN_VALIDATION_KEYS = Set.new(%i[
                                          absence acceptance comparison confirmation exclusion format
                                          inclusion length numericality presence uniqueness
                                          type model validate of shape coerce
                                          if unless on message strict
                                        ]).freeze

        # Types for which a shape block is meaningless — the block describes the members of a
        # structured value (Array elements, Hash keys, or a class's readers), not a scalar.
        SHAPE_INCOMPATIBLE_TYPES = [String, Integer, Float, Numeric, TrueClass, FalseClass, Symbol, NilClass,
                                    Date, Time, DateTime,
                                    :boolean, :uuid, :params].freeze

        # Field-level options a shape member supports (beyond validations + metadata). `sensitive:` is
        # one of them: a member's name is added to the ParameterFilter set by the sensitive-name
        # collectors, which descend into shape members via `_sensitive_candidate_configs`, and
        # ParameterFilter redacts by key name at any depth (array elements included) — so a per-element
        # or nested Hash member redacts precisely. When the value in a member-bearing position is NOT a
        # Hash (an object-backed shape, or malformed input), ParameterFilter can't reach into it, so
        # `_mask_unfilterable_shape_value` redacts that value wholesale before logging/inspect — see
        # there for the safe-over-precise trade-off.
        #
        # Shape members are reader-less, validation/schema-only declarations (a `ShapeConfig`, no reader,
        # no participation in value resolution), so `default:`/`preprocess:` — which produce/transform a
        # value that needs a resolution target to land on (resolved on the read path post-PRO-2903) —
        # have nowhere to apply and are rejected rather than silently dropped when converting to a
        # ShapeConfig. `model:` is rejected separately (see `_build_shape_member`) for the related but
        # distinct reason that it resolves an id and exposes an `_id` companion reader a member lacks.
        SHAPE_MEMBER_FIELD_OPTIONS = %i[allow_blank allow_nil optional method_call sensitive user_facing].freeze
        SHAPE_MEMBER_UNSUPPORTED_OPTIONS = %i[default preprocess].freeze

        # The mask a sensitive value is replaced with — matches `ActiveSupport::ParameterFilter`'s default
        # so wholesale-masked values read identically to per-key-filtered ones.
        SENSITIVE_FILTERED_MASK = "[FILTERED]"

        # Parse a structured field's block into a `{ members: [...], container: <klass> }` validation
        # value. `container` lets ShapeValidator defer a type mismatch to TypeValidator (rather than
        # trying to extract members from the wrong kind of value).
        def _build_shape(fields, validations: nil, outbound: false, &)
          raise ArgumentError, "a shape block can only be declared on a single field" if fields.size > 1

          container = _shape_compatible_type!(validations)

          builder = ShapeBuilder.new
          builder.instance_exec(&)

          members = builder.declarations.map { |name, opts, subblock| _build_shape_member(name, opts, subblock, outbound:) }

          { members:, container: }
        end

        # A member reuses the same option handling as a top-level field (optional/allow_blank/
        # default/etc. + validations + metadata), but yields a ShapeConfig and never a reader.
        def _build_shape_member(name, opts, subblock, outbound: false)
          unsupported = opts.keys & SHAPE_MEMBER_UNSUPPORTED_OPTIONS
          if unsupported.any?
            raise ArgumentError,
                  "shape member `#{name}` does not support #{unsupported.map { |k| "#{k}:" }.join('/')} " \
                  "(shape blocks declare validation/schema only)"
          end

          # `user_facing:` reclassifies an INBOUND violation into the user-facing failure bucket. An
          # outbound (`exposes`) failure means the action produced bad output — always a dev bug, never
          # the caller's fault — and the outbound settlement path never consults `user_facing:`, so on an
          # exposes shape member it would be silently inert. Reject it loudly (top-level `exposes` fields
          # already reject `user_facing:` as an unknown key; this keeps shape members consistent).
          if outbound && opts[:user_facing]
            raise ArgumentError,
                  "shape member `#{name}` does not support user_facing: on exposes — an outbound failure is a " \
                  "dev-facing bug (bad output), never a user-facing one. Drop user_facing:."
          end

          # `model:` resolves a record from an id and exposes a `<field>_id` companion reader — both live
          # in the reader/facade layer a reader-less member never routes through, so on a member it would
          # only type-check the element in place (what `type: Klass` already does) while implying
          # resolution/companion behavior that never happens. Reject it loudly rather than accept the
          # degenerate form, pointing at the plain-type-check alternative.
          if opts.key?(:model)
            raise ArgumentError,
                  "shape member `#{name}` does not support model: — a model field resolves a record from an id " \
                  "and exposes a `#{Internal::FieldConfig.model_id_key(name)}` reader, but a shape member is " \
                  "reader-less and validates the element in place (use `type: Klass` for a plain instance check)."
          end

          field_opts = opts.slice(*SHAPE_MEMBER_FIELD_OPTIONS)
          field_validations, metadata = _partition_field_options([name], **opts.except(*SHAPE_MEMBER_FIELD_OPTIONS))

          field_validations[:shape] = _build_shape([name], validations: field_validations, outbound:, &subblock) if subblock

          config = _parse_field_configs(name, metadata:, **field_opts, **field_validations).first
          raise ArgumentError, "coerce: is not supported on a shape member (top-level `expects` fields only)." if config.validations.dig(:type, :coerce)

          # A member's `user_facing:` has full parity with a field's — validate it through the same
          # gate, so a bad value (`user_facing: 123`) raises the same clear ArgumentError rather than
          # slipping through as an opaque option.
          _validate_user_facing!(config.user_facing)

          ShapeConfig.new(field: name, validations: config.validations, metadata: config.metadata,
                          method_call: config.method_call, sensitive: config.sensitive, user_facing: config.user_facing)
        end

        # A shape block requires a single, structured type:. Mirrors the of: guard's strictness.
        # Returns the structured klass (Array, Hash, or a member-bearing class).
        def _shape_compatible_type!(validations)
          type = validations&.dig(:type)
          klass = type.is_a?(Hash) ? type[:klass] : type
          klasses = Array(klass)
          return klasses.first if klasses.size == 1 && SHAPE_INCOMPATIBLE_TYPES.exclude?(klasses.first)

          raise ArgumentError,
                "a shape block requires a single structured type: (Array, Hash, or a class) — got #{klasses.inspect}"
        end

        def _partition_field_options(fields, **options)
          metadata_keys = Axn.extension_config.registered_field_metadata_keys
          metadata = options.slice(*metadata_keys)
          validations = options.except(*metadata_keys)

          unknown = validations.keys.reject { |k| KNOWN_VALIDATION_KEYS.include?(k) }
          if unknown.any?
            raise ArgumentError,
                  "Unknown key(s) #{unknown.map(&:inspect).join(', ')} in field declaration. " \
                  "Not a recognized validation or registered field metadata key."
          end

          if metadata.present? && fields.size > 1
            raise ArgumentError,
                  "Field metadata (#{metadata.keys.join(', ')}) can only be provided when declaring a single field"
          end

          [validations, metadata]
        end

        # Pure parse: builds the configs without touching the class (no readers defined), so callers
        # can run every declaration check before committing anything.
        def _parse_field_configs( # rubocop:disable Metrics/ParameterLists
          *fields,
          on: nil,
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
          # Handle optional: true by setting allow_blank: true
          allow_blank ||= optional

          if validations.key?(:model)
            _validate_model_batch!(fields, on:)
            _reject_model_transform!(fields, on:, preprocess:, validations:)
          end

          _parse_field_validations(*fields, allow_nil:, allow_blank:, **validations).map do |field, parsed_validations|
            reader = reader_names[field] || field
            FieldConfig.new(field:, validations: parsed_validations, on:, default:, preprocess:, sensitive:, metadata:,
                            reader_as: reader, user_facing:, method_call:)
          end
        end

        # `coerce:`/`preprocess:` transform a scalar WIRE value, but a `model:` field resolves a record
        # from an id/record — its value is the record, not a scalar to coerce, and the class check `model:`
        # already performs is not what `coerce:` does. So neither ever had a coherent meaning on a model
        # field, and (now that subfield transforms resolve on the read path, which the model reader does
        # not route through) applying them would silently do nothing. Reject at declaration — loud, never
        # silently inert. To transform the lookup TOKEN, declare/transform the `<field>_id` field instead.
        def _reject_model_transform!(fields, on:, preprocess:, validations:)
          offending = []
          offending << "coerce:" if validations.key?(:coerce) || (validations[:type].is_a?(Hash) && validations[:type][:coerce])
          offending << "preprocess:" unless preprocess.nil?
          return if offending.empty?

          where = on ? "#{fields.map(&:to_s).inspect} with on: #{on}" : fields.map(&:to_s).inspect
          raise ArgumentError,
                "#{offending.join(' / ')} is not supported on a `model:` field (#{where}) — a model field resolves a " \
                "record from an id, not a scalar to coerce/preprocess. To transform the lookup token, declare or " \
                "transform the `<field>_id` field instead."
        end

        # A model: batch that also names a model field's own `<field>_id` companion (e.g.
        # `expects :company, :company_id, model:`) can never work at any level: model: applies to
        # EVERY field in the batch, so the `<field>_id` is itself a model: field (it would require
        # `<field>_id_id` and reject a raw id), and it collides with the raw-id reader the model:
        # field already generates. A model: field exposes its own `<field>_id` reader for the raw id,
        # so the explicit one is both redundant and broken. (Declaring the id in a separate expects
        # doesn't help either — the generated `<field>_id` reader already exists, so it trips the
        # duplicate-reader guard.)
        def _validate_model_batch!(fields, on: nil)
          batch = fields.map(&:to_sym)
          model_field = batch.find { |f| batch.include?(Axn::Internal::FieldConfig.model_id_key(f)) }
          return unless model_field

          id_key = Axn::Internal::FieldConfig.model_id_key(model_field)
          where = on ? "#{fields.map(&:to_s).inspect} with on: #{on}" : fields.map(&:to_s).inspect
          raise ArgumentError,
                "a model: batch (#{where}) names both " \
                ":#{model_field} and its own id companion :#{id_key} — but model: applies to every field " \
                "in the batch, so :#{id_key} becomes a second model: field (requiring :#{id_key}_id) " \
                "rather than the raw id. The model: field :#{model_field} already generates a " \
                ":#{id_key} reader for the raw id; drop the explicit :#{id_key}."
        end

        # Generate the readers for an already-validated, already-committed batch of top-level inbound
        # configs. Two passes, matching _define_subfield_readers!: all explicit primary readers first,
        # then the auto-generated companions (boolean `?` predicates, model `<field>_id` readers), so a
        # companion defers to an explicit same-named reader regardless of declaration order.
        def _define_field_readers!(configs)
          # rubocop:disable Style/CombinableLoops
          configs.each { |c| _define_field_reader(c.reader_as, c.field) }
          configs.each do |c|
            _define_boolean_predicate_reader(c.reader_as) if c.boolean?
            _define_model_id_reader(c.reader_as, c.field, c.validations[:model]) if c.validations.key?(:model)
          end
          # rubocop:enable Style/CombinableLoops
        end

        # An auto-generated companion reader (boolean predicate, model `<field>_id`) defers to any
        # pre-existing method of the same name rather than clobbering it — but, unlike a silent skip,
        # leaves a debug-level breadcrumb so a surprising shadow is discoverable. Returns true when
        # the name is free (caller should define it), false when it's taken (already logged).
        def _reader_name_available?(name, kind:)
          return true unless method_defined?(name) || private_method_defined?(name)

          Axn.config.logger.debug { "[Axn] #{self.name || 'Action'}: skipping auto-generated #{kind} reader `#{name}` (already defined)" }
          false
        end

        # `model:` fields get a `<reader>_id` reader meaning "the primary key of the resolved
        # record", reading the raw id from the inbound context. The subfield contract defines the
        # same reader against an `on:` parent — both share `_define_model_id_reader_from`.
        def _define_model_id_reader(reader, source_field, model_options)
          by_primary_key = model_options.is_a?(Hash) && model_options[:finder] == :find
          _define_model_id_reader_from(reader:, source_field:, by_primary_key:) do |id_key|
            @__context.provided_data[id_key]
          end
        end

        # Defines the `<reader>_id` reader shared by the top-level and subfield `model:` contracts.
        # For the default (id-based `:find`) finder a directly-supplied, non-blank id IS the pk, so
        # it's returned without resolving the record; otherwise (a record was passed, the id was
        # blank, or a custom finder is in play) it reads the resolved — and memoized — record's `.id`,
        # so it never triggers a second lookup. A blank id is treated as absent (matching the
        # resolver/consistency check), and a missing record yields nil rather than the raw input —
        # which for a custom finder is a lookup token, not a primary key. `raw_reader` yields the raw
        # `<field>_id` value for the caller's context (top-level provided_data vs. the `on:` parent).
        def _define_model_id_reader_from(reader:, source_field:, by_primary_key:, &raw_reader)
          id_reader = Internal::FieldConfig.model_id_key(reader)
          return unless _reader_name_available?(id_reader, kind: "model id")

          id_key = Internal::FieldConfig.model_id_key(source_field)
          define_method(id_reader) do
            raw = instance_exec(id_key, &raw_reader)
            next raw if by_primary_key && !raw.nil? && !raw.to_s.strip.empty?

            record = public_send(reader)
            record.respond_to?(:id) ? record.id : nil
          end
        end

        def _define_field_reader(reader, source = reader)
          # Allow local access to explicitly-expected fields on the action instance.
          # NOTE: exposes fields are intentionally excluded — access those via result.field instead.
          # `reader` is the method name (may be aliased via as:/prefix:); `source` is the wire key
          # the value actually lives under in the inbound context.
          define_method(reader) { internal_context.public_send(source) }
        end

        def _define_boolean_predicate_reader(field)
          field_name = field.to_s
          return if field_name.end_with?("?")

          predicate_name = "#{field_name}?"
          return unless _reader_name_available?(predicate_name, kind: "boolean predicate")

          alias_method predicate_name, field
        end

        # `coerce: <Type>` → `type: { klass: <Type>, coerce: true }`. The sugar value carries the
        # target type (a Class or array of Classes), never a boolean — the boolean lives only inside
        # the type hash. Combining with an explicit `type:` is contradictory (the sugar already
        # declares the type), so it raises.
        def _expand_coerce_sugar!(validations)
          return unless validations.key?(:coerce)

          if validations.key?(:type)
            raise ArgumentError,
                  "coerce: and type: cannot be combined (coerce: already declares the type). " \
                  "Use `type: { klass: …, coerce: true }` when you also need sibling type options."
          end

          target = validations.delete(:coerce)
          if [true, false].include?(target)
            raise ArgumentError,
                  "coerce: must be a type (a Class or array of Classes), not a boolean. " \
                  "The boolean form lives inside `type: { klass: …, coerce: true }`."
          end

          validations[:type] = { klass: target, coerce: true }
        end

        # A coerce target must be in the v1 coercible set (Axn::Reflection::Coercion::SUPPORTED); an
        # unsupported type raises not-yet-supported so expanding the set stays a deliberate future
        # ticket. `String` may accompany a coercible type as a passthrough branch (the raw wire scalar
        # itself), which is why `coerce: [Date, String]` is legal — but a target set with no coercible
        # member coerces nothing and is a declaration mistake.
        def _validate_coercion!(type_hash)
          # The flag is a strict boolean — this base layer raises on DSL misuse rather than treating
          # any truthy value (`coerce: :typo`) as enabled. `coerce: false` is a valid no-op (the type
          # is declared, coercion off), so it passes here and skips the coercible-set checks below.
          coerce = type_hash[:coerce]
          raise ArgumentError, "coerce: must be true or false (got #{coerce.inspect})" unless [true, false].include?(coerce)
          return unless coerce

          klasses = Array(type_hash[:klass])
          coercible = Axn::Reflection::Coercion.coercible_klasses(type_hash)
          unsupported = klasses - coercible - [String]

          unless unsupported.empty?
            raise ArgumentError,
                  "coerce: does not yet support #{unsupported.map(&:inspect).join(', ')} " \
                  "(supported: #{Axn::Reflection::Coercion::SUPPORTED.join(', ')}). " \
                  "String may accompany a coercible type as a passthrough."
          end

          return unless coercible.empty?

          raise ArgumentError,
                "coerce: needs at least one coercible type (#{Axn::Reflection::Coercion::SUPPORTED.join(', ')}); " \
                "got #{klasses.map(&:inspect).join(', ')}."
        end

        # A blank gate is canonicalized away at declaration, EXACTLY tracking the set of condition
        # values ActiveModel ignores. AM resolves if:/unless: through
        # ActiveSupport::Callbacks::Callback#check_conditionals, which early-returns an empty
        # condition list `if conditionals.blank?` (activesupport 7.2.2.2, active_support/callbacks.rb)
        # — so a blank condition is NO conditional at all and the validators run unconditionally.
        # Measured against AM 7.2.2.2 via `validates :f, presence: true, if: <value>` with the field
        # absent: `nil`, `false`, `""`, any whitespace-only String, and `[]` all RUN the validators
        # (they are blank, hence ungated — `if: false` means "no condition", NOT "never run"), which
        # is precisely `value.blank?`. We reuse that same predicate here, so a REMAINING gate key
        # downstream — the push-down exemption in _parse_field_validations, reflection's
        # conditionally_gated?, and the contradiction carve-outs — always denotes a REAL, enforced
        # gate. Without this, a blank gate would be classified as gated though it runs
        # unconditionally: ancestor-forcing would be wrongly relaxed, and the dead-tolerance check
        # would wrongly accept a contradiction-shaped contract (schema looser than runtime). Only
        # non-blank opaque values survive as gates (a Symbol, a Proc; a non-blank String survives
        # here but AM then rejects it at validator build — loud, unchanged). Mutates `validations`.
        def _canonicalize_blank_gates!(validations)
          Internal::FieldConfig::CONDITIONAL_GATE_KEYS.each do |key|
            next unless validations.key?(key)

            validations.delete(key) if validations[key].blank?
          end
        end

        # This method applies any top-level options to each of the individual validations given.
        # It also allows our custom validators to accept a direct value rather than a hash of options.
        def _parse_field_validations(
          *fields,
          allow_nil: false,
          allow_blank: false,
          **validations
        )
          _canonicalize_blank_gates!(validations)

          # `coerce: <Type>` sugar → a coerce flag inside the type bag (coercion binds to the type;
          # it is meaningless without one). Runs before the type: sugar so the resulting `{ klass: }`
          # hash flows through the normal path.
          _expand_coerce_sugar!(validations)

          # Apply syntactic sugar for our custom validators (convert shorthand to full hash of options)
          validations[:type] = Axn::Validators::TypeValidator.apply_syntactic_sugar(validations[:type], fields) if validations.key?(:type)
          validations[:model] = Axn::Validators::ModelValidator.apply_syntactic_sugar(validations[:model], fields) if validations.key?(:model)
          validations[:validate] = Axn::Validators::ValidateValidator.apply_syntactic_sugar(validations[:validate], fields) if validations.key?(:validate)

          # Validate the coerce target set (covers BOTH the sugar above and an explicit
          # `type: { klass:, coerce: true }`) once the type bag is canonical.
          _validate_coercion!(validations[:type]) if validations[:type].is_a?(Hash) && validations[:type].key?(:coerce)

          if validations.key?(:of)
            declared_klasses = Array(validations.dig(:type, :klass))
            raise ArgumentError, "of: requires type: Array (got #{declared_klasses.inspect})" unless declared_klasses == [Array]

            validations[:of] = Axn::Validators::OfValidator.apply_syntactic_sugar(validations[:of], fields)
            raise ArgumentError, "of: must supply :klass" if validations[:of][:klass].nil?
          end

          # Push allow_blank and allow_nil to the individual validations
          if allow_blank || allow_nil
            # A truthy explicit presence: can never fire under a tolerance flag — the pushed-down
            # allow_blank/allow_nil would make the presence validator accept exactly the values it
            # exists to reject — so the combination is dead machinery, rejected at declaration.
            # (`presence: false` is coherent: explicit suppression, same intent as the flag.)
            if validations[:presence]
              raise ArgumentError,
                    "optional:/allow_blank:/allow_nil: cannot be combined with an explicit `presence:` — " \
                    "the tolerance is pushed into every validator, so the presence check could never fail. " \
                    "Declare one requiredness signal (drop the flag, or drop presence:)."
            end

            # ActiveModel's shared "default" options (`if:`/`unless:`/`on:`/`strict:`/`allow_blank:`/
            # `allow_nil:`) ride the hash as sibling keys of the validators but are NOT validators —
            # there is nothing to push tolerance into, and normalizing them as scalars would corrupt
            # them (e.g. `strict: true` → `strict: { allow_blank:, allow_nil: }`, which then raises a
            # bare `TypeError` at strict-raise time instead of `ActiveModel::StrictValidationFailed`).
            # Slice them out (reusing AM's own canonical list so the set can't drift), transform only
            # the real validators, then restore verbatim. Core-Ruby delete (not ActiveSupport's
            # Hash#except!): axn runs outside Rails, where that core_ext may never be loaded.
            shared_option_keys = Axn::Validation::Base.shared_validation_option_keys
            shared_options = validations.slice(*shared_option_keys)
            shared_option_keys.each { |key| validations.delete(key) }
            validations.transform_values! do |v|
              # A falsy validator value (`presence: false`, or a `nil`/`false` on any validator) is
              # disabled — `validates` skips it (`next unless options`), so there is nothing to push
              # tolerance into; pass it through unchanged (mirrors AM's own falsy-skip).
              next v unless v

              # Any other value is normalized exactly as `validates` would (scalar → options hash),
              # then the tolerance rides on top — so `numericality: true`, `inclusion: [..]`/`1..5`,
              # `format: /re/`, etc. combine transparently with optional:/allow_blank:/allow_nil:,
              # matching how they behave without a tolerance flag (PRO-2915).
              { allow_blank:, allow_nil: }.merge(Axn::Validation::Base.normalize_validator_options(v))
            end
            validations.merge!(shared_options)
          else
            # Apply default presence validation (unless the type is boolean or params)
            type_values = Array(validations.dig(:type, :klass))
            validations[:presence] = true unless validations.key?(:presence) || type_values.include?(:boolean) || type_values.include?(:params)
          end

          fields.map { |field| [field, validations] }
        end
      end

      # Keys the framework owns in the execution/exception-report context, so they can't be set via
      # set_execution_context or the additional_execution_context hook: :inputs/:outputs are the
      # structural pair, and :async/:ambient_context/:axn_stack/:tags/:dimensions are
      # framework-populated in execution_context / Internal::ExceptionContext.build — reserving them
      # here prevents a user value from being silently overwritten when they're assigned after merging
      # the user's extra keys. :tags/:dimensions carry the resolved `tag`/`dimension` facets (PRO-2853).
      RESERVED_EXECUTION_CONTEXT_KEYS = %i[inputs outputs async ambient_context axn_stack tags dimensions].freeze

      module InstanceMethods
        def internal_context = @__internal_context ||= _build_context_facade(:inbound)
        def result = @__result ||= _build_context_facade(:outbound)

        # Resolved declared-inbound fields as a Hash (defaults/preprocess applied, model: fields
        # resolved to their record), keyed by wire key. Splat into a nested action to forward
        # inputs: `Child.call(**inputs, override: x)`. Reads through internal_context (not raw
        # provided_data) so a model: field supplied by `<field>_id` forwards the resolved record —
        # the record lives only in the reader. Fields whose resolved value is nil are omitted, so a
        # nested action still applies its own absent/default handling for them.
        def inputs
          self.class._declared_fields(:inbound).each_with_object({}) do |field, hash|
            value = internal_context.public_send(field)
            hash[field] = value unless value.nil?
          end
        end

        delegate :default_error, :default_success, to: :internal_context

        # Accepts:
        # - a single Axn::Result: forwards (result.declared_fields & own outbound declared fields)
        # - two positional arguments (key, value)
        # - a hash of key/value pairs
        def expose(*args, **kwargs)
          return _expose_from_result(args.first) if args.size == 1 && kwargs.empty? && args.first.is_a?(Axn::Result)

          if args.any?
            if args.size != 2
              raise ArgumentError,
                    "expose must be called with exactly two positional arguments (or a hash of key/value pairs)"
            end

            kwargs.merge!(args.first => args.last)
          end

          kwargs.each do |key, value|
            # Symbolize the exposure key to match the symbol-canonical outbound contract (PRO-2790):
            # `exposes "saved"` declares `:saved`, and the result facade / outbound validation read
            # `exposed_data[:saved]`. Without this a string-keyed write (`expose("saved", v)`,
            # `expose("saved" => v)`, or a string `expose_return_as`) would store under "saved" and
            # the declared field would read nil.
            key = key.to_sym

            raise Axn::ContractViolation::UnknownExposure, key unless result.respond_to?(key)

            @__context.exposed_data[key] = value
          end
        end

        # Set additional context to be included in execution_context for exception reporting/handlers.
        # This context is NOT included in automatic pre/post logging (which only logs inputs/outputs).
        # Framework-owned keys (RESERVED_EXECUTION_CONTEXT_KEYS) are stripped before merging.
        def set_execution_context(**kwargs)
          @__additional_execution_context ||= {}
          @__additional_execution_context.merge!(kwargs.except(*RESERVED_EXECUTION_CONTEXT_KEYS))
        end

        # Clear any previously set additional execution context
        def clear_execution_context
          @__additional_execution_context = nil
        end

        # Returns a structured hash for exception reporting and handlers.
        # Contains :inputs, :outputs, any extra keys from set_execution_context / additional_execution_context
        # hook, and (when present) a sensitive-filtered :ambient_context.
        # Framework-owned keys (RESERVED_EXECUTION_CONTEXT_KEYS) from extra context are stripped before merging.
        def execution_context
          explicit_context = @__additional_execution_context || {}
          hook_context = respond_to?(:additional_execution_context, true) ? additional_execution_context : {}
          extra_context = explicit_context.merge(hook_context).except(*RESERVED_EXECUTION_CONTEXT_KEYS)

          ctx = {
            inputs: _safe_execution_context_slice { inputs_for_logging },
            outputs: _safe_execution_context_slice { outputs_for_logging },
            **extra_context,
          }

          # Resolving/filtering ambient context can raise (e.g. a failing ambient_context_provider
          # whose error is now memoized and re-raised on every read — see
          # Axn::Core::AmbientContext#ambient_context). Building exception-report context must never
          # itself raise, or the real exception never reaches Axn.config.on_exception, so omit
          # ambient_context here rather than propagate.
          ambient = _safe_execution_context_slice do
            ambient_filter = self.class._has_dynamic_sensitive_fields? ? self.class._build_instance_filter(self) : self.class.inspection_filter
            ambient_filter.filter(ambient_context)
          end
          ctx[:ambient_context] = ambient if ambient.present?
          ctx
        end

        private

        # Exception-report context must never itself raise (a failing ambient provider can propagate
        # through sensitive-predicate evaluation while building any of these slices, since resolving
        # inputs_for_logging/outputs_for_logging may evaluate a dynamic `sensitive:` predicate that
        # reads ambient_context). Degrade to {} rather than let it escape.
        def _safe_execution_context_slice
          yield
        rescue StandardError
          {}
        end

        # Forward the intersection of a nested result's declared exposures and this action's own
        # declared exposures. Reads declared fields (static contract) so it is safe on a failed
        # result — it forwards whatever the child managed to expose (nil for the rest) and never
        # inspects ok?/error or calls fail!. An empty intersection is always a wiring mistake.
        def _expose_from_result(source_result)
          forwardable = source_result.declared_fields & self.class._declared_fields(:outbound)

          if forwardable.empty?
            raise Axn::ContractViolation::NoMatchingExposures.new(
              declared: self.class._declared_fields(:outbound),
              exposed: source_result.declared_fields,
            )
          end

          forwardable.each do |field|
            @__context.exposed_data[field] = source_result.public_send(field)
          end
        end

        # Filtered inbound fields only (no additional context) - used by automatic logging and execution_context
        def inputs_for_logging
          self.class._context_slice(data: @__context.__combined_data, direction: :inbound, action_instance: self)
        end

        # Filtered outbound fields only (no additional context) - used by automatic logging and execution_context
        def outputs_for_logging
          self.class._context_slice(data: @__context.__combined_data, direction: :outbound, action_instance: self)
        end

        def _build_context_facade(direction)
          raise ArgumentError, "Invalid direction: #{direction}" unless %i[inbound outbound].include?(direction)

          klass = direction == :inbound ? Axn::InternalContext : Axn::Result
          implicitly_allowed_fields = direction == :inbound ? self.class._declared_fields(:outbound) : []

          klass.new(action: self, context: @__context, declared_fields: self.class._declared_fields(direction), implicitly_allowed_fields:)
        end
      end
    end
  end
end
