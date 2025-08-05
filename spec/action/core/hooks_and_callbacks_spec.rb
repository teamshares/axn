# frozen_string_literal: true

RSpec.describe Action do
  describe "Hooks & Callbacks" do
    subject(:result) { action.call(trigger:) }

    let(:action) do
      Class.new do
        include Action
        expects :trigger, type: Symbol

        before { puts "before" }

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
          when :raise then raise "bad"
          when :fail then fail!("Custom failure message")
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
        Class.new do
          include Action
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
        Class.new do
          include Action
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
  end
end
