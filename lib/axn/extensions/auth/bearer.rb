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
          # A padded name (a config value's stray space) would match no request header: every request a 401.
          raise ConfigurationError, "Bearer header #{header.inspect} has leading or trailing whitespace" unless header.strip == header

          # A frozen copy: the name decides both which header is read and whether it is parsed as
          # `Bearer <key>`, so the caller mutating its String must change neither.
          @header = header.dup.freeze
          @keys = _principal_ids(keys).to_h { |id, value| [id, _check_literals!(id, value)] }.freeze
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

        # Principal ids canonicalize to frozen Strings, so two ids that stringify alike (`:svc` and
        # `"svc"`) would silently collapse into one entry and drop a configured key — refused instead.
        def _principal_ids(keys)
          seen = {}
          keys.to_h do |principal, value|
            id = _principal_id(principal)
            if seen.key?(id)
              raise ConfigurationError,
                    "Bearer principal ids must be unique: #{seen[id].inspect} and #{principal.inspect} both name principal #{id.inspect}"
            end

            seen[id] = principal
            [id, value]
          end
        end

        def _principal_id(principal)
          return principal.to_s.dup.freeze if (principal.is_a?(String) || principal.is_a?(Symbol)) && !principal.empty?

          raise ConfigurationError, "Bearer principal id must be a non-empty String or Symbol (got #{principal.class})"
        end

        # Literals are checked once, here, so a blank key fails the deploy rather than every request.
        # Each is stored as `require_secret!`'s frozen copy (inside a new frozen Array for a list), so
        # mutating what the caller still holds cannot change which credential authenticates.
        def _check_literals!(id, value)
          list = _key_list(value)
          raise ConfigurationError, "Bearer key for #{id.inspect} must list at least one key" if list.empty?

          checked = list.map { |entry| Auth.deferred?(entry) ? _require_resolvable!(id, entry) : _require_key!(id, entry) }
          value.is_a?(Array) ? checked.freeze : checked.first
        end

        # Not Kernel#Array: `Array(nil)` is `[]`, which would report a Proc returning an unset ENV var
        # as "no keys" instead of naming the nil it actually returned.
        def _key_list(value) = value.is_a?(Array) ? value : [value]

        def _require_resolvable!(id, value)
          return value if Auth.resolvable?(value)

          raise ConfigurationError, "Bearer key for #{id.inspect} is a Proc that takes neither zero arguments nor one request argument"
        end

        # `require_secret!`, plus the one rule specific to reading a token out of a header: the presented
        # token is stripped before comparison, so a key with surrounding whitespace (a secret file's
        # trailing newline, typically) could never match. That is a misconfiguration to raise, not a
        # permanent stream of mismatches.
        def _require_key!(id, value)
          key = Auth.require_secret!("Bearer key for #{id.inspect}", value)
          return key if key.strip == key

          raise ConfigurationError,
                "Bearer key for #{id.inspect} has leading or trailing whitespace; presented tokens are stripped, so it could never match"
        end

        def _candidates(id, value, request)
          keys = _key_list(value).flat_map { |entry| _key_list(Auth.resolve(entry, request)) }
          raise ConfigurationError, "Bearer key for #{id.inspect} resolved to no keys" if keys.empty?

          keys.map { |key| _require_key!(id, key) }
        end
      end
    end
  end
end
