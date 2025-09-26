# frozen_string_literal: true

module Axn
  module RailsIntegration
    module Generators
      class AxnGenerator < Rails::Generators::NamedBase
        source_root File.expand_path("templates", __dir__)

        argument :expectations, type: :array, default: [], banner: "expectation1 expectation2 ..."

        def create_action_file
          template "action.rb.erb", "app/actions/#{file_path}.rb"
        end

        def create_spec_file
          return unless spec_generation_enabled?

          template "action_spec.rb.erb", "spec/actions/#{file_path}_spec.rb"
        end

        private

        def class_name
          @class_name ||= name.camelize
        end

        def file_path
          @file_path ||= name.underscore
        end

        def expectations_with_types
          expectations.map { |exp| { name: exp, type: "String" } }
        end

        def spec_generation_enabled?
          return false unless rspec_available?
          return false if spec_generation_skipped?

          true
        end

        def rspec_available?
          defined?(RSpec)
        end

        def spec_generation_skipped?
          return false unless defined?(Rails) && Rails.application&.config&.generators

          generators_config = Rails.application.config.generators

          # Check individual boolean flags (modern style)
          return true if generators_config.respond_to?(:test_framework) &&
                         generators_config.test_framework == false

          # Check for specific spec-related flags
          spec_flags = %w[specs axn_specs]
          spec_flags.each do |flag|
            return true if generators_config.respond_to?(flag) &&
                           generators_config.public_send(flag) == false
          end

          false
        end
      end
    end
  end
end
