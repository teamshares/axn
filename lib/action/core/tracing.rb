# frozen_string_literal: true

module Action
  module Core
    module Tracing
      private

      def with_tracing(&)
        return yield unless Action.config.wrap_with_trace

        Action.config.wrap_with_trace.call(self.class.name || "AnonymousClass", &)
      rescue StandardError => e
        Axn::Util.piping_error("running trace hook", action: self, exception: e)
      end
    end
  end
end
