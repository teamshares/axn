# frozen_string_literal: true

module Axn
  module Internal
    # Handles errors from "piping" code - hooks, callbacks, and other non-critical
    # code paths that shouldn't break the main action flow. Errors are logged
    # (or raised in development if configured) rather than propagating.
    module PipingError
      def self.swallow(desc, exception:, action: nil)
        # If raise_piping_errors_in_dev is enabled and we're in development, raise instead of log.
        # Test and production environments always swallow the error to match production behavior.
        raise exception if Axn.config.raise_piping_errors_in_dev && Axn.config.env.development?

        # Extract just filename/line number from backtrace
        src = exception.backtrace.first.split.first.split("/").last.split(":")[0, 2].join(":")

        message = if Axn.config.env.production?
                    "Ignoring exception raised while #{desc}: #{exception.class.name} - #{exception.message} (from #{src})"
                  else
                    msg = "!! IGNORING EXCEPTION RAISED WHILE #{desc.upcase} !!\n\n" \
                          "\t* Exception: #{exception.class.name}\n" \
                          "\t* Message: #{exception.message}\n" \
                          "\t* From: #{src}"
                    "#{'⌵' * 30}\n\n#{msg}\n\n#{'^' * 30}"
                  end

        (action || Axn.config.logger).send(:warn, message)

        nil
      end
    end
  end
end
