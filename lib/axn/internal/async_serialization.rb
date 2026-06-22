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

          # Choose the decoder from the payload's own format markers, not the current
          # process's loaded constants — a job may be enqueued and performed in processes
          # that differ in whether ActiveJob is loaded. A fallback payload tags GlobalID
          # args with the `_as_global_id` key suffix; an ActiveJob payload wraps values in
          # `_aj_*` hashes. A payload with neither marker is pure JSON-native, where both
          # decoders agree — so defer to the process check for symmetry (and so a no-ActiveJob
          # process doesn't reach for a decoder it can't load).
          return Axn::Internal::GlobalIdSerialization.deserialize(params) if _fallback_encoded?(params)
          return _deserialize_via_active_job(params) if _active_job_encoded?(params) || _active_job_available?

          Axn::Internal::GlobalIdSerialization.deserialize(params)
        end

        # Validate that every arg will serialize for async, raising a field-aware
        # UnserializableArgument otherwise — without keeping the result. Lets an adapter
        # that serializes natively (the ActiveJob adapter, via perform_later) surface the
        # same enqueue-time contract as the Sidekiq path instead of leaking
        # ActiveJob::SerializationError. The throwaway serialize is a cold-path cost; the
        # adapter still serializes the real payload exactly once (no double-encoding).
        def assert_serializable!(params)
          serialize(params)
          nil
        end

        # A value that rides nested inside another payload which an adapter will itself
        # serialize needs path-specific handling. On the ActiveJob path the adapter's
        # serializer recurses into nested hashes AND is not idempotent over its own tags,
        # so pre-serializing here would double-encode and raise — pass it through untouched.
        # On the fallback path the serializer is top-level-only and can't reach nested
        # objects, so flatten them now; the resulting all-string hash is left untouched by
        # the adapter's top-level pass.
        def prepare_nested_payload(value)
          _active_job_available? ? value : serialize(value)
        end

        # Inverse of prepare_nested_payload: on the ActiveJob path the adapter already
        # restored the nested value recursively; only the fallback path needs a manual pass.
        def restore_nested_payload(value)
          _active_job_available? ? value : deserialize(value)
        end

        def _active_job_available? = !!defined?(::ActiveJob::Arguments)

        # Fallback-format marker: GlobalIdSerialization tags converted args with the
        # `_as_global_id` key suffix (top-level, matching how that serializer works).
        def _fallback_encoded?(params)
          params.any? { |key, _v| key.to_s.end_with?(Axn::Internal::GlobalIdSerialization::GLOBAL_ID_SUFFIX) }
        end

        # ActiveJob-format marker: ActiveJob::Arguments wraps non-native values in hashes
        # keyed by reserved `_aj_*` keys (e.g. `_aj_globalid`, `_aj_serialized`). These keys
        # are reserved by ActiveJob — a user hash can't legitimately carry them (AJ raises),
        # so their presence anywhere in the payload reliably identifies the ActiveJob format.
        def _active_job_encoded?(params)
          params.any? { |_k, v| _aj_tagged?(v) }
        end

        def _aj_tagged?(value)
          case value
          when Hash then value.keys.any? { |k| k.to_s.start_with?("_aj_") } || value.values.any? { |v| _aj_tagged?(v) }
          when Array then value.any? { |v| _aj_tagged?(v) }
          else false
          end
        end

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
          # Hash keys must be Strings specifically: the JSON round-trip stringifies every key,
          # so a non-String key (Integer/Symbol/etc.) would silently come back as a String —
          # the very corruption this guard exists to prevent. Values still need only be JSON-native.
          when Hash then value.all? { |k, v| k.is_a?(String) && _json_native?(v) }
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
