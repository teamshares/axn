# frozen_string_literal: true

require_relative "../../lib/axn"

module Benchmark
  module AxnScenarios
    # Bare minimum - just confirms Axn runs without raising
    class BareAction
      include Axn

      def call
        # Does nothing - just confirms the framework overhead
      end
    end

    # Minimal with basic input/output
    class MinimalAction
      include Axn

      expects :name
      exposes :greeting

      def call
        expose :greeting, "Hello, #{name}!"
      end
    end

    # Basic action with multiple inputs/outputs
    class BasicAction
      include Axn

      expects :name, :email
      exposes :greeting, :user_id

      def call
        user_id = rand(1000)
        greeting = "Hello, #{name}! Your email is #{email}."
        expose :greeting, greeting
        expose :user_id, user_id
      end
    end

    # Type validation with various types
    class TypeValidationAction
      include Axn

      expects :name, type: String
      expects :email, type: String
      expects :age, type: Integer, optional: true
      expects :admin, type: :boolean, default: false
      expects :tags, type: Array, optional: true
      exposes :greeting, :user_info

      def call
        greeting = "Hello, #{name}! Your email is #{email}."
        greeting += " You are #{age} years old." if age
        expose :greeting, greeting

        user_info = {
          admin:,
          tags: tags || [],
          created_at: Time.now,
        }
        expose :user_info, user_info
      end
    end

    # Complex validation with nested fields
    class NestedValidationAction
      include Axn

      expects :user, type: Hash
      exposes :processed_user

      def call
        # Manual validation of nested fields
        validate_user_data!

        processed_user = {
          name: user[:name],
          email: user[:email],
          profile: user[:profile] || {},
          processed_at: Time.now,
        }
        expose :processed_user, processed_user
      end

      private

      def validate_user_data!
        fail!("User name is required") unless user[:name].is_a?(String) && !user[:name].empty?
        fail!("User email is required") unless user[:email].is_a?(String) && user[:email].include?("@")

        return unless user[:profile]

        fail!("Profile must be a hash") unless user[:profile].is_a?(Hash)
        fail!("Profile bio must be a string") if user[:profile][:bio] && !user[:profile][:bio].is_a?(String)
        return unless user[:profile][:avatar_url] && !user[:profile][:avatar_url].is_a?(String)

        fail!("Profile avatar_url must be a string")
      end
    end

    # With hooks
    class HooksAction
      include Axn

      expects :name, :email
      exposes :greeting, :processed_at

      before do
        @start_time = Time.now
      end

      after do
        @end_time = Time.now
        expose :processed_at, @end_time
      end

      def call
        greeting = "Hello, #{name}! Your email is #{email}."
        expose :greeting, greeting
      end
    end

    # Error handling with custom messages
    class ErrorHandlingAction
      include Axn

      expects :name, :email
      expects :should_fail, type: :boolean, default: false
      expects :error_type, type: String, optional: true
      exposes :greeting

      success "User processed successfully"
      error "Failed to process user: %<reason>s"

      def call
        validate_inputs!
        simulate_business_logic!

        greeting = "Hello, #{name}! Your email is #{email}."
        expose :greeting, greeting
      end

      private

      def validate_inputs!
        fail!("Name cannot be blank", reason: "invalid_name") if name.blank?
        fail!("Email format invalid", reason: "invalid_email") unless email.include?("@")
      end

      def simulate_business_logic!
        case error_type
        when "timeout"
          fail!("Request timed out", reason: "timeout")
        when "validation"
          fail!("Validation failed", reason: "validation")
        when "network"
          fail!("Network error", reason: "network")
        end

        fail!("Simulated error", reason: "simulated") if should_fail
      end
    end

    # Error handling with conditional messages
    class ConditionalErrorAction
      include Axn

      expects :user_id, type: Integer
      expects :action_type, type: String
      exposes :action_result

      success "Action completed successfully"
      error "User not found", if: -> { user_id.zero? }
      error "Invalid action: %<action_type>s", if: -> { !%w[create update delete].include?(action_type) }
      error "Permission denied for user %<user_id>s", if: -> { user_id.negative? }

      def call
        action_result = {
          user_id:,
          action: action_type,
          timestamp: Time.now,
          status: "completed",
        }
        expose :action_result, action_result
      end
    end

    # With composition (steps)
    class CompositionAction
      include Axn

      expects :name, :email
      exposes :greeting, :processed_at

      step :validate_input do
        fail!("Name is required") if name.blank?
        fail!("Email is required") if email.blank?
      end

      step :generate_greeting do
        greeting = "Hello, #{name}! Your email is #{email}."
        expose :greeting, greeting
      end

      step :add_timestamp do
        expose :processed_at, Time.now
      end

      def call
        # Steps handle the logic
      end
    end

    # With simulated database operations
    class DatabaseAction
      include Axn

      expects :name, :email
      exposes :greeting, :user_id

      def call
        # Simulate database operations
        user_id = rand(1000)
        greeting = "Hello, #{name}! Your email is #{email}. User ID: #{user_id}"
        expose :greeting, greeting
        expose :user_id, user_id
      end
    end

    # Complex scenario with multiple features
    class ComplexAction
      include Axn

      expects :name, type: String
      expects :email, type: String
      expects :age, type: Integer, optional: true
      expects :admin, type: :boolean, default: false
      exposes :greeting, :user_id, :processed_at, :admin_status

      before do
        @start_time = Time.now
        @user_id = rand(1000)
      end

      after do
        @end_time = Time.now
        expose :processed_at, @end_time
      end

      step :validate_input do
        fail!("Name is required") if name.blank?
        fail!("Email is required") if email.blank?
        fail!("Email format invalid") unless email.include?("@")
      end

      step :generate_greeting do
        greeting = "Hello, #{name}! Your email is #{email}."
        greeting += " You are #{age} years old." if age
        expose :greeting, greeting

        admin_status = admin ? "Admin user" : "Regular user"
        expose :admin_status, admin_status
      end

      step :add_metadata do
        expose :user_id, @user_id
      end

      def call
        # Steps handle the logic
      end
    end

    # Nested action calls with error propagation
    class NestedAction
      include Axn

      expects :name, :email
      expects :nested_should_fail, type: :boolean, default: false
      exposes :greeting, :nested_result, :processing_chain

      def call
        # Call another action
        nested_result = BasicAction.call(name:, email:)
        fail!("Nested action failed: #{nested_result.error}") unless nested_result.ok?

        # Simulate processing chain
        processing_chain = %w[input_validation nested_processing final_processing]

        greeting = "Nested: #{nested_result.greeting}"
        expose :greeting, greeting
        expose :nested_result, nested_result.greeting
        expose :processing_chain, processing_chain
      end
    end

    # Business logic with multiple service calls
    class ServiceOrchestrationAction
      include Axn

      expects :user_id, type: Integer
      expects :order_data, type: Hash
      exposes :order_data, :user_info, :inventory_status

      def call
        # Simulate multiple service calls
        user_info = fetch_user_info
        inventory_status = check_inventory
        order_data = process_order

        expose :user_info, user_info
        expose :inventory_status, inventory_status
        expose :order_data, order_data
      end

      private

      def fetch_user_info
        { id: user_id, name: "User #{user_id}", status: "active" }
      end

      def check_inventory
        { available: true, quantity: rand(100), location: "warehouse_1" }
      end

      def process_order
        {
          order_id: rand(10_000),
          status: "processed",
          total: order_data[:amount] || 0,
          processed_at: Time.now,
        }
      end
    end

    # Data transformation with complex logic
    class DataTransformationAction
      include Axn

      expects :raw_data, type: Array
      expects :transform_options, type: Hash, optional: true
      exposes :transformed_data, :statistics

      def call
        transformed_data = raw_data.map do |item|
          transform_item(item)
        end

        statistics = calculate_statistics(transformed_data)

        expose :transformed_data, transformed_data
        expose :statistics, statistics
      end

      private

      def transform_item(item)
        {
          id: item[:id] || rand(1000),
          name: item[:name]&.upcase,
          value: (item[:value] || 0) * (transform_options&.dig(:multiplier) || 1),
          processed_at: Time.now,
          metadata: {
            original_keys: item.keys,
            transform_version: "1.0",
          },
        }
      end

      def calculate_statistics(data)
        {
          count: data.length,
          total_value: data.sum { |item| item[:value] },
          average_value: data.length.positive? ? data.sum { |item| item[:value] } / data.length : 0,
          processed_at: Time.now,
        }
      end
    end

    # All scenarios for easy access - ordered by complexity
    SCENARIOS = {
      bare: BareAction,
      minimal: MinimalAction,
      basic: BasicAction,
      type_validation: TypeValidationAction,
      nested_validation: NestedValidationAction,
      hooks: HooksAction,
      error_handling: ErrorHandlingAction,
      conditional_error: ConditionalErrorAction,
      composition: CompositionAction,
      database: DatabaseAction,
      service_orchestration: ServiceOrchestrationAction,
      data_transformation: DataTransformationAction,
      complex: ComplexAction,
      nested: NestedAction,
    }.freeze

    def self.run_scenario(scenario_name, **args)
      scenario_class = SCENARIOS[scenario_name]
      raise "Unknown scenario: #{scenario_name}" unless scenario_class

      scenario_class.call(**args)
    end

    def self.basic_scenarios
      %i[bare minimal basic]
    end

    def self.validation_scenarios
      %i[type_validation nested_validation]
    end

    def self.feature_scenarios
      %i[hooks error_handling conditional_error composition]
    end

    def self.business_scenarios
      %i[database service_orchestration data_transformation]
    end

    def self.complex_scenarios
      %i[complex nested]
    end

    def self.all_scenarios
      SCENARIOS.keys
    end
  end
end
