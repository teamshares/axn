# frozen_string_literal: true

require "axn/internal/global_id_serialization"

module Axn
  module Async
    # Raised at enqueue when an async argument cannot be serialized for background
    # execution. Field-aware: names the offending field, its class, and how to fix it.
    # Lives here (not exceptions.rb) alongside the other Axn::Async errors
    # (AdapterNotFound, MissingEnqueuesEachError).
    class UnserializableArgument < ArgumentError
      def initialize(field:, value:)
        @field = field
        @value = value
        super()
      end

      def message
        "Cannot serialize argument `#{@field}` (#{@value.class}) for async execution. " \
          "#{Axn::Internal::AsyncSerialization._unserializable_hint(@value)}"
      end
    end
  end

  module Internal
    # Dispatcher for async argument serialization. See lib/axn/internal/async_serialization.rb
    # header comment / docs/superpowers/plans for the design.
    module AsyncSerialization
      GENERIC_HINT =
        "Async args must be JSON-native values (String, Integer, Float, true/false, nil, " \
        "Array/Hash of those) or GlobalID-able objects (e.g. ActiveRecord records, " \
        "ActiveStorage attachments)."

      class << self
        # Returns a fix hint tailored to common footguns (files/IO, ActiveStorage proxies).
        def _unserializable_hint(value)
          if _io_like?(value)
            "Persist it to ActiveStorage and pass the attachment, or otherwise convert it " \
              "to a serializable value. #{GENERIC_HINT}"
          elsif _active_storage_proxy?(value)
            "Pass its `.blob` (or `.attachment`) instead of the attachment proxy. #{GENERIC_HINT}"
          else
            GENERIC_HINT
          end
        end

        def _io_like?(value) = value.respond_to?(:read)

        def _active_storage_proxy?(value)
          return false unless defined?(::ActiveStorage::Attached)

          value.is_a?(::ActiveStorage::Attached::One) || value.is_a?(::ActiveStorage::Attached::Many)
        end
      end
    end
  end
end
