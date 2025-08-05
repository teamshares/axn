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
        end.to output("before\ncalling\non_success\nafter\n").to_stdout
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
        end.to output("before\ncalling\non_success\nafter\non_error\non_exception\n").to_stdout
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
  end
end
