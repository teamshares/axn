# frozen_string_literal: true

module Action
  module Core
    module Tracing
      private

      def _with_tracing(&)
        return yield unless Axn.config.wrap_with_trace

        Axn.config.wrap_with_trace.call(self.class.name || "AnonymousClass", &)
      rescue StandardError => e
        Axn::Internal::Logging.piping_error("running trace hook", action: self, exception: e)
      end
    end
  end
end
