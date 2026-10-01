# frozen_string_literal: true

require "openssl"
require "axn/exceptions"
require "axn/extensions"

module Axn
  module Extensions
    # Shared request-authentication primitives for gems that accept inbound requests on axn's behalf
    # (axn-openapi's mounts, axn-webhooks' verifiers). Transport-free on purpose: axn has no Rack
    # dependency, so a "request" here is any object answering `#header(name)` — each gem adapts its
    # own request object to that one method rather than core learning a framework.
    #
    # A **strategy** is any object answering `#call(request)` with a verdict: a `Verdict`, anything
    # else answering `ok?` (optionally `reason`/`principal`), or a bare boolean. Optional metadata a
    # strategy may publish for the gem serving it: `#principals` (the ids it can authenticate, so a
    # gem can check an allowlist against them at boot), `#unauthorized_headers` (a challenge to attach
    # to a 401), and `#scheme`/`#header` (a neutral description a gem maps onto its own vocabulary —
    # an OpenAPI security scheme, say). `Bearer` is the built-in one.
    #
    # `Auth::ConfigurationError` lives in axn/exceptions with the rest of the public error hierarchy.
    module Auth
      # The outcome of authenticating one request. `principal` is who the request authenticated as
      # (nil on a rejection, always); `reason` names why a rejection happened (nil when ok), so a
      # missing credential and a wrong one are separable in logs and metrics.
      #
      # Enforced at construction, not just by the factories: a strategy can build a Verdict directly,
      # and `normalize` passes a Verdict through as-is.
      Verdict = Data.define(:ok, :reason, :principal) do
        def self.ok(principal = nil) = new(ok: true, reason: nil, principal:)
        def self.rejected(reason) = new(ok: false, reason:, principal: nil)

        # `ok:` is the member's own name, which Data's keyword initializer requires.
        def initialize(ok:, reason: nil, principal: nil) # rubocop:disable Naming/MethodParameterName
          raise ArgumentError, "Verdict ok must be true or false" unless [true, false].include?(ok)
          raise ArgumentError, "a rejected Verdict cannot carry a principal" if !ok && !principal.nil?
          raise ArgumentError, "an ok Verdict cannot carry a reason" if ok && !reason.nil?

          super
        end

        def ok? = ok
      end

      # The request presented no credential this strategy reads (absent header, wrong scheme).
      CREDENTIALS_MISSING = Verdict.rejected(:credentials_missing).freeze
      # The request presented a credential, and it matched nothing.
      CREDENTIALS_MISMATCH = Verdict.rejected(:credentials_mismatch).freeze

      module_function

      # Constant-time AND length-independent: both sides are hashed to fixed-width digests first, so
      # the comparison answers neither "which byte differed" nor "how long is the secret". Same
      # construction as ActiveSupport::SecurityUtils.secure_compare. False (never raises) on nil.
      def secure_compare(candidate, expected)
        return false if candidate.nil? || expected.nil?

        OpenSSL.fixed_length_secure_compare(
          OpenSSL::Digest::SHA256.digest(candidate.to_s),
          OpenSSL::Digest::SHA256.digest(expected.to_s),
        )
      end

      # THE secret guard. A blank or absent secret is not a failure, it is a WEAK KEY: `""` compares
      # equal to an empty credential and is a legal HMAC key, so it is an authentication bypass rather
      # than a mismatch. `false` would coerce to the guessable String "false". Names the value's TYPE
      # or emptiness only — never its bytes, since this can fire on every request.
      #
      # Returns a frozen copy, so later mutation of the caller's String cannot change the secret.
      def require_secret!(declaration, value, label: "secret", error: ConfigurationError)
        return value.dup.freeze if value.is_a?(String) && !value.empty?

        raise error,
              "#{declaration} #{label} must be a non-empty String " \
              "(got #{value.is_a?(String) ? 'an empty String' : value.class})"
      end

      # Whether `value` is resolved per request (see `resolve`) rather than used as a literal. Only a
      # Proc: an arbitrary object that merely answers #call (a Method, a credential provider) is a
      # literal here, so a boot-time secret check cannot exempt something `resolve` would never call.
      # A Symbol is a literal too — resolving it against the request is a DSL convention a gem may
      # layer on top (axn-webhooks does), not something core should guess at.
      def deferred?(value) = value.is_a?(Proc)

      # Whether `resolve` can call `value`: true for a literal, and for a Proc it would call bare (arity
      # zero) or with the request as its single positional argument. False for a Proc that needs a
      # second argument or a required keyword, which `resolve` could only answer with an ArgumentError
      # on every request — so a strategy can check it at construction and fail the deploy instead.
      def resolvable?(value)
        return true if !deferred?(value) || value.arity.zero?

        parameters = value.parameters
        return false if parameters.any? { |type, _| type == :keyreq }

        required = parameters.count { |type, _| type == :req }
        required == 1 || (required.zero? && parameters.any? { |type, _| %i[opt rest].include?(type) })
      end

      def resolve(value, request)
        return value unless deferred?(value)

        value.arity.zero? ? value.call : value.call(request)
      end

      # Asks `ok?` FIRST: a rejecting verdict object is still a truthy Ruby object, so reading it for
      # truthiness would authenticate every rejected request. Anything without `ok?` (a boolean, a
      # found record) is read for truthiness. Always a strict boolean.
      def verified?(verdict) = verdict.respond_to?(:ok?) ? !!verdict.ok? : !!verdict

      # Any strategy's answer as a Verdict. A rejection never carries a principal, whatever the
      # strategy returned alongside it.
      def normalize(verdict)
        return verdict if verdict.is_a?(Verdict)

        if verified?(verdict)
          Verdict.ok(verdict.respond_to?(:principal) ? verdict.principal : nil)
        else
          reason = verdict.respond_to?(:reason) ? verdict.reason : nil
          Verdict.rejected(reason || :rejected)
        end
      end
    end
  end
end

require "axn/extensions/auth/bearer"
