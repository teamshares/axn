# frozen_string_literal: true

require "axn/internal/identity"
require "axn/internal/rendering"
require "axn/internal/text"

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
      #
      # A seam that cannot answer means NOT dev-loud. Both reads are into caller-owned config — the setting
      # and the `env` object a host application supplies — and a half-booted or misconfigured one raises
      # here, which would make FAILING TO DECIDE the answer: `best_effort` is called from `ensure` blocks
      # throughout the executor, so a raise from the decision replaces the exception already in flight with
      # one manufactured while working out how to report it. The two directions are not symmetric. Answering
      # false where true was configured loses a deliberately loud raise in development, which is a
      # development-time annoyance; answering by raising turns swallow-and-log into an escape in any
      # environment, which is the failure this whole guard exists to prevent.
      #
      # Narrow on the same terms as everything else here: a signal is not a broken config, and axn absorbs
      # one nowhere.
      def raises_in_dev?
        Axn.config.best_effort_raises_in_dev && Axn.config.env.development?
      rescue StandardError, *SWALLOWABLE_BEYOND_STANDARD_ERROR
        false
      end

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
      #
      # Every fact about the exception comes from `Internal::Rendering`, never from raw interpolation: this
      # code runs INSIDE the rescue, so a `message`, a `class`, or a backtrace read here is a second chance
      # for the exception to escape through the guard meant to contain it — and since the guard is called
      # from `ensure` all over the executor, an escape does not just lose a log line, it replaces the
      # exception already in flight. Two shapes reach it without a hostile author: an exception whose
      # `#message` raises, and an ordinary one whose STORED message holds bytes that cannot be joined to
      # axn's own prose.
      def _warn_and_swallow(exception, desc, action)
        raise exception if raises_in_dev?

        _report_swallowed(exception, desc, action)

        nil
      end

      # The backstop over the REPORTING, and over nothing else, absorbing whatever building or emitting the
      # warning can raise so a side-channel diagnostic is never what escapes.
      #
      # It lives in its own method rather than as a rescue on `_warn_and_swallow` because a method-level
      # rescue there would also cover the dev-loud `raise exception` above — and since the block's exception
      # is usually a StandardError, the dev-loud mode would silently stop being loud, logging and swallowing
      # exactly where it was configured to raise. The dev-loud path re-raises the BLOCK's exception, which
      # must leave through `best_effort`'s caller untouched.
      #
      # Narrow on the same terms as `best_effort` and `_emit_warning`: nothing here may absorb a class the
      # guard itself passes through (a signal, an `exit`, another library's control-flow signal).
      def _report_swallowed(exception, desc, action)
        _emit_warning(action, _warning_message(exception, desc))
      rescue StandardError, *SWALLOWABLE_BEYOND_STANDARD_ERROR
        nil
      end

      # Everything the warning names comes from `Internal::Rendering` rather than from raw interpolation.
      def _warning_message(exception, desc)
        described = _describe(desc)
        klass = Internal::Rendering.class_name(exception)
        message = Internal::Rendering.exception_message(exception)
        src = Internal::Rendering.exception_source_location(exception)

        if Axn.config.env.production?
          "Ignoring exception raised while #{described}: #{klass} - #{message} (from #{src})"
        else
          msg = "!! IGNORING EXCEPTION RAISED WHILE #{described.upcase} !!\n\n" \
                "\t* Exception: #{klass}\n" \
                "\t* Message: #{message}\n" \
                "\t* From: #{src}"
          "#{'⌵' * 30}\n\n#{msg}\n\n#{'^' * 30}"
        end
      end

      # `desc` names the intent and is a String by contract, but it is EXTENSION-AUTHOR input reaching the
      # gem's lowest guard, and the non-production wording calls `upcase` on it — so it is type-tested and
      # rendered on the same terms as everything else here. Anything that is not a String is named by its
      # class instead, which is a legible desc and cannot raise.
      def _describe(desc)
        return Internal::Text.renderable(desc) if Internal::Identity.kind?(desc, ::String)

        Internal::Rendering.class_name(desc)
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
    end
  end
end
