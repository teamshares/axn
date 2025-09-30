# frozen_string_literal: true

module Axn
  module Attachable
    module Steps
      extend ActiveSupport::Concern

      class_methods do
        def _axn_steps
          _attached_axns.values.select { |descriptor| descriptor.as == :step }.map(&:axn_klass)
        end
      end

      # Execute steps automatically when the action is called
      def call
        self.class._axn_steps.each do |axn|
          _merge_step_exposures!(axn.call!(**_merged_context_data))
        end
      end

      private

      def _merged_context_data
        @__context.__combined_data
      end

      # Each step can expect the data exposed from the previous steps
      def _merge_step_exposures!(step_result)
        step_result.declared_fields.each do |field|
          @__context.exposed_data[field] = step_result.public_send(field)
        end
      end
    end
  end
end
