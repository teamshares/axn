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
        def serialize(params)
          return {} if params.nil? || params.empty?
          return _serialize_via_active_job(params) if _active_job_available?

          params.each { |key, value| _assert_fallback_serializable!(key, value) }
          Axn::Internal::GlobalIdSerialization.serialize(params)
        end

        def deserialize(params)
          return {} if params.nil? || params.empty?
          return _deserialize_via_active_job(params) if _active_job_available?

          Axn::Internal::GlobalIdSerialization.deserialize(params)
        end

        def _active_job_available? = defined?(::ActiveJob::Arguments) ? true : false

        # Fallback (no ActiveJob) can only round-trip JSON-native scalars, top-level
        # GlobalID-able objects, and Arrays/Hashes of JSON-native scalars. Everything
        # else (Symbol, Date, Time, BigDecimal, files, custom objects, nested GIDs)
        # would corrupt or fail on the JSON round-trip, so it raises instead.
        def _assert_fallback_serializable!(field, value)
          raise Axn::Async::UnserializableArgument.new(field:, value:) unless _fallback_serializable?(value)
        end

        # Serializable iff it's JSON-native through-and-through, OR a top-level GlobalID-able
        # object (the only non-native value GlobalIdSerialization can convert in the fallback).
        # Nested GlobalID-ables are NOT supported in the fallback (GlobalIdSerialization only
        # converts top-level values), so an Array/Hash containing one fails _json_native? and raises.
        def _fallback_serializable?(value)
          _json_native?(value) || value.respond_to?(:to_global_id)
        end

        def _json_native?(value)
          case value
          when nil, true, false, Integer, Float, String then true
          when Array then value.all? { |v| _json_native?(v) }
          when Hash then value.all? { |k, v| _json_native?(k) && _json_native?(v) }
          else false
          end
        end

        # Serialize value-by-value (keyed by field) so a SerializationError can be
        # re-raised naming the offending field. Keys are stringified for the backend.
        def _serialize_via_active_job(params)
          params.each_with_object({}) do |(key, value), hash|
            hash[key.to_s] = ::ActiveJob::Arguments.serialize([value]).first
          rescue ::ActiveJob::SerializationError
            raise Axn::Async::UnserializableArgument.new(field: key, value:)
          end
        end

        def _deserialize_via_active_job(params)
          params.each_with_object({}) do |(key, value), hash|
            hash[key.to_sym] = ::ActiveJob::Arguments.deserialize([value]).first
          end
        end

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
