# frozen_string_literal: true

module Axn
  module Internal
    module Logging
      def self.piping_error(desc, exception:, action: nil)
        # If raise_piping_errors_outside_production is enabled and we're in development or test, raise instead of log
        raise exception if Axn.config.raise_piping_errors_outside_production && (Axn.config.env.development? || Axn.config.env.test?)

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
