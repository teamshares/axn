# frozen_string_literal: true

require "fileutils"
require "axn/core/flow/handlers/invoker"

module Axn
  module Core
    module Profiling
      def self.included(base)
        base.class_eval do
          class_attribute :_profiling_enabled, default: false
          class_attribute :_profiling_condition, default: nil

          extend ClassMethods
        end
      end

      module ClassMethods
        # Enable profiling for this action class
        #
        # @param if [Proc, Symbol, #call, nil] Optional condition to determine when to profile
        # @return [void]
        def profile(if: nil)
          self._profiling_enabled = true
          self._profiling_condition = binding.local_variable_get(:if)
        end
      end

      private

      def _with_profiling(&)
        # Fastest path: global profiling disabled
        return yield unless Axn.config.profiling_enabled

        # Check if this specific action should be profiled
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
        output_file = File.join(Axn.config.profiling_output_dir, "#{profile_name}.json")

        # Configure Vernier with our settings
        collector_options = {
          out: output_file,
          allocation_sample_rate: (Axn.config.profiling_sample_rate * 1000).to_i,
        }

        Vernier.profile(**collector_options, &)
      end

      def _ensure_output_directory_exists
        return if @_profiling_directory_created

        output_dir = Axn.config.profiling_output_dir
        FileUtils.mkdir_p(output_dir)
        @_profiling_directory_created = true
      end

      def _should_profile?
        # Fast path: check if action has profiling enabled
        return false unless self.class._profiling_enabled

        # Fast path: no condition means always profile
        return true unless self.class._profiling_condition

        # Slow path: evaluate condition (only when needed)
        Axn::Core::Flow::Handlers::Invoker.call(
          action: self,
          handler: self.class._profiling_condition,
          operation: "determining if profiling should run",
        )
      end

      def _ensure_vernier_available!
        return if defined?(Vernier) && Vernier.is_a?(Module)

        begin
          require "vernier"
        rescue LoadError
          raise LoadError, <<~ERROR
            Vernier profiler is not available. To use profiling, add 'vernier' to your Gemfile:

              gem 'vernier', '~> 0.1'

            Then run: bundle install
          ERROR
        end
      end
    end
  end
end
