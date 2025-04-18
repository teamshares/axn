# frozen_string_literal: true

module Action
  module Attachable
    module Subactions
      extend ActiveSupport::Concern

      class_methods do
        def _attachable_name(name:) = "_subaction_#{name}"

        def action(name, axn_klass = nil, **action_kwargs, &block)
          axn_klass = axn_for_attachment(name:, axn_klass:, **action_kwargs, &block)
          internal_name = _attachable_name(name:)
          raise ArgumentError, "#{attachment_type} cannot be added -- '#{name}' is already taken" if respond_to?(internal_name)

          define_singleton_method(internal_name) { axn_klass }

          define_singleton_method(name) do |**kwargs|
            send(internal_name).call(**kwargs)
          end

          # TODO: do we also need an instance-level version that auto-wraps in hoist_errors(label: name)?

          define_singleton_method("#{name}!") do |**kwargs|
            send(internal_name).call!(**kwargs)
          end
        end
      end
    end
  end
end
