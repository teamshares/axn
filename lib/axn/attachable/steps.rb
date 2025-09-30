# frozen_string_literal: true

module Axn
  module Attachable
    module Steps
      extend ActiveSupport::Concern

      class_methods do
        def _axn_steps
          _attached_axns.values.select { |descriptor| descriptor.as == :step }.map(&:axn_klass)
        end

        def steps(*steps)
          Array(steps).compact.each do |step|
            raise ArgumentError, "Step #{step} must include Axn module" if step.is_a?(Class) && !step.included_modules.include?(Axn) && !step < Axn

            step("Step #{_axn_steps.length + 1}", step)
          end
        end

        def step(name, axn_klass = nil, error_prefix: nil, **kwargs, &block)
          # Use the registry system
          attach_axn(
            as: :step,
            name:,
            axn_klass:,
            error_prefix:,
            **kwargs,
            &block
          )
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
