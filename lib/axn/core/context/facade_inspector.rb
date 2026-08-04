# frozen_string_literal: true

require "axn/internal/identity"
require "axn/internal/reflection/property_names"
require "axn/internal/rendering"

module Axn
  module Core
    class ContextFacadeInspector
      def initialize(action:, facade:, context:)
        @action = action
        @facade = facade
        @context = context
      end

      def call
        str = [status, visible_fields].compact_blank.join(" ")

        "#<#{class_name} #{str}>"
      end

      private

      attr_reader :action, :facade, :context

      def status
        return unless facade.is_a?(Axn::Result)

        return "[OK]" if context.ok?

        return default_message? ? "[failed]" : "[failed with '#{exception_message}']" if facade.outcome.failure?

        %([failed with #{Axn::Internal::Rendering.class_name(context.exception)}: '#{exception_message}'])
      end

      # Whether the failure carries no reason of its own, so `inspect` can say "[failed]" plainly.
      #
      # `default_message?` is axn's own predicate, but it is DEFINED only on `Axn::Failure`, and the exception
      # on a failed result frequently is not one: an exception classified into the failure bucket by
      # `fails_on`, and a `user_facing:` validation error, both settle here carrying their own class. So it is
      # asked only of an exception that answers it — the same guard `Result#_user_provided_error_message` puts
      # on the identical read, which spells it as a dispatched `is_a?`. Here the type test is undispatched
      # (`Module#===`), on the same terms as the reads below: whether axn may call its own method on a
      # caller-supplied object is a fact about the class hierarchy, not that object's opinion.
      def default_message?
        Axn::Internal::Identity.kind?(context.exception, Axn::Failure) && context.exception.default_message?
      end

      # An exception carried on a failed result is caller-supplied, and `inspect` is called from loggers,
      # debuggers and spec failure output — the places a raise is hardest to trace back. So both the class
      # and the message come from the one reader that dispatches nothing the exception can override and
      # renders the bytes it answers with.
      def exception_message = Axn::Internal::Rendering.exception_message(context.exception)

      # Both operands of each pair are foreign, so both go through a funnel — every operand of a composition
      # or none of them, since an `Encoding::CompatibilityError` needs two INCOMPATIBLE ones and rendering just
      # one converts a working join into a raise.
      #
      # The NAME goes through the shared name renderer (`renderable_label`, which handles a Symbol; a declared
      # name is one). The VALUE's rendering is made uniform where it is produced, by `format_for_inspect`
      # routing each dispatch of a caller's `inspect` through `Internal::Identity.describe` — so what arrives
      # here is already valid UTF-8, and this composition can just join it.
      #
      # `inspect` is called from loggers, debuggers and spec-failure output, which makes a raise here the
      # hardest kind to trace back to its cause: an exposed Latin-1 field name holding a UTF-8 value made
      # `result.inspect` raise with the result itself perfectly intact underneath.
      def visible_fields
        declared_fields.map do |field|
          value = facade.public_send(field)

          "#{rendered_field_name(field)}: #{format_for_inspect(field, value)}"
        end.join(", ")
      end

      # The reflection layer's renderer, reached directly rather than re-derived: `facade_inspector` sits ABOVE
      # that layer (nothing it requires reaches `axn/core`), so there is no cycle to route around — unlike
      # `Internal::FieldConfig`, which the reflection layer requires and which therefore composes its own.
      def rendered_field_name(field) = Axn::Internal::Reflection::PropertyNames.renderable_label(field)

      def class_name = facade.class.name
      def declared_fields = facade.send(:declared_fields)

      def format_for_inspect(field, value)
        return value.inspect if value.nil?

        # A sensitive shape member inside a non-Hash value (an object-backed shape, or malformed input) is
        # opaque to the key-name filter below, so mask that value wholesale first; a Hash value is left for
        # the per-key filtering path to redact precisely. See `_mask_unfilterable_shape_value`.
        value = action.class._mask_unfilterable_shape_value(field, value, action)

        # Initially based on https://github.com/rails/rails/blob/800976975253be2912d09a80757ee70a2bb1e984/activerecord/lib/active_record/attribute_methods.rb#L527
        inspected_value = if value.is_a?(String) && value.length > 50
                            "#{value[0, 50]}...".inspect
                          elsif value.is_a?(Date) || value.is_a?(Time)
                            %("#{value.to_fs(:inspect)}")
                          elsif defined?(::ActiveRecord::Relation) && value.instance_of?(::ActiveRecord::Relation)
                            # Avoid hydrating full AR relation (i.e. avoid loading records just to report an error)
                            "#{value.name}::ActiveRecord_Relation"
                          else
                            # `Internal::Identity.describe`, not a bare `inspect`: this is a caller's value and
                            # `inspect` is its own code, so the call is made (its rendering is what makes this
                            # line useful) but its failure absorbed, and whatever it answers is rendered to
                            # valid UTF-8 — which is what lets the composition above just join it. The three
                            # branches beside this one build their text from ASCII or from `String#inspect`,
                            # whose non-ASCII output is escaped for every encoding but UTF-8, so they are
                            # already UTF-8-compatible.
                            Axn::Internal::Identity.describe(value)
                          end

        # Sensitive subfields and shape members live nested inside a structured value; once it has been
        # stringified above, `filter_param(field, ...)` (which matches on the top-level key only) can no
        # longer reach the nested keys. So filter the structure itself first — Hash or Array, since an
        # Array-element member redacts per element — then inspect the filtered result. If nothing nested
        # matched, fall through so a sensitive top-level field (whose whole value is redacted by name) is
        # still handled.
        if value.is_a?(Hash) || value.is_a?(Array)
          nested_keys = nested_sensitive_keys(field)
          unless nested_keys.empty?
            filtered = ActiveSupport::ParameterFilter.new(nested_keys).filter({ field => value })[field]
            # Route the filtered structure back through the top-level filter (same as the scalar path
            # below) so a field that is ITSELF sensitive redacts wholesale by name — otherwise the
            # partially-filtered structure would expose the parent's non-sensitive keys. Rendered through the
            # same reader as the scalar path: the container is axn's own copy, but its CONTENTS are the
            # caller's, and `Hash#inspect`/`Array#inspect` dispatch each element's own `inspect`.
            return inspection_filter.filter_param(field, Axn::Internal::Identity.describe(filtered))
          end
        end

        inspection_filter.filter_param(field, inspected_value)
      end

      def inspection_filter
        @inspection_filter ||= if action.class._has_dynamic_sensitive_fields?
                                 action.class._build_instance_filter(action)
                               else
                                 action.class.inspection_filter
                               end
      end

      # ParameterFilter keys for sensitive values nested inside `field`'s structured value: sensitive
      # subfield wire paths (dotted, precise to their parent) plus sensitive shape-member names (flat —
      # a member redacts by name wherever it appears, i.e. every array element and any nesting depth).
      def nested_sensitive_keys(field)
        subfield_paths = action.subfield_configs
                               .select { |config| sensitive_subfield_on?(config, field) }
                               .map { |config| action.class._resolved_subfields.index[config].wire_path.join(".") }

        subfield_paths + sensitive_member_names(field)
      end

      # `field` is the top-level parent's wire key; the config's resolved wire path (from the per-class
      # SubfieldTree cache) already translated any `as:`/`prefix:` alias and nested `on:` chain back to
      # wire keys, so a sensitive subfield matches whichever top-level value it ultimately lives under.
      def sensitive_subfield_on?(config, field)
        path = action.class._resolved_subfields.index[config]
        path && path.wire_path.first == field && action.class._resolve_sensitive_value(config.sensitive, action)
      end

      # Names of sensitive shape members that render inside `field`'s displayed value (nested shapes
      # included), with dynamic `sensitive:` predicates resolved against the action instance — matching
      # how inputs_for_logging filters. The walk itself belongs to the contract (see
      # `Contract#_sensitive_member_names`), which reuses the answer when no `sensitive:` needs an
      # instance; `inspect` asks once per displayed field, over the whole stored graph.
      def sensitive_member_names(field)
        shape_bearing_configs_under(field).flat_map { |config| action.class._sensitive_member_names(config, action) }
      end

      # Configs whose shape members would appear inside `field`'s value: the top-level field config
      # itself, plus any subfield config resolving to a wire path rooted at `field` (a shape block
      # declared on a subfield). Logging redacts both because `_sensitive_candidate_configs` walks
      # `subfield_configs`; inspect must match rather than only covering top-level shapes.
      def shape_bearing_configs_under(field)
        top_level = (action.class.internal_field_configs + action.class.external_field_configs).select { |c| c.field == field }
        subfields = action.subfield_configs.select do |config|
          path = action.class._resolved_subfields.index[config]
          path && path.wire_path.first == field
        end
        top_level + subfields
      end
    end
  end
end
