# frozen_string_literal: true

module Axn
  module Tools
    # The sanctioned entry point for running an Axn AS A TOOL. Holds an adapter's chosen profile and
    # runs `.call` under the matching per-call gates (Axn::Internal::CurrentCallOptions), returning a
    # plain Axn::Result so an adapter's existing result-mapping is unchanged. Coercion is always on
    # for tools (the trusted-JSON boundary wants it, and a field's own `coerce:` still wins); the
    # user-facing surfacing and undeclared-input rejection are per-adapter opt-ins. Detection of an
    # input-contract failure rides on the returned result's exception (`input_invalid?`), not on any
    # new Axn::Result method.
    class Invoker
      NOT_SET = Object.new.freeze

      # axn framework-reserved input keys that untrusted (model-supplied) args may not set. Currently
      # only :ambient_context — direct passing is a valid override for a normal `.call`, but a tool's
      # args come from the model, so the invoker forces the ambient-resolution pipeline and lets the
      # adapter inject its own trusted context. NOT :server_context — that is an mcp transport concept
      # the mcp adapter extracts itself and passes in as the trusted ambient_context.
      RESERVED_INPUT_KEYS = %i[ambient_context].freeze

      def initialize(user_facing_input_errors: false, reject_undeclared_inputs: false)
        @user_facing_input_errors = user_facing_input_errors
        @reject_undeclared_inputs = reject_undeclared_inputs
      end

      # args: the untrusted, model-supplied argument hash.
      # ambient_context: the adapter's OWN trusted ambient context (optional), merged after the guard.
      def call(axn_class, args = {}, ambient_context: NOT_SET)
        clean = args.reject { |key, _| RESERVED_INPUT_KEYS.include?(key.to_sym) }
        clean = clean.merge(ambient_context:) unless ambient_context.equal?(NOT_SET)

        Axn::Internal::CurrentCallOptions.with(
          coerce_input_types: true,
          user_facing_input_errors: @user_facing_input_errors,
          reject_undeclared_inputs: @reject_undeclared_inputs,
        ) do
          axn_class.call(**clean)
        end
      end

      # Whether a returned result failed on an inbound contract violation that was surfaced as a
      # correctable CALLER (model) error — i.e. an inbound violation settled user-facing under
      # `user_facing_input_errors`. A dev-facing inbound failure (a normal reported bug, or an
      # ambient-context violation, which stays dev-facing because ambient context is trusted/
      # adapter-supplied) already paged `on_exception` and is NOT flagged here, so the adapter returns
      # its generic error rather than telling the model "Invalid tool arguments" for an infra bug.
      # False for a `fail!`, an outbound violation, or any other raised exception.
      def self.input_invalid?(result) = Axn::ValidationError.user_facing?(result.exception)
    end
  end
end
