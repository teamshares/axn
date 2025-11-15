# frozen_string_literal: true

module Axn
  module Extras
    module Strategies
      module Client
        def self.configure(name: :client, prepend_config: nil, debug: false, user_agent: nil, **options, &block)
          # Aliasing to avoid shadowing/any confusion
          client_name = name

          Module.new do
            extend ActiveSupport::Concern

            included do
              raise ArgumentError, "client strategy: desired client name '#{client_name}' is already taken" if method_defined?(client_name)

              define_method client_name do
                # Hydrate options that are callable (e.g. procs), so we can set e.g. per-request expiration
                # headers and/or other non-static values.
                hydrated_options = options.transform_values do |value|
                  value.respond_to?(:call) ? value.call : value
                end

                Faraday.new(**hydrated_options) do |conn|
                  conn.headers["Content-Type"] = "application/json"
                  conn.headers["User-Agent"] = user_agent || "#{client_name} / Axn Client Strategy / v#{Axn::VERSION}"

                  # Because middleware is executed in reverse order, downstream user may need flexibility in where to inject configs
                  prepend_config&.call(conn)

                  conn.response :raise_error
                  conn.request :url_encoded
                  conn.request :json
                  conn.response :json, content_type: /\bjson$/

                  # Enable for debugging
                  conn.response :logger if debug

                  block&.call(conn)
                end
              end
              memo client_name
            end
          end
        end
      end
    end
  end
end

# Register the strategy only if faraday is available
Axn::Strategies.register(:client, Axn::Extras::Strategies::Client) if defined?(Faraday)
