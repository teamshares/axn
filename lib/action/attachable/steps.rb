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
          Array(steps).compact.each do |step|
            raise ArgumentError, "Step #{step} must include Action module" if step.is_a?(Class) && !step.included_modules.include?(Action) && !step < Action
          end

          # Convert action classes to Entry objects if they're not already
          converted_steps = Array(steps).compact.map do |step|
            if step.is_a?(Class)
              Entry.new(label: step.name || "Step", axn: step)
            else
              step
            end
          end

          # Set up error handling for steps without explicit labels
          converted_steps.each_with_index do |entry, idx|
            next unless entry.is_a?(Entry) && !entry.axn.name

            step_num = _axn_steps.length + idx + 1
            error from: entry.axn do |e|
              "Step #{step_num}: #{e.message}"
            end
          end

          self._axn_steps += converted_steps
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
          steps Entry.new(label: name, axn: axn_klass)
          error_prefix ||= "#{name}: "
          error from: axn_klass do |e|
            "#{error_prefix}#{e.message}"
          end
        end
      end

      # Execute steps automatically when the action is called
      def call
        _axn_steps.each_with_index do |step, idx|
          step = Entry.new(label: "Step #{idx + 1}", axn: step) unless step.is_a?(Entry)

          step_result = step.axn.call!(**merged_context_data)

          merge_step_exposures!(step_result)
        end
      end

      private

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
