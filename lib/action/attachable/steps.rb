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
        def steps(*steps) = self._axn_steps += Array(steps).compact

        def step(name, axn_klass = nil, **kwargs, &block)
          axn_klass = axn_for_attachment(name:, axn_klass:, attachment_type: "Step", **kwargs, &block)

          # Add the step to the list of steps
          _axn_steps << Entry.new(label: name, axn: axn_klass)
        end
      end

      def call
        self.class._axn_steps.each_with_index do |step, idx|
          # Set a default label if we were just given an array of unlabeled steps
          # TODO: should Axn have a default label passed in already that we could pull out?
          step = Entry.new(label: "Step #{idx + 1}", axn: step) if step.is_a?(Class)

          hoist_errors(prefix: "#{step.label} step") do
            step.axn.call(@context)
          end
        end
      end
    end
  end
end
