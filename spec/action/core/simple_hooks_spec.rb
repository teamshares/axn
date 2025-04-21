# frozen_string_literal: true

RSpec.describe Action do
  describe "Hooks & Rollback" do
    subject(:result) { action.call(should_raise:) }

    let(:action) do
      Class.new do
        include Action
        expects :should_raise, allow_blank: true

        before do
          puts "before"
        end

        after do
          puts "after"
        end

        # TODO: maybe don't offer around, and/or ensure it doesn't get raised up above our internal hooks
        # around do |block|
        #   puts "around-before"
        #   block.call
        #   puts "around-after"
        # end

        def call
          puts "calling"
          raise "bad" if should_raise
        end

        def rollback
          puts "rolling back"
        end
      end
    end

    context "when ok?" do
      let(:should_raise) { false }

      it "executes before and after" do
        expect do
          expect(result).to be_ok
        end.to output("before\ncalling\nafter\n").to_stdout
      end
    end

    context "when not ok?" do
      let(:should_raise) { true }

      it "executes rollback" do
        pending "TODO: implement #rollback"

        expect do
          expect(result).not_to be_ok
        end.to output("before\ncalling\nrolling back\n").to_stdout
      end
    end
  end
end
