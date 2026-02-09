# frozen_string_literal: true

# rubocop:disable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/BlockNesting
module Axn
  module Extras
    module Strategies
      module Client
        # Injects request/response into the action's set_execution_context under client_strategy__last_request
        # so exception reporting (e.g. on_exception) includes the last client request (url, method, status, etc.).
        def self.ensure_execution_context_middleware_defined
          return if const_defined?(:ExecutionContextMiddleware, false)

          const_set(:ExecutionContextMiddleware, Class.new(::Faraday::Middleware) do
            def initialize(app, action_instance)
              super(app)
              @action_instance = action_instance
            end

            def call(env)
              assign_request_context(env)
              @app.call(env).on_complete { |response_env| assign_response_context(env, response_env) }
            end

            private

            def assign_request_context(env)
              return unless @action_instance.respond_to?(:set_execution_context, true)

              @action_instance.send(:set_execution_context,
                                    client_strategy__last_request: {
                                      url: env.url.to_s,
                                      method: env.method.to_s.upcase,
                                    })
            end

            def assign_response_context(request_env, response_env)
              return unless @action_instance.respond_to?(:set_execution_context, true)

              last_request = {
                url: request_env.url.to_s,
                method: request_env.method.to_s.upcase,
                status: response_env.status,
              }
              last_request[:response_content_type] = response_env.response_headers["Content-Type"] if response_env.response_headers["Content-Type"]
              @action_instance.send(:set_execution_context, client_strategy__last_request: last_request)
            end
          end)
        end

        def self.configure(name: :client, prepend_config: nil, debug: false, user_agent: nil, error_handler: nil, **options, &block)
          # Aliasing to avoid shadowing/any confusion
          client_name = name
          error_handler_config = error_handler

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

                ::Faraday.new(**hydrated_options) do |conn|
                  conn.headers["Content-Type"] = "application/json"
                  conn.headers["User-Agent"] = user_agent || "#{client_name} / Axn Client Strategy / v#{Axn::VERSION}"

                  # Because middleware is executed in reverse order, downstream user may need flexibility in where to inject configs
                  prepend_config&.call(conn)

                  # Auto-inject request/response into set_execution_context for exception reporting
                  Client.ensure_execution_context_middleware_defined
                  conn.use Client::ExecutionContextMiddleware, self

                  conn.response :raise_error
                  conn.request :url_encoded
                  conn.request :json
                  conn.response :json, content_type: /\bjson$/

                  # Enable for debugging
                  conn.response :logger if debug

                  # Inject error handler middleware if configured
                  if error_handler_config && defined?(Faraday)
                    unless Client.const_defined?(:ErrorHandlerMiddleware, false)
                      Client.const_set(:ErrorHandlerMiddleware, Class.new(::Faraday::Middleware) do
                        def initialize(app, config)
                          super(app)
                          @config = config
                        end

                        def call(env)
                          @app.call(env).on_complete do |response_env|
                            body = parse_body(response_env.body)
                            condition = @config[:if] || -> { status != 200 }

                            @response_env = response_env
                            @body = body
                            should_handle = instance_exec(&condition)

                            handle_error(response_env, body) if should_handle
                          end
                        end

                        def status
                          @response_env&.status
                        end

                        attr_reader :body, :response_env

                        private

                        def parse_body(body)
                          return {} if body.blank?

                          body.is_a?(String) ? JSON.parse(body) : body
                        rescue JSON::ParserError
                          {}
                        end

                        def handle_error(response_env, body)
                          error = extract_value(body, @config[:error_key])
                          details = extract_value(body, @config[:detail_key]) if @config[:detail_key]
                          backtrace = extract_value(body, @config[:backtrace_key]) if @config[:backtrace_key]

                          formatted_message = if @config[:formatter]
                                                @config[:formatter].call(error, details, response_env)
                                              else
                                                format_default_message(error, details)
                                              end

                          prefix = "Error while #{response_env.method.to_s.upcase}ing #{response_env.url}"
                          message = formatted_message.present? ? "#{prefix}: #{formatted_message}" : prefix

                          exception_class = @config[:exception_class] || ::Faraday::BadRequestError
                          exception = exception_class.new(message)
                          exception.set_backtrace(backtrace) if backtrace.present?
                          raise exception
                        end

                        def extract_value(data, key)
                          return nil if key.blank?

                          keys = key.split(".")
                          keys.reduce(data) do |current, k|
                            return nil unless current.is_a?(Hash)

                            current[k.to_s] || current[k.to_sym]
                          end
                        end

                        def format_default_message(error, details)
                          parts = []
                          parts << error if error

                          if details
                            if @config[:extract_detail]
                              extracted = if details.is_a?(Hash)
                                            details.map { |key, value| @config[:extract_detail].call(key, value) }.compact.to_sentence
                                          else
                                            Array(details).map { |node| @config[:extract_detail].call(node) }.compact.to_sentence
                                          end
                              parts << extracted if extracted.present?
                            elsif details.present?
                              raise ArgumentError, "must provide extract_detail when detail_key is set and details is not a string" unless details.is_a?(String)

                              parts << details
                            end
                          end

                          parts.compact.join(" - ")
                        end
                      end)
                    end
                    conn.use Client::ErrorHandlerMiddleware, error_handler_config
                  end

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
# rubocop:enable Metrics/AbcSize, Metrics/CyclomaticComplexity, Metrics/MethodLength, Metrics/PerceivedComplexity, Metrics/BlockNesting

# Register the strategy only if faraday is available
Axn::Strategies.register(:client, Axn::Extras::Strategies::Client) if defined?(Faraday)
