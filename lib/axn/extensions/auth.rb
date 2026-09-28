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
    module Auth
      # A strategy or secret that is misconfigured rather than a request that is unauthenticated.
      # Raised, never returned as a rejection: a 401 meaning "we are misconfigured" is
      # indistinguishable from one meaning "you are not who you claim", and would otherwise present
      # as an unexplained outage. An ArgumentError, since it is a declaration mistake when it fires
      # at boot.
      class ConfigurationError < ArgumentError
        include Axn::Error
      end

      # The outcome of authenticating one request. `principal` is who the request authenticated as
      # (nil on a rejection, always); `reason` names why a rejection happened (nil when ok), so a
      # missing credential and a wrong one are separable in logs and metrics.
      #
      # Both halves are enforced at construction (`new` and `with` alike), not just by the factories: a
      # strategy can build a Verdict directly, and `normalize` passes a Verdict through as-is, so the
      # invariant a serving gem reads has to hold for every instance rather than for the ones axn made.
      Verdict = Data.define(:ok, :reason, :principal) do
        def self.ok(principal = nil) = new(ok: true, reason: nil, principal:)
        def self.rejected(reason) = new(ok: false, reason:, principal: nil)

        # `ok:` is the member's own name, which Data's keyword initializer requires.
        def initialize(ok:, reason: nil, principal: nil) # rubocop:disable Naming/MethodParameterName
          raise ArgumentError, "Verdict ok must be true or false" unless ok.equal?(true) || ok.equal?(false)
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
      # Asks the value nothing about itself: the type test is `Module#===` and emptiness is read off a
      # native copy, so a String subclass overriding `empty?` (or an object overriding `is_a?`/`class`)
      # can neither slip a weak key past the guard nor replace the error it raises. Returns that copy,
      # frozen — a plain String holding the same bytes — so what the caller authenticates against is
      # detached from the object it passed in and carries none of a subclass's overrides downstream.
      def require_secret!(declaration, value, label: "secret", error: ConfigurationError)
        string = Internal::Identity.kind?(value, ::String)
        secret = ::String.new(value).freeze if string
        return secret if string && !secret.empty?

        raise error,
              "#{declaration} #{label} must be a non-empty String " \
              "(got #{string ? 'an empty String' : Internal::RenderedClassName.of(value)})"
      end

      # Whether `value` is resolved per request (see `resolve`) rather than used as a literal. Only a
      # Proc: an arbitrary object that merely answers #call (a Method, a credential provider) is a
      # literal here, so a boot-time secret check cannot exempt something `resolve` would never call.
      # A Symbol is a literal too — resolving it against the request is a DSL convention a gem may
      # layer on top (axn-webhooks does), not something core should guess at.
      #
      # Decided with `Module#===` rather than `is_a?`, and arity read through Proc's own method, so a
      # value cannot claim deferral (and skip a boot-time secret check) or steer which way it is called.
      def deferred?(value) = Internal::Identity.kind?(value, ::Proc)

      PROC_ARITY = ::Proc.instance_method(:arity)
      private_constant :PROC_ARITY

      def resolve(value, request)
        return value unless deferred?(value)

        PROC_ARITY.bind_call(value).zero? ? value.call : value.call(request)
      end

      # Asks `ok?` FIRST: a rejecting verdict object is still a truthy Ruby object, so reading it for
      # truthiness would authenticate every rejected request. Anything without `ok?` (a boolean, a
      # found record) is read for truthiness.
      def verified?(verdict) = verdict.respond_to?(:ok?) ? verdict.ok? : !!verdict

      # Any strategy's answer as a Verdict. A rejection never carries a principal, whatever the
      # strategy returned alongside it. Only a genuine Verdict (checked natively) passes through as-is,
      # since only a genuine one had its invariants enforced at construction.
      def normalize(verdict)
        return verdict if Internal::Identity.kind?(verdict, Verdict)

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
