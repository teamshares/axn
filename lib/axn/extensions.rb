# frozen_string_literal: true

module Axn
  # The extension-author surface: "for gems building on axn," distinct from
  # Axn::Internal (private) and the user-facing DSL. Not Ruby core-ext/refinements —
  # this is the API sibling gems (Axn::Webhooks, Axn::MCP, ...) may rely on.
  module Extensions
    # The non-StandardError classes a side-channel guard may swallow. Deliberately a tiny
    # allowlist rather than "everything that isn't a signal": the set of non-StandardError
    # exceptions present in a real process is OPEN — gems and stdlib define their own direct
    # Exception subclasses (Timeout::ExitException, ActiveSupport::ErrorReporter::UnexpectedError,
    # CGI::InvalidEncoding) — and several exist precisely so nothing can swallow them. Eating
    # Timeout::ExitException would make an enclosing Timeout.timeout silently not fire; eating
    # Interrupt/SystemExit/fatal would strand a process mid-shutdown.
    #
    # SystemStackError qualifies because a runaway recursion in a side channel (a self-referential
    # value reaching a log formatter, a reporter, or a metrics block) says nothing about whether
    # the action's own work succeeded, and being outside StandardError nothing else catches it.
    SWALLOWABLE_BEYOND_STANDARD_ERROR = [SystemStackError].freeze

    class << self
      def config
        @config ||= Config.new
      end

      # Runs the block, guarding a best-effort side effect (a hook, callback, observability
      # facet, or a reporter that itself throws). The exception is logged and swallowed (returning
      # nil) so it never breaks the main action flow — EXCEPT in development when
      # Axn.config.best_effort_raises_in_dev is set, where it re-raises.
      # `desc` names the intent ("resolving webhook subscribers"); `action` is an optional
      # warn-target (an action instance/class responding to :warn), defaulting to the config logger.
      #
      # Swallows StandardError plus SWALLOWABLE_BEYOND_STANDARD_ERROR. That default is for a true
      # side channel whose outcome nothing reads (emitting a log line, updating a span, reporting to
      # an error tracker). Pass `standard_errors_only: true` when the block's return value or side
      # effect feeds the call's real behavior (resolving a `model:` record, deciding whether a
      # handler applies, filtering which records enqueue): there, swallowing a SystemStackError
      # would surface a runaway user finder as a misleading "can't be blank" instead of the stack
      # that names it. That flag is pinned to the StandardError class boundary, so its meaning
      # cannot drift as the allowlist above grows.
      def best_effort(desc, action: nil, standard_errors_only: false)
        if standard_errors_only
          begin
            yield
          rescue StandardError => e
            _warn_and_swallow(e, desc, action)
          end
        else
          begin
            yield
          rescue StandardError, *SWALLOWABLE_BEYOND_STANDARD_ERROR => e
            _warn_and_swallow(e, desc, action)
          end
        end
      end

      private

      # Warn about a swallowed exception and return nil (best_effort's documented failure return).
      # Re-raises first in development when configured, keeping the guard dev-loud.
      def _warn_and_swallow(exception, desc, action)
        raise exception if Axn.config.best_effort_raises_in_dev && Axn.config.env.development?

        src = _source_location(exception)

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

      # Just the filename/line number the exception came from. An EMPTY backtrace has to be tolerated:
      # `raise` repopulates a nil one, but an exception reconstructed with `set_backtrace([])` (what a
      # death handler rebuilding one from job data hands us) keeps it, and this guard's whole job is to
      # not raise — it frequently runs from inside an `ensure`, where a raise would replace the
      # exception already in flight.
      def _source_location(exception)
        frame = exception.backtrace&.first
        return "unknown location" unless frame

        frame.split.first.split("/").last.split(":")[0, 2].join(":")
      end
    end
  end
end
