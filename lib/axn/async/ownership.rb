# frozen_string_literal: true

module Axn
  module Async
    # Public predicate for "is this job/notice signal Axn-owned?".
    #
    # Error-reporter `before_notify`-style filters (Honeybadger, Sentry, etc.) need to suppress
    # backend-native duplicate reports for Axn async failures, since Axn already reports them via
    # its own `on_exception` path. Doing so means answering "did this notice come from an Axn
    # action?" — which requires knowing Axn's internal async wiring (the generic Sidekiq worker,
    # the ActiveJob proxy naming convention, the Sidekiq `display_class` wire detail).
    #
    # That knowledge lives here, not in every downstream filter, so a future adapter refactor
    # (a new backend, a worker rename) is a one-line change in Axn instead of a silent break in
    # every downstream integration. See docs/recipes/suppressing-duplicate-async-reports.md.
    module Ownership
      # The ActiveJob adapter names its per-action proxy "<Action>::ActiveJobProxy" (see
      # Adapters::ActiveJob). The proxy itself is not `< Axn`, so we strip the suffix to recover
      # the real action class before constantizing.
      ACTIVE_JOB_PROXY_SUFFIX = "::ActiveJobProxy"

      # Is this job/notice signal Axn-owned?
      #
      # Accepts whatever an error reporter's Sidekiq/ActiveJob plugin might hand you:
      #   - a Class/Module already resolved by the caller
      #   - a String class name (may carry an "::ActiveJobProxy" suffix from the ActiveJob adapter)
      #   - a Hash (raw Sidekiq job hash, string OR symbol keys) — checks "display_class", then
      #     "wrapped", then "class", in that priority, to recover the real job/action class name
      #
      # Blank/nil/unrecognized input returns false (never raises), so a filter can pass every
      # signal it has through this predicate without guarding each one.
      #
      # @param candidate [Class, Module, String, Hash, nil]
      # @return [Boolean]
      def owned_by?(candidate)
        klass = _ownership_resolve_class(candidate)
        return false unless klass.is_a?(Module)
        return true if klass < Axn

        _ownership_predicates.any? { |predicate| predicate.call(klass) }
      end

      # Register an additional predicate that recognizes an adapter's own wrapper/worker class as
      # Axn-owned. Lets a new async adapter extend detection without any downstream filter change.
      # The block receives a resolved Class and returns truthy when it is that adapter's wrapper.
      #
      # @yieldparam klass [Class]
      # @return [self]
      def register_ownership_predicate(&block)
        _ownership_predicates << block
        self
      end

      private

      def _ownership_predicates
        @_ownership_predicates ||= []
      end

      # Normalize any accepted input shape to a resolved Class (or nil).
      def _ownership_resolve_class(candidate)
        case candidate
        when nil then nil
        when Module then _ownership_normalize_module(candidate)
        when String then _ownership_constantize(candidate)
        when Hash then _ownership_constantize(_ownership_job_hash_class_name(candidate))
        end
      end

      # A resolved ActiveJob proxy class (`<Action>::ActiveJobProxy`) inherits from
      # ActiveJob::Base, not Axn, so a caller that hands us the proxy Class directly (rather than
      # its name String) must still resolve back to the real action — same as the String path.
      def _ownership_normalize_module(mod)
        name = mod.name
        return mod unless name&.end_with?(ACTIVE_JOB_PROXY_SUFFIX)

        _ownership_constantize(name)
      end

      def _ownership_constantize(name)
        name = name.to_s
        return nil if name.empty?

        name.delete_suffix(ACTIVE_JOB_PROXY_SUFFIX).safe_constantize
      end

      # Recover the real job/action class name from a raw Sidekiq job hash. display_class (set at
      # enqueue via `.set(display_class: name)`) carries the real action for the generic worker;
      # wrapped carries the real job for ActiveJob-in-Sidekiq; class is the enqueued worker itself.
      # `presence` (not bare `||`) so a blank value falls through to the next key rather than
      # short-circuiting on it — an empty string is truthy in Ruby.
      def _ownership_job_hash_class_name(hash)
        (hash["display_class"] || hash[:display_class]).presence ||
          (hash["wrapped"] || hash[:wrapped]).presence ||
          (hash["class"] || hash[:class]).presence
      end
    end

    extend Ownership
  end
end
