# frozen_string_literal: true

require "axn/extensions/auth"

module Axn
  module Extensions
    module Auth
      # Static API-key authentication: each principal id names one or more keys, and a request
      # authenticates as the principal whose key it presents.
      #
      #   Axn::Extensions::Auth::Bearer.new(keys: { "data_pipeline" => -> { ENV.fetch("PIPELINE_API_KEY") } })
      #
      # By default the key is read from `Authorization: Bearer <key>` (RFC 6750); pass `header:` to
      # read the raw value of a custom header instead (`header: "X-API-Key"`). A key is a String, a
      # Proc (resolved on every request, so a rotated secret takes effect without a restart; a
      # one-arity Proc receives the request), or an Array of those; a Proc may also return an Array.
      # Listing old and new keys together is how a rotation overlaps.
      class Bearer
        AUTHORIZATION = "Authorization"
        SCHEME = "Bearer"

        attr_reader :header

        def initialize(keys:, header: AUTHORIZATION)
          raise ConfigurationError, "Bearer keys must be a non-empty Hash of principal id => key(s)" unless keys.is_a?(Hash) && keys.any?
          raise ConfigurationError, "Bearer header must be a non-empty String" unless header.is_a?(String) && !header.strip.empty?

          @header = header
          @keys = keys.to_h { |principal, value| [principal.to_s, _check_literals!(principal, value)] }.freeze
        end

        def principals = @keys.keys

        # "Bearer" when reading Authorization, nil for a custom header — neutral metadata a serving
        # gem maps onto its own vocabulary (an OpenAPI security scheme, say).
        def scheme = authorization? ? SCHEME : nil

        # RFC 6750's challenge, for a 401 — only meaningful for the Authorization scheme.
        def unauthorized_headers = authorization? ? { "www-authenticate" => SCHEME } : {}

        def call(request)
          # Keys resolve (and are guarded) BEFORE the request is read, so a misconfigured deploy
          # raises on every request — anonymous ones included — instead of hiding behind 401s.
          candidates = @keys.to_h { |principal, value| [principal, _candidates(principal, value, request)] }
          token = _presented_token(request)
          return CREDENTIALS_MISSING unless token

          # Every candidate of every principal is compared — no early exit — so response timing
          # cannot tell an attacker which principal (or how many keys) a near-miss sat closest to.
          matched = candidates.select do |_principal, keys|
            keys.map { |key| Auth.secure_compare(token, key) }.reduce(false, :|)
          end.keys

          return CREDENTIALS_MISMATCH if matched.empty?
          raise ConfigurationError, "Bearer key matched more than one principal (#{matched.map(&:inspect).join(', ')}); keys must be unique" if matched.size > 1

          Verdict.ok(matched.first)
        end

        # Holds live credentials by definition: never render them.
        def inspect = "#<#{self.class.name} header=#{header.inspect} principals=#{principals.inspect} keys=[REDACTED]>"

        # PP walks instance variables directly rather than calling #inspect.
        def pretty_print(printer) = printer.text(inspect)

        private

        def authorization? = header.casecmp?(AUTHORIZATION)

        def _presented_token(request)
          raw = request.header(header).to_s.strip
          if authorization?
            scheme, token = raw.split(" ", 2)
            return nil unless scheme&.casecmp?(SCHEME)

            raw = token.to_s.strip
          end
          raw.empty? ? nil : raw
        end

        # Literals are checked once, here, so a blank key fails the deploy rather than every request.
        def _check_literals!(principal, value)
          list = value.is_a?(Array) ? value : [value]
          raise ConfigurationError, "Bearer key for #{principal.to_s.inspect} must list at least one key" if list.empty?

          list.each { |entry| Auth.require_secret!("Bearer key for #{principal.to_s.inspect}", entry) unless Auth.deferred?(entry) }
          value.is_a?(Array) ? value.dup.freeze : value
        end

        def _candidates(principal, value, request)
          # Not Kernel#Array on the resolved value: `Array(nil)` is `[]`, which would report a Proc
          # returning an unset ENV var as "no keys" instead of naming the nil it actually returned.
          entries = value.is_a?(Array) ? value : [value]
          entries.flat_map { |entry| (resolved = Auth.resolve(entry, request)).is_a?(Array) ? resolved : [resolved] }.tap do |keys|
            raise ConfigurationError, "Bearer key for #{principal.inspect} resolved to no keys" if keys.empty?

            keys.each { |key| Auth.require_secret!("Bearer key for #{principal.inspect}", key) }
          end
        end
      end
    end
  end
end
