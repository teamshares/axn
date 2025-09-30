# frozen_string_literal: true

module Axn
  class Factory
    class << self
      # rubocop:disable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/CyclomaticComplexity, Metrics/ParameterLists
      def wrap(
        axn_klass = nil,
        superclass: nil,
        **,
        &
      )
        axn_klass || build(superclass:, **, &)
      end

      def build(
        callable = nil,
        # Builder-specific options
        superclass: nil,
        expose_return_as: nil,

        # Expose standard class-level options
        exposes: [],
        expects: [],
        success: nil,
        error: nil,

        # Hooks
        before: nil,
        after: nil,
        around: nil,

        # Callbacks
        on_success: nil,
        on_failure: nil,
        on_error: nil,
        on_exception: nil,

        # Strategies
        use: [],

        # Async configuration
        async: nil,

        &block
      )
        raise ArgumentError, "[Axn::Factory] Cannot receive both a callable and a block" if callable.present? && block_given?

        executable = callable || block
        raise ArgumentError, "[Axn::Factory] Must provide either a callable or a block" unless executable

        args = executable.parameters.each_with_object(_hash_with_default_array) { |(type, field), hash| hash[type] << field }

        if args[:opt].present? || args[:req].present? || args[:rest].present?
          raise ArgumentError,
                "[Axn::Factory] Cannot convert callable to action: callable expects positional arguments"
        end
        raise ArgumentError, "[Axn::Factory] Cannot convert callable to action: callable expects a splat of keyword arguments" if args[:keyrest].present?

        if args[:key].present?
          raise ArgumentError,
                "[Axn::Factory] Cannot convert callable to action: callable expects keyword arguments with defaults (ruby does not allow introspecting)"
        end

        expects = _hydrate_hash(expects)
        exposes = _hydrate_hash(exposes)

        Array(args[:keyreq]).each do |field|
          expects[field] ||= {}
        end

        # NOTE: inheriting from wrapping class, so we can set default values (e.g. for HTTP headers)
        _build_axn_class(superclass:, args:, executable:, expose_return_as:).tap do |axn|
          expects.each do |field, opts|
            axn.expects(field, **opts)
          end

          exposes.each do |field, opts|
            axn.exposes(field, **opts)
          end

          # Apply success and error handlers
          _apply_handlers(axn, :success, success, Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor)
          _apply_handlers(axn, :error, error, Axn::Core::Flow::Handlers::Descriptors::MessageDescriptor)

          # Hooks
          axn.before(before) if before.present?
          axn.after(after) if after.present?
          axn.around(around) if around.present?

          # Callbacks
          _apply_handlers(axn, :on_success, on_success, Axn::Core::Flow::Handlers::Descriptors::CallbackDescriptor)
          _apply_handlers(axn, :on_failure, on_failure, Axn::Core::Flow::Handlers::Descriptors::CallbackDescriptor)
          _apply_handlers(axn, :on_error, on_error, Axn::Core::Flow::Handlers::Descriptors::CallbackDescriptor)
          _apply_handlers(axn, :on_exception, on_exception, Axn::Core::Flow::Handlers::Descriptors::CallbackDescriptor)

          # Strategies
          Array(use).each do |strategy|
            if strategy.is_a?(Array)
              strategy_name, *config_args = strategy
              if config_args.last.is_a?(Hash)
                *other_args, config = config_args
                axn.use(strategy_name, *other_args, **config)
              else
                axn.use(strategy_name, *config_args)
              end
            else
              axn.use(strategy)
            end
          end

          # Async configuration
          unless async.nil?
            async_array = Array(async)
            # Skip async configuration if adapter is nil (but not if array is empty)
            if !async_array.empty? && async_array[0].nil?
              # Do nothing - skip async configuration
            else
              _apply_async_config(axn, async_array)
            end
          end

          # Default exposure
          axn.exposes(expose_return_as, optional: true) if expose_return_as.present?
        end
      end
      # rubocop:enable Metrics/AbcSize, Metrics/PerceivedComplexity, Metrics/CyclomaticComplexity, Metrics/ParameterLists

      private

      def _hash_with_default_array = Hash.new { |h, k| h[k] = [] }

      def _hydrate_hash(given)
        return given if given.is_a?(Hash)

        Array(given).each_with_object({}) do |key, acc|
          if key.is_a?(Hash)
            key.each_key do |k|
              acc[k] = key[k]
            end
          else
            acc[key] = {}
          end
        end
      end

      def _apply_handlers(axn, method_name, value, _descriptor_class)
        return unless value.present?

        # Check if the value itself is a hash (this catches the case where someone passes a hash literal)
        raise Axn::UnsupportedArgument, "Cannot pass hash directly to #{method_name} - use descriptor objects for kwargs" if value.is_a?(Hash)

        # Wrap in Array() to handle both single values and arrays
        Array(value).each do |handler|
          raise Axn::UnsupportedArgument, "Cannot pass hash directly to #{method_name} - use descriptor objects for kwargs" if handler.is_a?(Hash)

          # Both descriptor objects and simple cases (string/proc) can be used directly
          axn.public_send(method_name, handler)
        end
      end

      def _build_axn_class(superclass:, args:, executable:, expose_return_as:)
        Class.new(superclass || Object) do
          include Axn unless self < Axn

          # Set a default name for anonymous classes to help with debugging
          define_singleton_method(:name) do
            "AnonymousAxn_#{object_id}"
          end

          define_method(:call) do
            unwrapped_kwargs = Array(args[:keyreq]).each_with_object({}) do |field, hash|
              hash[field] = public_send(field)
            end

            retval = instance_exec(**unwrapped_kwargs, &executable)
            expose(expose_return_as => retval) if expose_return_as.present?
          end
        end
      end

      def _apply_async_config(axn, async)
        raise ArgumentError, "[Axn::Factory] Invalid async configuration" unless _validate_async_config(async)

        adapter, *config_args = async

        # Determine hash config and callable config
        config = config_args.find { |arg| arg.is_a?(Hash) }
        block = config_args.find { |arg| arg.respond_to?(:call) }

        # Call async once with the determined values
        axn.async(adapter, **(config || {}), &block)
      end

      def _validate_async_config(async_array)
        return false unless async_array.length.between?(1, 3)

        adapter = async_array[0]
        second_arg = async_array[1]
        third_arg = async_array[2]

        # First arg must be adapter (symbol/string), false, or nil
        return false unless adapter.is_a?(Symbol) || adapter.is_a?(String) || adapter == false || adapter.nil?

        case async_array.length
        when 1
          # Pattern A: [:sidekiq], [false], or [nil]
          true
        when 2
          # Pattern B: [:sidekiq, hash_or_callable] or [nil, hash_or_callable]
          second_arg.is_a?(Hash) || second_arg.respond_to?(:call)
        when 3
          # Pattern C: [:sidekiq, hash, callable] or [nil, hash, callable]
          second_arg.is_a?(Hash) && third_arg.respond_to?(:call)
        else
          false
        end
      end
    end
  end
end
