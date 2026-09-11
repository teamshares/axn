# frozen_string_literal: true

require "axn/core/flow/handlers"
require "axn/core/flow/handlers/resolvers/callback_resolver"

module Axn
  module Core
    module Flow
      module Callbacks
        def self.included(base)
          base.class_eval do
            class_attribute :_callbacks_registry, instance_accessor: false, default: Axn::Core::Flow::Handlers::Registry.empty

            extend ClassMethods
          end
        end

        module ClassMethods
          # Internal dispatcher
          def _dispatch_callbacks(event_type, action:, exception: nil)
            resolver = Axn::Core::Flow::Handlers::Resolvers::CallbackResolver.new(
              _callbacks_registry,
              event_type,
              action:,
              exception:,
            )
            resolver.execute_callbacks
          end

          # ONLY raised exceptions (i.e. NOT fail!).
          def on_exception(*handlers, **, &block) = _add_callback(:exception, handlers, **, block:)

          # ONLY raised on fail! (i.e. NOT unhandled exceptions).
          def on_failure(*handlers, **, &block) = _add_callback(:failure, handlers, **, block:)

          # Handles both fail! and unhandled exceptions
          def on_error(*handlers, **, &block) = _add_callback(:error, handlers, **, block:)

          # Executes when the action completes successfully (after all after hooks complete successfully)
          # Runs in child-first order (child handlers before parent handlers)
          def on_success(*handlers, **, &block) = _add_callback(:success, handlers, **, block:)

          private

          # `handlers` given variadically (`on_success :notify, :log`) each register their OWN entry,
          # sharing whatever `if:`/`unless:`/etc. kwargs were passed -- the same shape `before`/`after`
          # already have. A lone prebuilt descriptor is still accepted bare (not wrapped in a list),
          # matching the one caller that passes one (`Factory`'s `on_*:` kwarg fan-out).
          def _add_callback(event_type, handlers, block: nil, **kwargs)
            raise ArgumentError, "on_#{event_type} cannot be called with both a block and a handler" if block && handlers.any?
            raise ArgumentError, "on_#{event_type} must be called with a block or symbol" if handlers.empty? && !block

            handlers = [block] if handlers.empty?
            handlers.each { |handler| _register_callback(event_type, handler, **kwargs) }
            true
          end

          def _register_callback(event_type, handler, **kwargs)
            # If handler is already a descriptor, use it directly
            entry = if handler.is_a?(Axn::Core::Flow::Handlers::Descriptors::CallbackDescriptor)
                      raise ArgumentError, "Cannot pass additional configuration with prebuilt descriptor" if kwargs.any?

                      handler
                    else
                      # Before this went variadic, a single `handler = nil` positional was
                      # indistinguishable from "not given" and rejected by `_add_callback`'s own
                      # presence check above. Now that several handlers can be listed, an explicit
                      # `on_success nil` (or `false`, or any other non-Symbol non-callable) is a
                      # NONEMPTY entry in that list -- it slips past the presence check and would
                      # silently register a descriptor that does nothing at dispatch (a literal,
                      # non-callable handler resolves to itself and runs no code). Reject it here,
                      # by the same grammar the message DSL holds its handler to.
                      unless handler.is_a?(Symbol) || Axn::Core::Flow::Handlers::Invoker.safely_callable?(handler)
                        raise ArgumentError,
                              "on_#{event_type} handler must be a Symbol, a callable, or a prebuilt descriptor " \
                              "(got a value of class #{Axn::Internal::Reflection::PropertyNames.renderable_class_name(handler)})"
                      end

                      Axn::Core::Flow::Handlers::Descriptors::CallbackDescriptor.build(handler:, **kwargs)
                    end

            self._callbacks_registry = _callbacks_registry.register(event_type:, entry:)
          end
        end
      end
    end
  end
end
