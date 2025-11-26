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

      # Handle subfield filtering for hash values
      if value.is_a?(Hash) && sensitive_subfields?(field)
        filtered_value = filter_subfields(field, value)
        return filtered_value.inspect
      end

      inspection_filter.filter_param(field, inspected_value)
    end

    def inspection_filter = action.class.inspection_filter

    def sensitive_subfields?(field)
      action.subfield_configs.any? { |config| config.on == field && config.sensitive }
    end

    def filter_subfields(field, value)
      # Build a nested structure with subfield paths for filtering
      nested_data = { field => value }

      # Create a filter with the subfield paths
      sensitive_subfield_paths = action.subfield_configs
                                       .select { |config| config.on == field && config.sensitive }
                                       .map { |config| "#{field}.#{config.field}" }

      return value if sensitive_subfield_paths.empty?

      subfield_filter = ActiveSupport::ParameterFilter.new(sensitive_subfield_paths)
      filtered_data = subfield_filter.filter(nested_data)

      filtered_data[field]
    end
  end
end
