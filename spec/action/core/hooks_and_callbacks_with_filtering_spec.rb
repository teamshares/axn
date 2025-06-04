# frozen_string_literal: true

RSpec.describe Action do
  describe "Hooks & Callbacks with filtering" do
    subject(:result) { action.call(trigger:, should_rescue:) }

    let(:trigger) { :ok }
    let(:should_rescue) { false }

    let(:action) do
      Class.new do
        include Action
        expects :trigger, type: Symbol
        expects :should_rescue, type: :boolean, default: false

        before { puts "before" }

        rescues -> { should_rescue } => ->(e) { puts "rescued: #{e.message}" }

        # Callbacks
        on_success { puts "on_success" }

        on_failure ->(e) { e.message == "SPECIFIC" } do |e|
          puts "on_failure: #{e.message}"
        end

        on_error ->(e) { e.message == "ERROR" } do |e|
          puts "on_error: #{e.message}"
        end

        on_exception ArgumentError do |e|
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

    context "when ok?" do
      let(:trigger) { :ok }

      it do
        expect do
          expect(result).to be_ok
        end.to output("before\ncalling\nafter\non_success\n").to_stdout
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

        context "when rescues" do
          let(:should_rescue) { true }

          it "does not call on_exception" do
            expect do
              expect(result).not_to be_ok
            end.to output("before\ncalling\n").to_stdout
          end
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
  end
end
