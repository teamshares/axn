# frozen_string_literal: true

module Action
  module Attachable
    module Subactions
      extend ActiveSupport::Concern

      class_methods do
        def action(name, axn_klass = nil, **action_kwargs, &block)
          axn_klass ||= axn_for_attachment(name:, axn_klass:, **action_kwargs, &block)

          define_singleton_method(_new_action_name(name)) { axn_klass }

          define_singleton_method(name) do |**kwargs|
            send(_new_action_name(name)).call(**kwargs)
          end

          define_singleton_method("#{name}!") do |**kwargs|
            send(_new_action_name(name)).call!(**kwargs)
          end
        end
      end
    end
  end
end
