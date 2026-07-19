# frozen_string_literal: true

module Axn
  # The extension-author surface: "for gems building on axn," distinct from
  # Axn::Internal (private) and the user-facing DSL. Not Ruby core-ext/refinements —
  # this is the API sibling gems (Axn::Webhooks, Axn::MCP, ...) may rely on.
  module Extensions
    class << self
      def config
        @config ||= Config.new
      end

      # Runs the block, guarding a best-effort side effect (a hook, callback, observability
      # facet, or a reporter that itself throws). On StandardError the error is logged and
      # swallowed (returning nil) so it never breaks the main action flow — EXCEPT in
      # development when Axn.config.best_effort_raises_in_dev is set, where it re-raises.
      # `desc` names the intent ("resolving webhook subscribers"); `action` is an optional
      # warn-target (an action instance/class responding to :warn), defaulting to the config logger.
      def best_effort(desc, action: nil)
        yield
      rescue StandardError => e
        raise e if Axn.config.best_effort_raises_in_dev && Axn.config.env.development?

        # Extract just filename/line number from backtrace
        src = e.backtrace.first.split.first.split("/").last.split(":")[0, 2].join(":")

        message = if Axn.config.env.production?
                    "Ignoring exception raised while #{desc}: #{e.class.name} - #{e.message} (from #{src})"
                  else
                    msg = "!! IGNORING EXCEPTION RAISED WHILE #{desc.upcase} !!\n\n" \
                          "\t* Exception: #{e.class.name}\n" \
                          "\t* Message: #{e.message}\n" \
                          "\t* From: #{src}"
                    "#{'⌵' * 30}\n\n#{msg}\n\n#{'^' * 30}"
                  end

        (action || Axn.config.logger).send(:warn, message)

        nil
      end
    end
  end
end
