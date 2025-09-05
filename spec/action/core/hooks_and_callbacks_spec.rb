# frozen_string_literal: true

RSpec.describe Axn do
  describe "Hooks & Callbacks" do
    subject(:result) { action.call(trigger:, should_rescue:) }

    let(:trigger) { :ok }
    let(:should_rescue) { false }

    # Shared examples for testing symbol method handlers
    shared_examples "symbol method handler" do |callback_type, trigger_value, expected_output|
      context "when #{trigger_value} is triggered" do
        let(:trigger) { trigger_value }

        it "calls the appropriate #{callback_type} handlers" do
          expect do
            if trigger_value == :ok
              expect(action.call(trigger:)).to be_ok
            else
              expect(action.call(trigger:)).not_to be_ok
            end
          end.to output(expected_output).to_stdout
        end
      end
    end

    # Shared examples for testing conditional filtering
    shared_examples "conditional filtering" do |callback_type, should_skip_value, expected_output|
      context "when should_skip is #{should_skip_value}" do
        let(:should_skip) { should_skip_value }

        context "on #{callback_type}" do
          let(:trigger) { callback_type == :success ? :ok : :raise }

          it "#{should_skip_value ? "does not execute" : "executes"} the #{callback_type} callback" do
            expect do
              if callback_type == :success
                expect(action.call(trigger:, should_skip:)).to be_ok
              else
                expect(action.call(trigger:, should_skip:)).not_to be_ok
              end
            end.to output(expected_output).to_stdout
          end
        end
      end
    end

    let(:action) do
      build_axn do
        expects :trigger, type: Symbol
        expects :should_rescue, type: :boolean, default: false

        before { puts "before" }

        error ->(e) { "rescued: #{e.message}" }, if: -> { should_rescue }

        # Callbacks
        on_success { puts "on_success" }
        on_failure { puts "on_failure" }
        on_error { puts "on_error" }
        on_exception { puts "on_exception" }

        after do
          puts "after"
          raise "bad" if trigger == :raise_from_after
        end

        def call
          puts "calling"

          case trigger
          when :raise_argument_error
            raise ArgumentError, "SPECIFIC"
          when :raise
            raise "bad"
          when :raise_with_specific_error
            raise "ERROR"
          when :fail_with_specific_message
            fail!("SPECIFIC")
          when :fail_with_specific_error
            fail!("ERROR")
          when :fail
            fail!("Custom failure message")
          end
        end
      end
    end

    context "when ok?" do
      let(:trigger) { :ok }

      it do
        expect do
          expect(result).to be_ok
        end.to output("before\ncalling\nafter\non_success\n").to_stdout
      end
    end

    context "when exception raised" do
      let(:trigger) { :raise }

      it do
        expect do
          expect(result).not_to be_ok
        end.to output("before\ncalling\non_error\non_exception\n").to_stdout
      end
    end

    context "when exception raised in after hook" do
      let(:trigger) { :raise_from_after }

      it do
        expect do
          expect(result).not_to be_ok
        end.to output("before\ncalling\nafter\non_error\non_exception\n").to_stdout
      end
    end

    context "when fail! is called" do
      let(:trigger) { :fail }

      it do
        expect do
          expect(result).not_to be_ok
        end.to output("before\ncalling\non_error\non_failure\n").to_stdout
      end
    end

    context "when after hook fails" do
      let(:action) do
        build_axn do
          expects :trigger, type: Symbol

          before { puts "before" }

          on_success { puts "on_success" }

          after do
            puts "after"
            raise "after hook failed" if trigger == :fail_after
          end

          def call
            puts "calling"
          end
        end
      end

      let(:trigger) { :fail_after }

      it "does not call on_success when after hook fails" do
        expect do
          expect(result).not_to be_ok
        end.to output("before\ncalling\nafter\n").to_stdout
      end
    end

    context "when on_success callback fails" do
      let(:action) do
        build_axn do
          expects :trigger, type: Symbol

          before { puts "before" }

          on_success { puts "first_success" }
          on_success { puts "second_success" }
          on_success { raise "third_success_failed" }
          on_success { puts "fourth_success" }

          after { puts "after" }

          def call
            puts "calling"
          end
        end
      end

      let(:trigger) { :ok }

      it "continues running other on_success callbacks even if one fails" do
        expect do
          expect(result).to be_ok
        end.to output("before\ncalling\nafter\nfourth_success\nsecond_success\nfirst_success\n").to_stdout
      end
    end

    context "with filtering" do
      let(:action) do
        build_axn do
          expects :trigger, type: Symbol
          expects :should_rescue, type: :boolean, default: false

          before { puts "before" }

          error ->(e) { "rescued: #{e.message}" }, if: -> { should_rescue }

          # Callbacks with filters
          on_success { puts "on_success" }

          on_failure(if: ->(e) { e.message == "SPECIFIC" }) do |e|
            puts "on_failure: #{e.message}"
          end

          on_error(if: ->(e) { e.message == "ERROR" }) do |e|
            puts "on_error: #{e.message}"
          end

          on_exception(if: ArgumentError) do |e|
            puts "on_exception: #{e.message}"
          end

          after do
            puts "after"
          end

          def call
            puts "calling"

            case trigger
            when :raise_argument_error
              raise ArgumentError, "SPECIFIC"
            when :raise
              raise "bad"
            when :raise_with_specific_error
              raise "ERROR"
            when :fail_with_specific_message
              fail!("SPECIFIC")
            when :fail_with_specific_error
              fail!("ERROR")
            when :fail
              fail!("Custom failure message")
            end
          end
        end
      end

      context "on_failure" do
        let(:trigger) { :fail }

        it do
          expect do
            expect(result).not_to be_ok
          end.to output("before\ncalling\n").to_stdout
        end

        context "when matches filter" do
          let(:trigger) { :fail_with_specific_message }

          it do
            expect do
              expect(result).not_to be_ok
            end.to output("before\ncalling\non_failure: SPECIFIC\n").to_stdout
          end
        end
      end

      context "on_exception" do
        let(:trigger) { :raise }

        it do
          expect do
            expect(result).not_to be_ok
          end.to output("before\ncalling\n").to_stdout
        end

        context "when matches filter" do
          let(:trigger) { :raise_argument_error }

          it do
            expect do
              expect(result).not_to be_ok
            end.to output("before\ncalling\non_exception: SPECIFIC\n").to_stdout
          end
        end
      end

      context "on_error" do
        context "when raise matches filter" do
          let(:trigger) { :raise_with_specific_error }

          it do
            expect do
              expect(result).not_to be_ok
            end.to output("before\ncalling\non_error: ERROR\n").to_stdout
          end
        end

        context "when fail! matches filter" do
          let(:trigger) { :fail_with_specific_error }

          it do
            expect do
              expect(result).not_to be_ok
            end.to output("before\ncalling\non_error: ERROR\n").to_stdout
          end
        end
      end

      context "with unless filtering" do
        let(:action) do
          build_axn do
            expects :trigger, type: Symbol
            expects :should_skip, type: :boolean, default: false

            before { puts "before" }

            on_success(unless: :should_skip?) { puts "on_success_unless" }
            on_failure(unless: :should_skip?) { puts "on_failure_unless" }
            on_exception(unless: :should_skip?) { puts "on_exception_unless" }
            on_error(unless: :should_skip?) { puts "on_error_unless" }

            after do
              puts "after"
            end

            def call
              puts "calling"
              case trigger
              when :raise
                raise "bad"
              when :fail
                fail!("Custom failure message")
              end
            end

            def should_skip?
              should_skip
            end
          end
        end

        context "when should_skip is false" do
          let(:should_skip) { false }

          context "on success" do
            let(:trigger) { :ok }

            it "executes the callback" do
              expect do
                expect(action.call(trigger:, should_skip:)).to be_ok
              end.to output("before\ncalling\nafter\non_success_unless\n").to_stdout
            end
          end

          context "on failure" do
            let(:trigger) { :fail }

            it "executes the callback" do
              expect do
                expect(action.call(trigger:, should_skip:)).not_to be_ok
              end.to output("before\ncalling\non_error_unless\non_failure_unless\n").to_stdout
            end
          end

          context "on exception" do
            let(:trigger) { :raise }

            it "executes the callback" do
              expect do
                expect(action.call(trigger:, should_skip:)).not_to be_ok
              end.to output("before\ncalling\non_error_unless\non_exception_unless\n").to_stdout
            end
          end
        end

        context "when should_skip is true" do
          let(:should_skip) { true }

          context "on success" do
            let(:trigger) { :ok }

            it "does not execute the callback" do
              expect do
                expect(action.call(trigger:, should_skip:)).to be_ok
              end.to output("before\ncalling\nafter\n").to_stdout
            end
          end

          context "on failure" do
            let(:trigger) { :fail }

            it "does not execute the callback" do
              expect do
                expect(action.call(trigger:, should_skip:)).not_to be_ok
              end.to output("before\ncalling\n").to_stdout
            end
          end

          context "on exception" do
            let(:trigger) { :raise }

            it "does not execute the callback" do
              expect do
                expect(action.call(trigger:, should_skip:)).not_to be_ok
              end.to output("before\ncalling\n").to_stdout
            end
          end
        end
      end

      context "raises error when both if and unless provided" do
        %i[success failure exception error].each do |callback_type|
          it "raises ArgumentError for on_#{callback_type}" do
            expect do
              build_axn do
                public_send("on_#{callback_type}", if: :condition?, unless: :other_condition?) { puts callback_type }
              end
            end.to raise_error(ArgumentError, /on_#{callback_type} cannot be called with both :if and :unless/)
          end
        end
      end

      context "with symbol method auto-expansion in conditional callbacks" do
        let(:action) do
          build_axn do
            expects :trigger, type: Symbol
            expects :execute_flag, type: :boolean, default: false
            expects :skip_flag, type: :boolean, default: false

            # Test if: with symbol methods
            on_success :handle_success, if: :should_execute_predicate?
            on_failure :handle_failure, if: :should_execute_predicate?
            on_error :handle_error, if: :should_execute_predicate?
            on_exception :handle_exception, if: :should_execute_predicate?

            # Test unless: with symbol methods
            on_success :handle_success_unless, unless: :should_skip_predicate?
            on_failure :handle_failure_unless, unless: :should_skip_predicate?
            on_error :handle_error_unless, unless: :should_skip_predicate?
            on_exception :handle_exception_unless, unless: :should_skip_predicate?

            def call
              case trigger
              when :raise
                raise "test exception"
              when :fail
                fail!("test failure")
              when :ok
                # success
              end
            end

            # Conditional predicate methods - use the expects parameters
            def should_execute_predicate?
              execute_flag
            end

            def should_skip_predicate?
              skip_flag
            end

            # Handler methods for if: conditions
            def handle_success
              puts "success_if_executed"
            end

            def handle_failure
              puts "failure_if_executed"
            end

            def handle_error
              puts "error_if_executed"
            end

            def handle_exception
              puts "exception_if_executed"
            end

            # Handler methods for unless: conditions
            def handle_success_unless
              puts "success_unless_executed"
            end

            def handle_failure_unless
              puts "failure_unless_executed"
            end

            def handle_error_unless
              puts "error_unless_executed"
            end

            def handle_exception_unless
              puts "exception_unless_executed"
            end
          end
        end

        context "when execute_flag is true and skip_flag is false" do
          let(:execute_flag) { true }
          let(:skip_flag) { false }

          context "on success" do
            let(:trigger) { :ok }

            it "executes both if: and unless: callbacks" do
              expect do
                expect(action.call(trigger:, execute_flag:, skip_flag:)).to be_ok
              end.to output("success_unless_executed\nsuccess_if_executed\n").to_stdout
            end
          end

          context "on failure" do
            let(:trigger) { :fail }

            it "executes both if: and unless: callbacks" do
              expect do
                expect(action.call(trigger:, execute_flag:, skip_flag:)).not_to be_ok
              end.to output("error_unless_executed\nerror_if_executed\nfailure_unless_executed\nfailure_if_executed\n").to_stdout
            end
          end

          context "on exception" do
            let(:trigger) { :raise }

            it "executes both if: and unless: callbacks" do
              expect do
                expect(action.call(trigger:, execute_flag:, skip_flag:)).not_to be_ok
              end.to output("error_unless_executed\nerror_if_executed\nexception_unless_executed\nexception_if_executed\n").to_stdout
            end
          end
        end

        context "when execute_flag is false and skip_flag is false" do
          let(:execute_flag) { false }
          let(:skip_flag) { false }

          context "on success" do
            let(:trigger) { :ok }

            it "executes only unless: callbacks" do
              expect do
                expect(action.call(trigger:, execute_flag:, skip_flag:)).to be_ok
              end.to output("success_unless_executed\n").to_stdout
            end
          end

          context "on failure" do
            let(:trigger) { :fail }

            it "executes only unless: callbacks" do
              expect do
                expect(action.call(trigger:, execute_flag:, skip_flag:)).not_to be_ok
              end.to output("error_unless_executed\nfailure_unless_executed\n").to_stdout
            end
          end

          context "on exception" do
            let(:trigger) { :raise }

            it "executes only unless: callbacks" do
              expect do
                expect(action.call(trigger:, execute_flag:, skip_flag:)).not_to be_ok
              end.to output("error_unless_executed\nexception_unless_executed\n").to_stdout
            end
          end
        end

        context "when execute_flag is true and skip_flag is true" do
          let(:execute_flag) { true }
          let(:skip_flag) { true }

          context "on success" do
            let(:trigger) { :ok }

            it "executes only if: callbacks" do
              expect do
                expect(action.call(trigger:, execute_flag:, skip_flag:)).to be_ok
              end.to output("success_if_executed\n").to_stdout
            end
          end

          context "on failure" do
            let(:trigger) { :fail }

            it "executes only if: callbacks" do
              expect do
                expect(action.call(trigger:, execute_flag:, skip_flag:)).not_to be_ok
              end.to output("error_if_executed\nfailure_if_executed\n").to_stdout
            end
          end

          context "on exception" do
            let(:trigger) { :raise }

            it "executes only if: callbacks" do
              expect do
                expect(action.call(trigger:, execute_flag:, skip_flag:)).not_to be_ok
              end.to output("error_if_executed\nexception_if_executed\n").to_stdout
            end
          end
        end

        context "when execute_flag is false and skip_flag is true" do
          let(:execute_flag) { false }
          let(:skip_flag) { true }

          context "on success" do
            let(:trigger) { :ok }

            it "executes no callbacks" do
              expect do
                expect(action.call(trigger:, execute_flag:, skip_flag:)).to be_ok
              end.to output("").to_stdout
            end
          end

          context "on failure" do
            let(:trigger) { :fail }

            it "executes no callbacks" do
              expect do
                expect(action.call(trigger:, execute_flag:, skip_flag:)).not_to be_ok
              end.to output("").to_stdout
            end
          end

          context "on exception" do
            let(:trigger) { :raise }

            it "executes no callbacks" do
              expect do
                expect(action.call(trigger:, execute_flag:, skip_flag:)).not_to be_ok
              end.to output("").to_stdout
            end
          end
        end
      end
    end

    context "with symbol method handlers" do
      let(:action) do
        build_axn do
          expects :trigger, type: Symbol

          # Test on_error with symbol method names
          on_error :handle_error_no_args
          on_error :handle_error_positional, if: ArgumentError
          on_error :handle_error_keyword, if: TypeError

          # Test other callbacks with symbol method names
          on_success :handle_success_no_args
          on_success :handle_success_positional
          on_success :handle_success_keyword

          on_failure :handle_failure_no_args
          on_failure :handle_failure_positional, if: ->(e) { e.message == "SPECIFIC" }

          on_exception :handle_exception_no_args
          on_exception :handle_exception_positional, if: ZeroDivisionError

          def call
            case trigger
            when :raise_argument_error
              raise ArgumentError, "ARGUMENT_ERROR"
            when :raise_type_error
              raise TypeError, "TYPE_ERROR"
            when :raise_zero_division
              raise ZeroDivisionError, "ZERO_DIVISION"
            when :fail_specific
              fail!("SPECIFIC")
            when :fail_generic
              fail!("GENERIC")
            end
          end

          # Error handlers
          def handle_error_no_args
            @error_handled = true
            puts "error_handled_no_args"
          end

          def handle_error_positional(exception)
            @error_handled = true
            puts "error_handled_positional: #{exception.message}"
          end

          def handle_error_keyword(exception:)
            @error_handled = true
            puts "error_handled_keyword: #{exception.message}"
          end

          # Success handlers
          def handle_success_no_args
            @success_handled = true
            puts "success_handled_no_args"
          end

          def handle_success_positional
            @success_handled = true
            puts "success_handled_positional: no_args"
          end

          def handle_success_keyword
            @success_handled = true
            puts "success_handled_keyword: no_args"
          end

          # Failure handlers
          def handle_failure_no_args
            @failure_handled = true
            puts "failure_handled_no_args"
          end

          def handle_failure_positional(exception)
            @failure_handled = true
            puts "failure_handled_positional: #{exception.message}"
          end

          # Exception handlers
          def handle_exception_no_args
            @exception_handled = true
            puts "exception_handled_no_args"
          end

          def handle_exception_positional(exception)
            @exception_handled = true
            puts "exception_handled_positional: #{exception.message}"
          end
        end
      end

      context "on_error with symbol methods" do
        include_examples "symbol method handler", :error, :ok,
                         "success_handled_keyword: no_args\nsuccess_handled_positional: no_args\nsuccess_handled_no_args\n"
        include_examples "symbol method handler", :error, :raise_argument_error,
                         "error_handled_positional: ARGUMENT_ERROR\nerror_handled_no_args\nexception_handled_no_args\n"
        include_examples "symbol method handler", :error, :raise_type_error,
                         "error_handled_keyword: TYPE_ERROR\nerror_handled_no_args\nexception_handled_no_args\n"
        include_examples "symbol method handler", :error, :raise_zero_division,
                         "error_handled_no_args\nexception_handled_positional: ZERO_DIVISION\nexception_handled_no_args\n"
      end

      context "on_failure with symbol methods" do
        include_examples "symbol method handler", :failure, :fail_specific,
                         "error_handled_no_args\nfailure_handled_positional: SPECIFIC\nfailure_handled_no_args\n"
        include_examples "symbol method handler", :failure, :fail_generic, "error_handled_no_args\nfailure_handled_no_args\n"
      end

      context "on_success with symbol methods" do
        include_examples "symbol method handler", :success, :ok,
                         "success_handled_keyword: no_args\nsuccess_handled_positional: no_args\nsuccess_handled_no_args\n"
      end

      context "on_exception with symbol methods" do
        include_examples "symbol method handler", :exception, :raise_zero_division,
                         "error_handled_no_args\nexception_handled_positional: ZERO_DIVISION\nexception_handled_no_args\n"
      end

      context "with conditional filtering on symbol methods" do
        let(:action) do
          build_axn do
            expects :trigger, type: Symbol
            expects :should_skip, type: :boolean, default: false

            on_error :handle_error, unless: :should_skip?
            on_success :handle_success, if: :should_proceed?

            def call
              case trigger
              when :raise
                raise "bad"
              when :ok
                # success
              end
            end

            def handle_error
              puts "error_handled"
            end

            def handle_success
              puts "success_handled"
            end

            def should_skip?
              should_skip
            end

            def should_proceed?
              !should_skip
            end
          end
        end

        context "when should_skip is false" do
          include_examples "conditional filtering", :success, false, "success_handled\n"
          include_examples "conditional filtering", :error, false, "error_handled\n"
        end

        context "when should_skip is true" do
          include_examples "conditional filtering", :success, true, ""
          include_examples "conditional filtering", :error, true, ""
        end
      end
    end

    context "before block with default_error" do
      let(:action) do
        build_axn do
          expects :should_fail, allow_blank: true, default: false

          before do
            fail! "#{default_error}: some detail" if should_fail
          end

          def call
            # The before hook will run before this
          end
        end
      end

      it "can access default_error within before hook blocks" do
        expect(action.call).to be_ok
      end

      it "fails with default_error when should_fail is true" do
        result = action.call(should_fail: true)
        expect(result).not_to be_ok
        expect(result.error).to include("some detail")
      end

      it "succeeds when should_fail is false" do
        expect { action.call(should_fail: false) }.not_to raise_error
      end
    end

    context "inheritance" do
      let(:parent_class) do
        build_axn do
          expects :trigger, type: Symbol

          before { puts "parent_before" }
          on_success { puts "parent_on_success" }
          after { puts "parent_after" }

          def call
            puts "parent_calling"
          end
        end
      end

      let(:child_class) do
        Class.new(parent_class) do
          before { puts "child_before" }
          on_success { puts "child_on_success" }
          after { puts "child_after" }

          def call
            puts "child_calling"
          end
        end
      end

      let(:action) { child_class }

      it "runs on_success in child-first order" do
        expect do
          expect(action.call(trigger: :ok)).to be_ok
        end.to output("parent_before\nchild_before\nchild_calling\nparent_after\nchild_after\nchild_on_success\nparent_on_success\n").to_stdout
      end
    end
  end

  context "with prebuilt descriptors" do
    let(:action) do
      build_axn do
        on_success Axn::Core::Flow::Handlers::Descriptors::CallbackDescriptor.build(handler: -> { puts "success from descriptor" })
        on_error Axn::Core::Flow::Handlers::Descriptors::CallbackDescriptor.build(handler: -> { puts "error from descriptor" })
      end
    end

    it "supports prebuilt descriptors" do
      expect do
        expect(action.call).to be_ok
      end.to output("success from descriptor\n").to_stdout
    end

    it "raises error when combining descriptor with kwargs" do
      expect do
        build_axn do
          on_success Axn::Core::Flow::Handlers::Descriptors::CallbackDescriptor.build(handler: -> { puts "success" }), if: -> { true }
        end
      end.to raise_error(ArgumentError, "Cannot pass additional configuration with prebuilt descriptor")
    end
  end
end
