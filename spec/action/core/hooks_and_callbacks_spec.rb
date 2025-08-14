# frozen_string_literal: true

RSpec.describe Action do
  describe "Hooks & Callbacks" do
    subject(:result) { action.call(trigger:, should_rescue:) }

    let(:trigger) { :ok }
    let(:should_rescue) { false }

    let(:action) do
      build_action do
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
        build_action do
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
        build_action do
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
        build_action do
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
          build_action do
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
        it "raises ArgumentError for on_success" do
          expect do
            build_action do
              on_success(if: :condition?, unless: :other_condition?) { puts "success" }
            end
          end.to raise_error(ArgumentError, /on_success cannot be called with both :if and :unless/)
        end

        it "raises ArgumentError for on_failure" do
          expect do
            build_action do
              on_failure(if: :condition?, unless: :other_condition?) { puts "failure" }
            end
          end.to raise_error(ArgumentError, /on_failure cannot be called with both :if and :unless/)
        end

        it "raises ArgumentError for on_exception" do
          expect do
            build_action do
              on_exception(if: :condition?, unless: :other_condition?) { puts "exception" }
            end
          end.to raise_error(ArgumentError, /on_exception cannot be called with both :if and :unless/)
        end

        it "raises ArgumentError for on_error" do
          expect do
            build_action do
              on_error(if: :condition?, unless: :other_condition?) { puts "error" }
            end
          end.to raise_error(ArgumentError, /on_error cannot be called with both :if and :unless/)
        end
      end
    end

    context "inheritance" do
      let(:parent_class) do
        build_action do
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
end
