# frozen_string_literal: true

module Action
  module Attachable
    module Steps
      extend ActiveSupport::Concern

      included do
        class_attribute :_axn_steps, default: []
      end

      Entry = Data.define(:label, :axn)

      class_methods do
        def steps(*steps)
          # Convert action classes to Entry objects if they're not already
          converted_steps = Array(steps).compact.map do |step|
            if step.is_a?(Class)
              Entry.new(label: step.name || "Step", axn: step)
            else
              step
            end
          end

          self._axn_steps += converted_steps
        end

        def step(name, axn_klass = nil, **kwargs, &block)
          axn_klass = axn_for_attachment(
            name:,
            axn_klass:,
            attachment_type: "Step",
            superclass: Object, # NOTE: steps skip inheriting from the wrapping class (to avoid duplicate field expectations/exposures)
            **kwargs,
            &block
          )

          # Add the step to the list of steps
          steps Entry.new(label: name, axn: axn_klass)
          error from: axn_klass do |e|
            "#{name} step #{e.message}"
          end
        end
      end

      # Execute steps automatically when the action is called
      def call
        # Execute steps first if any are defined
        execute_steps if self.class._axn_steps.any?

        # Call the parent implementation (which is empty by default)
        super
      end

      private

      def execute_steps
        self.class._axn_steps.each_with_index do |step, idx|
          # Ensure step is an Entry object
          step = Entry.new(label: "Step #{idx + 1}", axn: step) unless step.is_a?(Entry)

          begin
            step_result = step.axn.call!(**merged_context_data)
            raise "Step #{step.label} returned nil result" if step_result.nil?

            merge_step_exposures!(step_result)
          rescue StandardError => e
            # Re-raise with step context
            raise "#{step.label} step #{e.message}"
          end
        end
      end

      def merged_context_data
        @__context.__combined_data
      end

      # Each step can expect the data exposed from the previous steps
      def merge_step_exposures!(step_result)
        step_result.declared_fields.each do |field|
          @__context.exposed_data[field] = step_result.public_send(field)
        end
      end
    end
  end
end
