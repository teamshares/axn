# frozen_string_literal: true

module Action
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
      return unless facade.is_a?(Action::Result)

      return "[OK]" if context.ok?

      if context.exception.is_a?(Action::Failure)
        return context.exception.message.present? ? "[failed with '#{context.exception.message}']" : "[failed]"
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

      inspection_filter.filter_param(field, inspected_value)
    end

    def inspection_filter = action.send(:inspection_filter)
  end
end
