# frozen_string_literal: true

require "axn/internal/identity"

module Axn
  # The extension-author surface: "for gems building on axn," distinct from
  # Axn::Internal (private) and the user-facing DSL. Not Ruby core-ext/refinements —
  # this is the API sibling gems (Axn::Webhooks, Axn::MCP, ...) may rely on.
  module Extensions
    # The ONLY non-StandardError classes axn will ever swallow — both in a side-channel guard
    # (best_effort) and when settling an exception onto a result (Core::Executor). One list, because
    # both answer the same question: may axn absorb this instead of letting it through?
    #
    # An ALLOWLIST, deliberately, and never a denylist of "everything that isn't a signal". The set of
    # non-StandardError exceptions in a live process is OPEN — Ruby defines a stable handful, but gems
    # and stdlib add their own direct Exception subclasses (Timeout::ExitException,
    # ActiveSupport::ErrorReporter::UnexpectedError, CGI::InvalidEncoding), and a library is free to
    # invent one tomorrow. Several exist PRECISELY so that nothing swallows them: absorbing
    # Timeout::ExitException makes an enclosing Timeout.timeout silently not fire, and
    # ErrorReporter::UnexpectedError is raised outside StandardError for exactly that reason.
    #
    # The two ways of being wrong are not symmetric. Swallow something we shouldn't and we silently
    # break another library's control flow — the hardest class of bug to trace. Fail to swallow
    # something we could have, and an unrecognized non-StandardError escapes `.call` unreported, which
    # is merely the status quo for anything not yet listed, and is fixed by adding a line here.
    #
    # Both members are unambiguously faults in the code being run, never a signal to anyone:
    #   * SystemStackError — runaway recursion.
    #   * ScriptError — and so NotImplementedError (an unfinished method), LoadError, SyntaxError.
    #
    # Ruby's `fatal` needs no entry: it is unrescuable, so `rescue Exception` never sees it.
    SWALLOWABLE_BEYOND_STANDARD_ERROR = [SystemStackError, ScriptError].freeze

    class << self
      # True when `exception` is one axn may absorb: any StandardError, plus the allowlist above.
      # Anything else — a signal, an `exit`, another library's private control-flow signal — must pass
      # through untouched.
      # Whether a guarded failure is re-raised rather than logged — the dev-loud mode. Exposed so
      # anything that has to reason about what best_effort will DO consults the same condition rather
      # than restating it.
      def raises_in_dev? = Axn.config.best_effort_raises_in_dev && Axn.config.env.development?

      # Undispatched ancestry, not `exception.is_a?`. Not as a defense against exceptions that lie
      # about themselves — that is unwinnable — but because the object's opinion is not the question.
      # This predicate decides whether axn may SWALLOW something, and the only thing that authorizes
      # that is the allowlist actually being in the class's ancestry. Asking the instance made the
      # answer depend on a method the instance defines; `Module#===` makes it depend on the hierarchy,
      # which is deterministic for every input. Same seam the span type check and the `validate:`
      # String check already use.
      def swallowable?(exception)
        return true if Internal::Identity.kind?(exception, StandardError)

        SWALLOWABLE_BEYOND_STANDARD_ERROR.any? { |klass| Internal::Identity.kind?(exception, klass) }
      end

      # True when axn owns this exception's #message — an Axn::Failure, or a user-facing validation error —
      # so the message is meant for the client and may carry a resolved presentation. A FOREIGN exception
      # reclassified via `fails_on` is not owned: it travels axn's failure path, but its #message is a
      # technical cause, and an adapter surfacing it would leak internals to a caller.
      def owned_failure?(exception)
        exception.is_a?(Axn::Failure) || Axn::ValidationError.user_facing?(exception)
      end

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
      # Swallows StandardError plus SWALLOWABLE_BEYOND_STANDARD_ERROR — the right default almost
      # everywhere, and required for a true side channel whose outcome nothing reads (emitting a log
      # line, updating a span, reporting to an error tracker).
      #
      # `standard_errors_only: true` narrows it to StandardError, letting the allowlisted classes
      # through. Justified only when escaping beats swallowing, which needs BOTH: nothing already
      # committed at that point, AND an executor boundary that will settle the escape into a reported
      # result instead of re-raising. Resolving a `model:` record qualifies — it runs inside its own
      # action's validation, so a runaway finder surfaces as a reported exception result naming the
      # real stack rather than a misleading "can't be blank". A post-fan-out callback does NOT: jobs
      # are already enqueued and the orchestrator is an async job whose adapter re-raises an exception
      # outcome, so an escape gets the batch enqueued twice. When in doubt, use the default.
      #
      # The flag is pinned to the StandardError class boundary, so its meaning cannot drift as the
      # allowlist above grows.
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
        raise exception if raises_in_dev?

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

        _emit_warning(action, message)

        nil
      end

      # Emitting the warning must not raise either. This guard is frequently invoked from an `ensure`,
      # so a logging backend that cannot write (a closed or failing IO, a broken custom logger) would
      # otherwise replace the exception already in flight — the exact failure the guard exists to
      # prevent, just moved one line later.
      #
      # When the primary target was an action, the configured logger gets one independent attempt: it is
      # a different object, and the usual cause is an action-level override rather than the backend. If
      # both fail there is nothing left to warn WITH, so the warning is dropped — a lost diagnostic is
      # strictly better than a lost exception.
      def _emit_warning(action, message)
        (action || Axn.config.logger).send(:warn, message)
      rescue StandardError, *SWALLOWABLE_BEYOND_STANDARD_ERROR
        return if action.nil?

        begin
          Axn.config.logger.send(:warn, message)
        rescue StandardError, *SWALLOWABLE_BEYOND_STANDARD_ERROR
          nil
        end
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
