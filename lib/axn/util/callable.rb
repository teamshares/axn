# frozen_string_literal: true

module Axn
  module Util
    module Callable
      extend self

      # Calls a callable with only the positional and keyword arguments it expects.
      # If the callable accepts **kwargs (keyrest), passes all provided kwargs.
      # If the callable accepts *args (rest), passes all provided positional args.
      #
      # @param callable [Proc, Method, #call] A callable object
      # @param args [Array] An array of positional arguments to potentially pass
      # @param kwargs [Hash] A hash of keyword arguments to potentially pass
      # @return The return value of calling the callable
      #
      # @example
      #   proc = ->(resource:, result:) { }
      #   Callable.call_with_desired_shape(proc, kwargs: { resource: "Action", result: result, extra: "ignored" })
      #   # Calls proc with only resource: and result:
      #
      # @example
      #   proc = ->(a, b, c:) { }
      #   Callable.call_with_desired_shape(proc, args: [1, 2, 3, 4], kwargs: { c: 5, d: 6 })
      #   # Calls proc with args [1, 2, 3] and kwargs { c: 5 }
      #
      # @example
      #   proc = ->(**kwargs) { }
      #   Callable.call_with_desired_shape(proc, kwargs: { resource: "Action", result: result })
      #   # Calls proc with all kwargs
      # Calls a callable with only the positional and keyword arguments it expects.
      def call_with_desired_shape(callable, args: [], kwargs: {})
        filtered_args, filtered_kwargs = only_requested_params(callable, args:, kwargs:)
        callable.call(*filtered_args, **filtered_kwargs)
      end

      # Returns filtered args and kwargs for a callable without calling it.
      # Useful when you need to execute the callable in a specific context (e.g., via instance_exec).
      #
      # @param callable [Proc, Method, #parameters] A callable object
      # @param args [Array] An array of positional arguments to potentially pass
      # @param kwargs [Hash] A hash of keyword arguments to potentially pass
      # @return [Array<Array, Hash>] A tuple of [filtered_args, filtered_kwargs]
      #
      # @example
      #   proc = ->(resource:, result:) { }
      #   args, kwargs = Callable.only_requested_params(proc, kwargs: { resource: "Action", result: result, extra: "ignored" })
      #   # => [[], { resource: "Action", result: result }]
      #   action.instance_exec(*args, **kwargs, &proc)
      def only_requested_params(callable, args: [], kwargs: {})
        return [args, kwargs] unless callable.respond_to?(:parameters)

        params = callable.parameters

        # Determine which positional arguments to pass
        filtered_args = filter_positional_args(params, args)

        # Determine which keyword arguments to pass
        filtered_kwargs = filter_kwargs(params, kwargs)

        [filtered_args, filtered_kwargs]
      end

      # Returns filtered args and kwargs for a callable when passing an exception.
      # The exception will be passed as either a positional argument or keyword argument,
      # depending on what the callable expects.
      #
      # @param callable [Proc, Method, #parameters] A callable object
      # @param exception [Exception, nil] The exception to potentially pass
      # @return [Array<Array, Hash>] A tuple of [filtered_args, filtered_kwargs]
      #
      # @example
      #   proc = ->(exception:) { }
      #   args, kwargs = Callable.only_requested_params_for_exception(proc, exception)
      #   # => [[], { exception: exception }]
      #   action.instance_exec(*args, **kwargs, &proc)
      #
      # @example
      #   proc = ->(exception) { }
      #   args, kwargs = Callable.only_requested_params_for_exception(proc, exception)
      #   # => [[exception], {}]
      #   action.instance_exec(*args, **kwargs, &proc)
      def only_requested_params_for_exception(callable, exception)
        return [[], {}] unless exception

        args = [exception]
        kwargs = { exception: }
        only_requested_params(callable, args:, kwargs:)
      end

      private

      def filter_positional_args(params, args)
        return args if args.empty?

        required_count = params.count { |type, _name| type == :req }
        optional_count = params.count { |type, _name| type == :opt }
        has_rest = params.any? { |type, _name| type == :rest }

        # If it accepts *args (rest), pass all provided args
        return args if has_rest

        # Otherwise, pass up to (required + optional) args
        max_args = required_count + optional_count
        args.first(max_args)
      end

      def filter_kwargs(params, kwargs)
        return kwargs if kwargs.empty?

        accepts_keyrest = params.any? { |type, _name| type == :keyrest }
        return kwargs if accepts_keyrest

        # Only pass explicitly expected keyword arguments
        expected_keywords = params.select { |type, _name| %i[key keyreq].include?(type) }.map { |_type, name| name }
        kwargs.select { |key, _value| expected_keywords.include?(key) }
      end
    end
  end
end
