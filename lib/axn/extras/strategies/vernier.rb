# frozen_string_literal: true

require "fileutils"
require "axn/core/flow/handlers/invoker"

module Axn
  module Extras
    module Strategies
      module Vernier
        # @param if [Proc, Symbol, #call, nil] Optional condition to determine when to profile
        # @param sample_rate [Float] Sampling rate (0.0 to 1.0, default: 0.1)
        # @param output_dir [String, Pathname] Output directory for profile files (default: Rails.root/tmp/profiles or tmp/profiles)
        # @return [Module] A configured module that adds profiling to the action
        def self.configure(if: nil, sample_rate: 0.1, output_dir: nil)
          condition = binding.local_variable_get(:if)
          sample_rate_value = sample_rate
          output_dir_value = output_dir || _default_output_dir

          Module.new do
            extend ActiveSupport::Concern

            included do
              class_attribute :_vernier_condition, default: condition
              class_attribute :_vernier_sample_rate, default: sample_rate_value
              class_attribute :_vernier_output_dir, default: output_dir_value

              around do |hooked|
                _with_vernier_profiling { hooked.call }
              end
            end

            private

            def _with_vernier_profiling(&)
              return yield unless _should_profile?

              _profile_with_vernier(&)
            end

            def _profile_with_vernier(&)
              _ensure_vernier_available!

              class_name = self.class.name.presence || "AnonymousAction"
              profile_name = "axn_#{class_name}_#{Time.now.to_i}"

              # Ensure output directory exists (only once per instance)
              _ensure_output_directory_exists

              # Build output file path
              output_dir = self.class._vernier_output_dir || _default_output_dir
              output_file = File.join(output_dir, "#{profile_name}.json")

              # Configure Vernier with our settings
              collector_options = {
                out: output_file,
                allocation_sample_rate: (self.class._vernier_sample_rate * 1000).to_i,
              }

              ::Vernier.profile(**collector_options, &)
            end

            def _ensure_output_directory_exists
              return if @_vernier_directory_created

              output_dir = self.class._vernier_output_dir || _default_output_dir
              FileUtils.mkdir_p(output_dir)
              @_vernier_directory_created = true
            end

            def _should_profile?
              # Fast path: no condition means always profile
              return true unless self.class._vernier_condition

              # Slow path: evaluate condition (only when needed)
              Axn::Core::Flow::Handlers::Invoker.call(
                action: self,
                handler: self.class._vernier_condition,
                operation: "determining if profiling should run",
              )
            end

            def _ensure_vernier_available!
              return if defined?(::Vernier) && ::Vernier.is_a?(Module)

              begin
                require "vernier"
              rescue LoadError
                raise LoadError, <<~ERROR
                  Vernier profiler is not available. To use profiling, add 'vernier' to your Gemfile:

                    gem 'vernier', '~> 1.0'

                  Then run: bundle install
                ERROR
              end
            end

            def _default_output_dir
              if defined?(Rails) && Rails.respond_to?(:root)
                Rails.root.join("tmp", "profiles")
              else
                Pathname.new("tmp/profiles")
              end
            end
          end
        end

        private_class_method def self._default_output_dir
          if defined?(Rails) && Rails.respond_to?(:root)
            Rails.root.join("tmp", "profiles")
          else
            Pathname.new("tmp/profiles")
          end
        end
      end
    end
  end
end

# Register the strategy (it handles missing vernier dependency gracefully)
Axn::Strategies.register(:vernier, Axn::Extras::Strategies::Vernier)
