# frozen_string_literal: true

module Axn
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

      if facade.outcome.failure?
        return context.exception.default_message? ? "[failed]" : "[failed with '#{context.exception.message}']"
      end

      %([failed with #{context.exception.class.name}: '#{context.exception.message}'])
    end

    def visible_fields
      declared_fields.map do |field|
        value = facade.public_send(field)

        "#{field}: #{format_for_inspect(field, value)}"
      end.join(", ")
    end

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
                          value.inspect
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
          # partially-filtered structure would expose the parent's non-sensitive keys.
          return inspection_filter.filter_param(field, filtered.inspect)
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
    # how inputs_for_logging filters. A duck-typed member without #sensitive is treated as not
    # sensitive (mirrors the ShapeValidator member contract for #method_call).
    def sensitive_member_names(field)
      shape_bearing_configs_under(field).flat_map { |config| collect_sensitive_member_names(config) }
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

    def collect_sensitive_member_names(config)
      members = config.validations.dig(:shape, :members) || []
      members.flat_map do |member|
        names = collect_sensitive_member_names(member)
        names << member.field if member.respond_to?(:sensitive) && action.class._resolve_sensitive_value(member.sensitive, action)
        names
      end
    end
  end
end
