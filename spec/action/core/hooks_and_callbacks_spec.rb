# frozen_string_literal: true

RSpec.describe Action do
  describe "Hooks & Callbacks" do
    subject(:result) { action.call(should_raise:, should_after_raise:) }

    let(:action) do
      Class.new do
        include Action
        expects :should_raise, type: :boolean
        expects :should_after_raise, type: :boolean

        before do
          puts "before"
        end

        on_success do
          puts "on_success"
        end

        after do
          puts "after"
          raise "bad" if should_after_raise
        end

        def call
          puts "calling"
          raise "bad" if should_raise
        end
      end
    end

    let(:should_raise) { false }
    let(:should_after_raise) { false }

    context "when ok?" do
      it "executes before, after, THEN on_success" do
        expect do
          expect(result).to be_ok
        end.to output("before\ncalling\nafter\non_success\n").to_stdout
      end
    end

    context "when not ok?" do
      let(:should_raise) { true }

      it "does not execute on_success" do
        expect do
          expect(result).not_to be_ok
        end.to output("before\ncalling\n").to_stdout
      end
    end

    context "when after hook fails" do
      let(:should_after_raise) { true }

      it "does not execute on_success" do
        expect do
          expect(result).not_to be_ok
        end.to output("before\ncalling\nafter\n").to_stdout
      end
    end
  end
end
