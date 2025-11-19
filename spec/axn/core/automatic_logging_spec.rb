# frozen_string_literal: true

RSpec.describe Axn::Core::AutomaticLogging do
  describe "automatic logging" do
    let(:log_messages) { [] }

    context "when action succeeds" do
      let(:action) { build_axn }

      before do
        allow(action).to receive(:info) do |message, **options|
          log_messages << { level: :info, message:, options: }
        end
      end

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
      let(:action) { build_axn { def call = fail!("Something went wrong") } }

      before do
        allow(action).to receive(:info) do |message, **options|
          log_messages << { level: :info, message:, options: }
        end
      end

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
      let(:action) { build_axn { def call = raise("Unexpected error") } }

      before do
        allow(action).to receive(:info) do |message, **options|
          log_messages << { level: :info, message:, options: }
        end
      end

      it "logs before and after exception" do
        expect { action.call! }.to raise_error("Unexpected error")

        expect(log_messages.length).to eq(2)

        before_log = log_messages.find { |log| log[:message].include?("About to execute") }
        after_log = log_messages.find { |log| log[:message].include?("Execution completed") }

        expect(before_log).to be_present
        expect(after_log).to be_present
        expect(after_log[:message]).to include("exception")
      end
    end

    context "when action uses log_calls with specific level" do
      let(:action) do
        build_axn do
          log_calls :warn
        end
      end

      before do
        allow(action).to receive(:warn) do |message, **options|
          log_messages << { level: :warn, message:, options: }
        end
      end

      it "uses the specified level" do
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

    context "when action disables logging with log_calls false" do
      let(:action) do
        build_axn do
          log_calls false
        end
      end

      it "disables logging entirely" do
        action.call

        expect(log_messages).to be_empty
      end
    end

    context "when action disables logging with log_calls nil" do
      let(:action) do
        build_axn do
          log_calls nil
        end
      end

      it "disables logging entirely" do
        action.call

        expect(log_messages).to be_empty
      end
    end

    context "when action uses default log_calls level" do
      let(:action) { build_axn }

      before do
        allow(action).to receive(:info) do |message, **options|
          log_messages << { level: :info, message:, options: }
        end
      end

      it "uses the default log_calls level" do
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

  describe "log_errors" do
    let(:log_messages) { [] }

    context "when action succeeds" do
      let(:action) do
        build_axn do
          log_calls false
          log_errors :warn
        end
      end

      before do
        allow(action).to receive(:warn) do |message, **options|
          log_messages << { level: :warn, message:, options: }
        end
      end

      it "does not log anything" do
        action.call

        expect(log_messages).to be_empty
      end
    end

    context "when action fails" do
      let(:action) do
        build_axn do
          log_calls false
          log_errors :warn

          def call = fail!("Something went wrong")
        end
      end

      before do
        allow(action).to receive(:warn) do |message, **options|
          log_messages << { level: :warn, message:, options: }
        end
      end

      it "logs after failed execution but not before" do
        action.call

        expect(log_messages.length).to eq(1)

        before_log = log_messages.find { |log| log[:message].include?("About to execute") }
        after_log = log_messages.find { |log| log[:message].include?("Execution completed") }

        expect(before_log).to be_nil
        expect(after_log).to be_present
        expect(after_log[:message]).to include("failure")
      end
    end

    context "when action raises exception" do
      let(:action) do
        build_axn do
          log_calls false
          log_errors :warn

          def call = raise("Unexpected error")
        end
      end

      before do
        allow(action).to receive(:warn) do |message, **options|
          log_messages << { level: :warn, message:, options: }
        end
      end

      it "logs after exception but not before" do
        expect { action.call! }.to raise_error("Unexpected error")

        expect(log_messages.length).to eq(1)

        before_log = log_messages.find { |log| log[:message].include?("About to execute") }
        after_log = log_messages.find { |log| log[:message].include?("Execution completed") }

        expect(before_log).to be_nil
        expect(after_log).to be_present
        expect(after_log[:message]).to include("exception")
      end
    end

    context "when action uses log_errors with specific level" do
      let(:action) do
        build_axn do
          log_calls false
          log_errors :error

          def call = fail!("Something went wrong")
        end
      end

      before do
        allow(action).to receive(:error) do |message, **options|
          log_messages << { level: :error, message:, options: }
        end
      end

      it "uses the specified level" do
        action.call

        expect(log_messages.length).to eq(1)
        expect(log_messages.first[:level]).to eq(:error)
      end
    end

    context "when action disables log_errors with false" do
      let(:action) do
        build_axn do
          log_errors false

          def call = fail!("Something went wrong")
        end
      end

      it "does not log anything" do
        action.call

        expect(log_messages).to be_empty
      end
    end

    context "when action disables log_errors with nil" do
      let(:action) do
        build_axn do
          log_errors nil

          def call = fail!("Something went wrong")
        end
      end

      it "does not log anything" do
        action.call

        expect(log_messages).to be_empty
      end
    end

    context "when action uses default log_errors level" do
      let(:action) do
        build_axn do
          log_calls false
          log_errors Axn.config.log_level

          def call = fail!("Something went wrong")
        end
      end

      before do
        allow(action).to receive(:info) do |message, **options|
          log_messages << { level: :info, message:, options: }
        end
      end

      it "uses the default level" do
        action.call

        expect(log_messages.length).to eq(1)
        expect(log_messages.first[:level]).to eq(:info)
      end
    end

    context "when both log_calls and log_errors are set" do
      let(:action) do
        build_axn do
          log_calls :debug
          log_errors :warn

          def call = fail!("Something went wrong")
        end
      end

      before do
        allow(action).to receive(:debug) do |message, **options|
          log_messages << { level: :debug, message:, options: }
        end
        allow(action).to receive(:warn) do |message, **options|
          log_messages << { level: :warn, message:, options: }
        end
      end

      it "uses log_calls (logs before and after)" do
        action.call

        expect(log_messages.length).to eq(2)
        log_messages.each { |log| expect(log[:level]).to eq(:debug) }
      end
    end
  end

  describe "inheritance" do
    let(:log_messages) { [] }

    let(:parent_action_class) do
      build_axn do
        log_calls :debug
      end
    end

    it "inherits the log_calls setting" do
      # Set up logging mocks for the parent action class
      allow(parent_action_class).to receive(:debug) do |message, **options|
        log_messages << { level: :debug, message:, options: }
      end

      parent_action_class.call

      expect(log_messages.length).to eq(2)
      log_messages.each { |log| expect(log[:level]).to eq(:debug) }
    end

    context "when child overrides log_calls" do
      let(:child_action) do
        Class.new(parent_action_class) do
          log_calls :warn

          def call
            # child implementation
          end
        end
      end

      it "uses the overridden level" do
        # Set up logging mocks for the child action class
        allow(child_action).to receive(:warn) do |message, **options|
          log_messages << { level: :warn, message:, options: }
        end

        child_action.call

        expect(log_messages.length).to eq(2)
        log_messages.each { |log| expect(log[:level]).to eq(:warn) }
      end
    end

    describe "log_errors inheritance" do
      let(:log_messages) { [] }

      let(:parent_action_class) do
        build_axn do
          log_calls false
          log_errors :error

          def call = fail!("Parent error")
        end
      end

      before do
        allow(parent_action_class).to receive(:error) do |message, **options|
          log_messages << { level: :error, message:, options: }
        end
      end

      it "inherits the log_errors setting" do
        parent_action_class.call

        expect(log_messages.length).to eq(1)
        expect(log_messages.first[:level]).to eq(:error)
      end

      context "when child overrides log_errors" do
        let(:child_action) do
          Class.new(parent_action_class) do
            log_errors :warn

            def call = fail!("Child error")
          end
        end

        before do
          allow(child_action).to receive(:warn) do |message, **options|
            log_messages << { level: :warn, message:, options: }
          end
        end

        it "uses the overridden level" do
          child_action.call

          expect(log_messages.length).to eq(1)
          expect(log_messages.first[:level]).to eq(:warn)
        end
      end
    end
  end
end
