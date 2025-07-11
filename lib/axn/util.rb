# frozen_string_literal: true

module Axn
  module Util
    def self.piping_error(desc, exception:, action: nil)
      # Extract just filename/line number from backtrace
      src = exception.backtrace.first.split.first.split("/").last.split(":")[0, 2].join(":")

      message = if Action.config.env.production?
                  "Ignoring exception raised while #{desc}: #{exception.class.name} - #{exception.message} (from #{src})"
                else
                  msg = "!! IGNORING EXCEPTION RAISED WHILE #{desc.upcase} !!\n\n" \
                        "\t* Exception: #{exception.class.name}\n" \
                        "\t* Message: #{exception.message}\n" \
                        "\t* From: #{src}"
                  banner = "#{"*" * 30}\n\n#{msg}\n\n#{"*" * 30}"
                  banner
                end

      (action || Action.config.logger).send(:warn, message)

      nil
    end
  end
end
