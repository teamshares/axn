# frozen_string_literal: true

require "pathname"

module RuboCop
  module Cop
    module Axn
      # This cop enforces that when calling Axns from within other Axns,
      # you must either use `call!` (with the bang) or check `result.ok?`.
      #
      # The cop only applies to files in configured target directories to avoid
      # false positives on standard library classes and other non-action classes.
      #
      # @example
      #   # bad
      #   class OuterAction
      #     include Axn
      #     def call
      #       InnerAction.call(param: "value")  # Missing result check
      #     end
      #   end
      #
      #   # good
      #   class OuterAction
      #     include Axn
      #     def call
      #       result = InnerAction.call(param: "value")
      #       return result unless result.ok?
      #       # Process successful result...
      #     end
      #   end
      #
      #   # also good
      #   class OuterAction
      #     include Axn
      #     def call
      #       InnerAction.call!(param: "value")  # Using call! ensures exceptions bubble up
      #     end
      #   end
      #
      # @example TargetDirectories configuration
      #   # .rubocop.yml
      #   Axn/UncheckedResult:
      #     TargetDirectories:
      #       - app/actions
      #       - app/services
      #       - lib/actions
      #       - lib/services
      #
      # rubocop:disable Metrics/ClassLength
      class UncheckedResult < RuboCop::Cop::Base
        extend RuboCop::Cop::AutoCorrector

        MSG = "Use `call!` or check `result.ok?` when calling Axns from within Axns"

        # Configuration options
        def check_nested?
          cop_config["CheckNested"] != false
        end

        def check_non_nested?
          cop_config["CheckNonNested"] != false
        end

        def target_directories
          cop_config["TargetDirectories"] || default_target_directories
        end

        def default_target_directories
          %w[app/actions app/services lib/actions lib/services]
        end

        # Track whether we're inside an Axn class and its call method
        def_node_search :action_class?, <<~PATTERN
          (class _ (const nil? :Axn) ...)
        PATTERN

        def_node_search :includes_action?, <<~PATTERN
          (send nil? :include (const nil? :Axn))
        PATTERN

        def_node_search :call_method?, <<~PATTERN
          (def :call ...)
        PATTERN

        def_node_search :axn_call?, <<~PATTERN
          (send (const _ _) :call ...)
        PATTERN

        def_node_search :likely_axn_class?, <<~PATTERN
          (const _ _)
        PATTERN

        def_node_search :bang_call?, <<~PATTERN
          (send (const _ _) :call! ...)
        PATTERN

        def_node_search :result_assignment?, <<~PATTERN
          (lvasgn _ (send (const _ _) :call ...))
        PATTERN

        def_node_search :result_ok_check?, <<~PATTERN
          (send (send _ :result) :ok?)
        PATTERN

        def_node_search :result_failed_check?, <<~PATTERN
          (send (send _ :result) :failed?)
        PATTERN

        def_node_search :result_error_check?, <<~PATTERN
          (send (send _ :result) :error)
        PATTERN

        def_node_search :result_exception_check?, <<~PATTERN
          (send (send _ :result) :exception)
        PATTERN

        def_node_search :return_with_result?, <<~PATTERN
          (return (send _ :result))
        PATTERN

        def_node_search :expose_with_result?, <<~PATTERN
          (send nil? :expose ...)
        PATTERN

        def_node_search :result_passed_to_method?, <<~PATTERN
          (send nil? :result ...)
        PATTERN

        def on_send(node)
          # Fast pattern matches first
          return unless axn_call?(node)
          return if bang_call?(node)

          # Directory check - expensive but can eliminate many files early
          return unless in_target_directory?(node)

          # AST traversal checks
          return unless inside_axn_call_method?(node)

          # Check if we should process this call based on configuration
          is_inside_action = inside_action_context?(node)
          return unless (is_inside_action && check_nested?) || (!is_inside_action && check_non_nested?)

          # Most expensive check last - traverses entire method body
          return if result_properly_handled?(node)

          add_offense(node, message: MSG)
        end

        private

        def in_target_directory?(node)
          # Get the file path of the current node
          file_path = node.location.expression.source_buffer.name
          return false unless file_path

          # Convert to relative path from project root
          relative_path = relative_path_from_project_root(file_path)
          return false unless relative_path

          # Check if the file is in any of the target directories
          target_directories.any? do |target_dir|
            relative_path.start_with?("#{target_dir}/") || relative_path == target_dir
          end
        end

        def relative_path_from_project_root(file_path)
          # Try to find the project root by looking for common markers
          current_path = File.expand_path(file_path)

          # Look for project root markers
          project_root_markers = %w[.git Gemfile Rakefile package.json]

          # Walk up the directory tree to find project root
          dir = File.dirname(current_path)
          while dir != "/" && dir != File.dirname(dir)
            if project_root_markers.any? { |marker| File.exist?(File.join(dir, marker)) }
              return Pathname.new(current_path).relative_path_from(Pathname.new(dir)).to_s
            end

            dir = File.dirname(dir)
          end

          # If we can't find a project root, just return the filename
          File.basename(file_path)
        end

        def inside_axn_call_method?(node)
          # Check if we're inside a call method of an Axn class
          current_node = node
          while current_node.parent
            current_node = current_node.parent

            # Check if we're inside a def :call
            next unless call_method?(current_node) && current_node.method_name == :call

            # Now check if this class includes Axn
            class_node = find_enclosing_class(current_node)
            return includes_action?(class_node) if class_node
          end
          false
        rescue StandardError => _e
          # If there's any error in the analysis, assume we're not in an Axn call method
          # This prevents the cop from crashing on complex or malformed code
          false
        end

        def inside_action_context?(node)
          # Check if this Axn call is inside an Axn class's call method
          current_node = node
          while current_node.parent
            current_node = current_node.parent

            # Check if we're inside a def :call
            next unless call_method?(current_node) && current_node.method_name == :call

            # Now check if this class includes Axn
            class_node = find_enclosing_class(current_node)
            return true if class_node && includes_action?(class_node)
          end
          false
        rescue StandardError => _e
          false
        end

        def find_enclosing_class(node)
          current_node = node
          while current_node.parent
            current_node = current_node.parent
            return current_node if current_node.type == :class
          end
          nil
        rescue StandardError => _e
          # If there's any error in the analysis, return nil
          nil
        end

        def result_properly_handled?(node)
          # Check if the result is assigned to a variable
          parent = node.parent
          return false unless parent&.type == :lvasgn

          result_var = parent.children[0]

          # Look for proper result handling in the method
          method_body = find_enclosing_method_body(node)
          return false unless method_body

          # Check if result.ok? is checked
          return true if result_ok_check_in_method?(method_body, result_var)

          # Check if result.failed? is checked
          return true if result_failed_check_in_method?(method_body, result_var)

          # Check if result.error is accessed
          return true if result_error_check_in_method?(method_body, result_var)

          # Check if result.exception is accessed
          return true if result_exception_check_in_method?(method_body, result_var)

          # Check if result is returned
          return true if result_returned_in_method?(method_body, result_var)

          # Check if result is used in expose
          return true if result_used_in_expose?(method_body, result_var)

          # Check if result is passed to another method
          return true if result_passed_to_method?(method_body, result_var)

          false
        rescue StandardError => _e
          # If there's any error in the analysis, assume the result is not properly handled
          # This prevents the cop from crashing on complex or malformed code
          false
        end

        def find_enclosing_method_body(node)
          current_node = node
          while current_node.parent
            current_node = current_node.parent
            if current_node.type == :def && current_node.method_name == :call
              return current_node.children[2] # The method body
            end
          end
          nil
        end

        def result_ok_check_in_method?(method_body, result_var)
          method_body.each_descendant(:send) do |send_node|
            next unless send_node.method_name == :ok?

            # Check if this is any_variable.ok?
            receiver = send_node.children[0]
            return true if receiver&.type == :lvar && receiver.children[0] == result_var
          end
          false
        end

        def result_failed_check_in_method?(method_body, result_var)
          method_body.each_descendant(:send) do |send_node|
            next unless send_node.method_name == :failed?

            receiver = send_node.children[0]
            return true if receiver&.type == :lvar && receiver.children[0] == result_var
          end
          false
        end

        def result_error_check_in_method?(method_body, result_var)
          method_body.each_descendant(:send) do |send_node|
            next unless send_node.method_name == :error

            receiver = send_node.children[0]
            return true if receiver&.type == :lvar && receiver.children[0] == result_var
          end
          false
        end

        def result_exception_check_in_method?(method_body, result_var)
          method_body.each_descendant(:send) do |send_node|
            next unless send_node.method_name == :exception

            receiver = send_node.children[0]
            return true if receiver&.type == :lvar && receiver.children[0] == result_var
          end
          false
        end

        def result_returned_in_method?(method_body, result_var)
          # Check for explicit return statements
          method_body.each_descendant(:return) do |return_node|
            return_value = return_node.children[0]
            return true if return_value&.type == :lvar && return_value.children[0] == result_var
          end

          # Check for implicit return (last statement in method)
          last_statement = if method_body.type == :begin
                             method_body.children.last
                           else
                             method_body
                           end

          return true if last_statement&.type == :lvar && last_statement.children[0] == result_var

          false
        end

        def result_used_in_expose?(method_body, result_var)
          method_body.each_descendant(:send) do |send_node|
            next unless send_node.method_name == :expose

            # Check if any argument references the result variable
            # send_node.children[0] is the receiver (nil for self)
            # send_node.children[1] is the method name (:expose)
            # send_node.children[2..] are the actual arguments
            send_node.children[2..].each do |arg|
              # Handle hash arguments in expose calls
              if arg.type == :hash
                arg.children.each do |pair|
                  next unless pair.type == :pair

                  value = pair.children[1]
                  return true if value&.type == :lvar && value.children[0] == result_var
                end
              elsif arg&.type == :lvar && arg.children[0] == result_var
                return true
              end
            end
          end
          false
        end

        def result_passed_to_method?(method_body, result_var)
          method_body.each_descendant(:send) do |send_node|
            next if send_node.method_name == :result # Skip result method calls
            next if send_node.method_name == :ok? # Skip result.ok? calls
            next if send_node.method_name == :failed? # Skip result.failed? calls
            next if send_node.method_name == :error # Skip result.error calls
            next if send_node.method_name == :exception # Skip result.exception calls

            # Check if result is passed as an argument
            # send_node.children[0] is the receiver
            # send_node.children[1] is the method name
            # send_node.children[2..] are the actual arguments
            send_node.children[2..].each do |arg|
              return true if arg&.type == :lvar && arg.children[0] == result_var
            end
          end
          false
        end
        # rubocop:enable Metrics/ClassLength
      end
    end
  end
end
