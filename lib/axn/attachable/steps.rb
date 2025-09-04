# frozen_string_literal: true

module Axn
  module Attachable
    module Steps
      extend ActiveSupport::Concern

      included do
        class_attribute :_axn_steps, default: []
      end

      class_methods do
        def steps(*steps)
          Array(steps).compact.each do |step|
            raise ArgumentError, "Step #{step} must include Axn module" if step.is_a?(Class) && !step.included_modules.include?(Axn) && !step < Axn

            step("Step #{_axn_steps.length + 1}", step)
          end
        end

        def step(name, axn_klass = nil, error_prefix: nil, **kwargs, &block)
          axn_klass = axn_for_attachment(
            name:,
            axn_klass:,
            attachment_type: "Step",
            superclass: Object, # NOTE: steps skip inheriting from the wrapping class (to avoid duplicate field expectations/exposures)
            **kwargs,
            &block
          )

          # Add the step to the list of steps
          _axn_steps << axn_klass

          # Set up error handling for steps without explicit labels
          error_prefix ||= "#{name}: "
          error from: axn_klass do |e|
            "#{error_prefix}#{e.message}"
          end
        end
      end

      # Execute steps automatically when the action is called
      def call
        _axn_steps.each do |axn|
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
