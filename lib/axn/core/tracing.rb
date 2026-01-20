# frozen_string_literal: true

require "securerandom"

module Axn
  module Core
    module Tracing
      class << self
        # Cache the tracer instance to avoid repeated lookups
        # The tracer provider may cache internally, but we avoid the method call overhead
        # We check defined?(OpenTelemetry) each time to handle cases where it's loaded lazily
        def tracer
          return nil unless defined?(OpenTelemetry)

          # Re-fetch if the tracer provider has changed (e.g., in tests with mocks)
          current_provider = OpenTelemetry.tracer_provider
          return @tracer if defined?(@tracer) && defined?(@tracer_provider) && @tracer_provider == current_provider

          @tracer_provider = current_provider
          @tracer = current_provider.tracer("axn", Axn::VERSION)
        end
      end

      private

      def _with_tracing(&)
        resource = self.class.name || "AnonymousClass"
        payload = { resource:, action: self }

        update_payload = proc do
          result = self.result
          outcome = result.outcome.to_s
          payload[:outcome] = outcome
          payload[:result] = result
          payload[:elapsed_time] = result.elapsed_time
          payload[:exception] = result.exception if result.exception
        rescue StandardError => e
          # Don't raise in ensure block to avoid interfering with existing exceptions
          Axn::Internal::Logging.piping_error("updating notification payload while tracing axn.call", action: self, exception: e)
        end

        instrument_block = proc do
          ActiveSupport::Notifications.instrument("axn.call", payload, &)
        ensure
          # Update payload BEFORE instrument completes so subscribers see the changes
          update_payload.call
        end

        # NOTE: despite using block form, ActiveSupport explicitly only emits to subscribers when it's finished,
        # which means it's not suitable for wrapping execution with a span and tracking child spans.
        # We use OpenTelemetry for that, if available.
        if defined?(OpenTelemetry)
          # #region agent log
          tracer_instance = Tracing.tracer
          provider_class = OpenTelemetry.tracer_provider.class.name
          tracer_class = tracer_instance.class.name
          Rails.logger.info "[AXN_DEBUG] _with_tracing: resource=#{resource}, provider=#{provider_class}, tracer=#{tracer_class}" if defined?(Rails)
          # #endregion
          tracer_instance.in_span("axn.call", attributes: { "axn.resource" => resource }) do |span|
            # #region agent log
            Rails.logger.info "[AXN_DEBUG] _with_tracing: inside span, span_class=#{span.class.name}, recording=#{span.respond_to?(:recording?) ? span.recording? : 'n/a'}" if defined?(Rails)
            # #endregion
            instrument_block.call
          ensure
            # Update span with outcome and error status after execution
            # This ensure runs before the span finishes, so we can still update it
            begin
              result = self.result
              outcome = result.outcome.to_s
              span.set_attribute("axn.outcome", outcome)

              if %w[failure exception].include?(outcome) && result.exception
                span.record_exception(result.exception)
                error_message = result.exception.message || result.exception.class.name
                span.status = OpenTelemetry::Trace::Status.error(error_message)
              end
            rescue StandardError => e
              # Don't raise in ensure block to avoid interfering with existing exceptions
              Axn::Internal::Logging.piping_error("updating OTel span while tracing axn.call", action: self, exception: e)
            end
          end
        else
          instrument_block.call
        end
      ensure
        begin
          emit_metrics_proc = Axn.config.emit_metrics
          if emit_metrics_proc
            result = self.result
            Axn::Util::Callable.call_with_desired_shape(emit_metrics_proc, kwargs: { resource:, result: })
          end
        rescue StandardError => e
          # Don't raise in ensure block to avoid interfering with existing exceptions
          Axn::Internal::Logging.piping_error("calling emit_metrics while tracing axn.call", action: self, exception: e)
        end
      end
    end
  end
end
