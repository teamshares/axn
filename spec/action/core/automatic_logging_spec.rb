# frozen_string_literal: true

require "spec_helper"

RSpec.describe Action::Core::AutomaticLogging do
  describe "automatic logging" do
    let(:log_messages) { [] }

    before do
      allow_any_instance_of(action).to receive(:info) do |_instance, message, **options|
        log_messages << { level: :info, message:, options: }
      end
      allow_any_instance_of(action).to receive(:debug) do |_instance, message, **options|
        log_messages << { level: :debug, message:, options: }
      end
      allow_any_instance_of(action).to receive(:warn) do |_instance, message, **options|
        log_messages << { level: :warn, message:, options: }
      end
    end

    context "when action succeeds" do
      let(:action) { build_action }

      it "logs before and after successful execution" do
        action.call

        expect(log_messages.length).to eq(2)

        before_log = log_messages.find { |log| log[:message].include?("About to execute") }
        after_log = log_messages.find { |log| log[:message].include?("Execution completed") }

        expect(before_log).to be_present
        expect(after_log).to be_present
        expect(after_log[:message]).to include("success")
      end

      it "includes timing information in after log" do
        action.call

        after_log = log_messages.find { |log| log[:message].include?("Execution completed") }
        expect(after_log[:message]).to match(/in \d+\.\d+ milliseconds/)
      end
    end

    context "when action fails" do
      let(:action) { build_action { def call = fail!("Something went wrong") } }

      it "logs before and after failed execution" do
        action.call

        expect(log_messages.length).to eq(2)

        before_log = log_messages.find { |log| log[:message].include?("About to execute") }
        after_log = log_messages.find { |log| log[:message].include?("Execution completed") }

        expect(before_log).to be_present
        expect(after_log).to be_present
        expect(after_log[:message]).to include("failure")
      end
    end

    context "when action raises exception" do
      let(:action) { build_action { def call = raise("Unexpected error") } }

      it "logs before and after exception" do
        pending("TODO: this will be fixed shortly")
        expect { action.call! }.to raise_error("Unexpected error")

        expect(log_messages.length).to eq(2)

        before_log = log_messages.find { |log| log[:message].include?("About to execute") }
        after_log = log_messages.find { |log| log[:message].include?("Execution completed") }

        expect(before_log).to be_present
        expect(after_log).to be_present
        expect(after_log[:message]).to include("exception")
      end
    end

    context "when action overrides autolog level" do
      let(:action) do
        build_action do
          def self.autolog_level
            :warn
          end
        end
      end

      it "uses the custom autolog level" do
        action.call

        expect(log_messages.length).to eq(2)

        # Verify that warn level was used instead of the default
        log_messages.each do |log|
          expect(log[:level]).to eq(:warn)
        end

        before_log = log_messages.find { |log| log[:message].include?("About to execute") }
        after_log = log_messages.find { |log| log[:message].include?("Execution completed") }

        expect(before_log).to be_present
        expect(after_log).to be_present
      end
    end

    context "when action uses default autolog level" do
      let(:action) { build_action }

      it "uses the default autolog level" do
        action.call

        expect(log_messages.length).to eq(2)

        # Verify that the default level (info) was used
        log_messages.each do |log|
          expect(log[:level]).to eq(:info)
        end

        before_log = log_messages.find { |log| log[:message].include?("About to execute") }
        after_log = log_messages.find { |log| log[:message].include?("Execution completed") }

        expect(before_log).to be_present
        expect(after_log).to be_present
      end
    end
  end
end
