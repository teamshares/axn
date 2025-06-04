# frozen_string_literal: true

RSpec.describe Action do
  describe "Hooks & Callbacks" do
    subject(:result) { action.call(should_fail:, should_raise:, should_after_raise:) }

    let(:action) do
      Class.new do
        include Action
        expects :should_fail, type: :boolean
        expects :should_raise, type: :boolean
        expects :should_after_raise, type: :boolean

        before { puts "before" }

        # Callbacks
        on_success { puts "on_success" }
        on_failure { puts "on_failure" }
        on_error { puts "on_error" }
        on_exception { puts "on_exception" }

        after do
          puts "after"
          raise "bad" if should_after_raise
        end

        def call
          puts "calling"
          raise "bad" if should_raise

          fail!("Custom failure message") if should_fail
        end
      end
    end

    let(:should_fail) { false }
    let(:should_raise) { false }
    let(:should_after_raise) { false }

    context "when ok?" do
      it "executes before, after, THEN on_success" do
        expect do
          expect(result).to be_ok
        end.to output("before\ncalling\nafter\non_success\n").to_stdout
      end
    end

    context "when exception raised" do
      let(:should_raise) { true }

      it "does not execute on_success" do
        expect do
          expect(result).not_to be_ok
        end.to output("before\ncalling\non_error\non_exception\n").to_stdout
      end
    end

    context "when exception raised in after hook" do
      let(:should_after_raise) { true }

      it "does not execute on_success" do
        expect do
          expect(result).not_to be_ok
        end.to output("before\ncalling\nafter\non_error\non_exception\n").to_stdout
      end
    end

    context "when fail! is called" do
      let(:should_fail) { true }

      it "executes on_failure" do
        expect do
          expect(result).not_to be_ok
        end.to output("before\ncalling\non_error\non_failure\n").to_stdout
      end
    end
  end
end
