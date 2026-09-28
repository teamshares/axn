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

          @header = _header_name(header)
          @keys = _principal_ids(keys).to_h { |id, (_label, value)| [id, _check_literals!(id, value)] }.freeze
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

        # Stored as a detached, frozen native copy: the name decides both which header is read and
        # whether it is parsed as `Bearer <key>`, so the caller mutating its String must change neither.
        def _header_name(header)
          name = ::String.new(header).freeze if Internal::Identity.kind?(header, ::String)
          return name if name && !name.strip.empty?

          raise ConfigurationError, "Bearer header must be a non-empty String"
        end

        def _presented_token(request)
          raw = request.header(header).to_s.strip
          if authorization?
            scheme, token = raw.split(" ", 2)
            return nil unless scheme&.casecmp?(SCHEME)

            raw = token.to_s.strip
          end
          raw.empty? ? nil : raw
        end

        # Principal ids canonicalize to Strings, so two ids that stringify alike (`:svc` and `"svc"`)
        # would silently collapse into one entry and drop a configured key — refused instead. Only a
        # String or Symbol is an id: anything else would stringify to whatever its own `to_s` says.
        # Messages render the canonical id (or the Symbol, which carries no overrides), never the
        # caller's String, so reporting cannot run a subclass's `inspect`.
        def _principal_ids(keys)
          keys.each_with_object({}) do |(principal, value), ids|
            id = _principal_id(principal)
            label = Internal::Identity.kind?(principal, ::Symbol) ? principal.inspect : id.inspect
            raise ConfigurationError, "Bearer principal ids must be unique: #{ids[id].first} and #{label} both name principal #{id.inspect}" if ids.key?(id)

            ids[id] = [label, value]
          end
        end

        # Symbol#to_s cannot be overridden; a String is copied natively, so a subclass's own `to_s`/`empty?` never run.
        def _principal_id(principal)
          id = case principal
               when ::Symbol then principal.to_s
               when ::String then ::String.new(principal).freeze
               end
          return id if id && !id.empty?

          raise ConfigurationError, "Bearer principal id must be a non-empty String or Symbol (got #{Internal::RenderedClassName.of(principal)})"
        end

        # Literals are checked once, here, so a blank key fails the deploy rather than every request.
        # Each is stored as the guard's detached copy, never the caller's object (nor the caller's
        # Array), so mutating what the caller still holds cannot change which credential authenticates.
        def _check_literals!(id, value)
          list = value.is_a?(Array) ? value : [value]
          raise ConfigurationError, "Bearer key for #{id.inspect} must list at least one key" if list.empty?

          checked = list.map { |entry| Auth.deferred?(entry) ? entry : _require_key!(id, entry) }
          value.is_a?(Array) ? checked.freeze : checked.first
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
          # Not Kernel#Array on the resolved value: `Array(nil)` is `[]`, which would report a Proc
          # returning an unset ENV var as "no keys" instead of naming the nil it actually returned.
          entries = value.is_a?(Array) ? value : [value]
          entries.flat_map { |entry| (resolved = Auth.resolve(entry, request)).is_a?(Array) ? resolved : [resolved] }.tap do |keys|
            raise ConfigurationError, "Bearer key for #{id.inspect} resolved to no keys" if keys.empty?

            keys.map! { |key| _require_key!(id, key) }
          end
        end
      end
    end
  end
end
