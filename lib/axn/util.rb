# frozen_string_literal: true

module Axn
  module Util
    def self.piping_error(desc, exception:, action: nil)
      message = "Ignoring #{exception.class.name} while #{desc}: #{exception.message}"

      unless Action.config.env.production?
        message.upcase!
        message += "\n\tFrom: #{exception.backtrace.first}"
        message = ("#" * 30) + "\n\n#{message}\n\n" + ("#" * 30)
      end

      (action || Action.config.logger).warn(message)

      nil
    end
  end
end
