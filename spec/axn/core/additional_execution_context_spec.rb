# frozen_string_literal: true

RSpec.describe "Additional execution context" do
  before do
    @original_handler = Axn.config.instance_variable_get(:@on_exception)
    Axn.config.instance_variable_set(:@on_exception, nil)
    allow(Axn.config).to receive(:on_exception)
  end

  after do
    Axn.config.instance_variable_set(:@on_exception, @original_handler)
  end

  describe "set_execution_context" do
    let(:action) do
      build_axn do
        expects :name, type: String

        def call
          set_execution_context(current_record_id: 123, batch_index: 5)
          raise "Processing failed" if name == "error"
        end
      end
    end

    it "includes additional context in exception logging at top level" do
      expect(Axn.config).to receive(:on_exception).with(
        an_instance_of(RuntimeError),
        hash_including(
          action: an_instance_of(action),
          context: hash_including(
            inputs: hash_including(name: "error"),
            current_record_id: 123,
            batch_index: 5,
          ),
        ),
      ).and_call_original

      action.call(name: "error")
    end

    it "accumulates context across multiple calls" do
      action = build_axn do
        def call
          set_execution_context(step: "initialization")
          set_execution_context(step: "processing", record_id: 456)
          raise "Failed"
        end
      end

      expect(Axn.config).to receive(:on_exception).with(
        anything,
        hash_including(context: hash_including(step: "processing", record_id: 456)),
      ).and_call_original

      action.call
    end

    it "does not include additional context in pre/post logging" do
      action = build_axn do
        log_calls :info

        def call
          set_execution_context(extra: "context")
        end
      end

      allow(action).to receive(:info).and_call_original

      action.call

      # Check that pre/post logs don't include the additional context
      expect(action).to have_received(:info).with(
        a_string_matching(/About to execute/),
        anything,
      )
      expect(action).to have_received(:info).with(
        a_string_matching(/Execution completed/),
        anything,
      )
      # Verify the log messages don't contain the additional context
      expect(action).not_to have_received(:info).with(
        a_string_including("extra"),
        anything,
      )
    end

    it "ignores reserved keys (inputs, outputs) from set_execution_context" do
      action = build_axn do
        expects :name, type: String

        def call
          set_execution_context(inputs: { override: true }, custom_key: "allowed")
          raise "Failed"
        end
      end

      expect(Axn.config).to receive(:on_exception).with(
        anything,
        hash_including(
          context: hash_including(
            inputs: hash_including(name: "test"),
            custom_key: "allowed",
          ),
        ),
      ) do |_exception, options|
        # Verify that inputs was not overwritten by set_execution_context
        expect(options[:context][:inputs]).not_to include(override: true)
      end.and_call_original

      action.call(name: "test")
    end
  end

  describe "additional_execution_context hook method" do
    let(:action) do
      build_axn do
        expects :name, type: String

        def call
          @current_record = { id: 789, type: "User" }
          raise "Processing failed" if name == "error"
        end

        private

        def additional_execution_context
          return {} unless @current_record

          {
            current_record_id: @current_record[:id],
            record_type: @current_record[:type],
          }
        end
      end
    end

    it "includes hook context in exception logging at top level" do
      expect(Axn.config).to receive(:on_exception).with(
        an_instance_of(RuntimeError),
        hash_including(
          action: an_instance_of(action),
          context: hash_including(
            inputs: hash_including(name: "error"),
            current_record_id: 789,
            record_type: "User",
          ),
        ),
      ).and_call_original

      action.call(name: "error")
    end

    it "returns empty hash when hook method is not defined" do
      action = build_axn do
        def call
          raise "Failed"
        end
      end

      expect(Axn.config).to receive(:on_exception).with(
        anything,
        hash_including(context: hash_not_including(:current_record_id)),
      ).and_call_original

      action.call
    end

    it "does not include hook context in pre/post logging" do
      action = build_axn do
        log_calls :info

        def call
          @current_record = { id: 999 }
        end

        private

        def additional_execution_context
          { current_record_id: @current_record[:id] }
        end
      end

      allow(action).to receive(:info).and_call_original

      action.call

      # Verify logs don't include the hook context
      expect(action).not_to have_received(:info).with(
        a_string_including("current_record_id"),
        anything,
      )
    end

    it "ignores reserved keys (inputs, outputs) from hook" do
      action = build_axn do
        expects :name, type: String

        def call
          raise "Failed"
        end

        private

        def additional_execution_context
          { outputs: { override: true }, hook_key: "allowed" }
        end
      end

      expect(Axn.config).to receive(:on_exception).with(
        anything,
        hash_including(
          context: hash_including(
            outputs: {},
            hook_key: "allowed",
          ),
        ),
      ) do |_exception, options|
        # Verify that outputs was not overwritten by hook
        expect(options[:context][:outputs]).not_to include(override: true)
      end.and_call_original

      action.call(name: "test")
    end
  end

  describe "set_execution_context and additional_execution_context together" do
    let(:action) do
      build_axn do
        expects :name, type: String

        def call
          @current_record = { id: 111, type: "Order" }
          set_execution_context(batch_id: "batch-123", step: "processing")
          raise "Failed" if name == "error"
        end

        private

        def additional_execution_context
          return {} unless @current_record

          {
            current_record_id: @current_record[:id],
            record_type: @current_record[:type],
          }
        end
      end
    end

    it "merges both contexts in exception logging at top level" do
      expect(Axn.config).to receive(:on_exception).with(
        an_instance_of(RuntimeError),
        hash_including(
          action: an_instance_of(action),
          context: hash_including(
            inputs: hash_including(name: "error"),
            batch_id: "batch-123",
            step: "processing",
            current_record_id: 111,
            record_type: "Order",
          ),
        ),
      ).and_call_original

      action.call(name: "error")
    end

    it "hook method context overrides set_execution_context when keys conflict" do
      action = build_axn do
        def call
          set_execution_context(step: "from_setter")
          raise "Failed"
        end

        private

        def additional_execution_context
          { step: "from_hook" }
        end
      end

      expect(Axn.config).to receive(:on_exception).with(
        anything,
        hash_including(context: hash_including(step: "from_hook")),
      ).and_call_original

      action.call
    end
  end

  describe "execution_context in action-specific handlers" do
    let(:action) do
      build_axn do
        expects :name, type: String

        def call
          set_execution_context(record_id: 999)
          raise "Failed" if name == "error"
        end

        on_exception do
          context = execution_context
          log "Failed with context: #{context.inspect}"
        end
      end
    end

    it "action-specific handler can access additional context via execution_context" do
      expect_any_instance_of(action).to receive(:log).with(
        a_string_including("record_id"),
      )

      action.call(name: "error")
    end

    it "execution_context includes inputs, outputs, and extra context at top level" do
      captured_context = nil
      action = build_axn do
        expects :name, type: String
        exposes :output

        def call
          set_execution_context(setter_value: "from_setter")
          expose :output, "done"
          raise "Failed" if name == "error"
        end

        on_exception do
          captured_context = execution_context
        end

        private

        def additional_execution_context
          { hook_value: "from_hook" }
        end
      end

      action.call(name: "error")

      expect(captured_context[:inputs]).to include(name: "error")
      expect(captured_context[:outputs]).to include(output: "done")
      expect(captured_context).to include(
        setter_value: "from_setter",
        hook_value: "from_hook",
      )
    end
  end

  describe "clear_execution_context" do
    it "clears previously set context" do
      action = build_axn do
        def call
          set_execution_context(step: "before")
          clear_execution_context
          raise "Failed"
        end
      end

      expect(Axn.config).to receive(:on_exception).with(
        anything,
        hash_including(context: hash_not_including(:step)),
      ).and_call_original

      action.call
    end
  end

  describe "inputs_for_logging and outputs_for_logging (private) vs execution_context (public)" do
    it "inputs_for_logging does not include additional context" do
      action = build_axn do
        expects :name, type: String

        def call
          set_execution_context(extra: "context")
        end
      end

      instance = action.send(:new, name: "test")
      instance.send(:set_execution_context, extra: "context")
      inputs = instance.send(:inputs_for_logging)

      expect(inputs).not_to include(:extra)
      expect(inputs).to include(name: "test")
    end

    it "outputs_for_logging does not include additional context" do
      action = build_axn do
        expects :name, type: String
        exposes :output

        def call
          set_execution_context(extra: "context")
          expose :output, "done"
        end
      end

      instance = action.send(:new, name: "test")
      instance.call
      outputs = instance.send(:outputs_for_logging)

      expect(outputs).not_to include(:extra)
      expect(outputs).to include(output: "done")
    end

    it "execution_context includes inputs, outputs, and additional context at top level" do
      action = build_axn do
        expects :name, type: String
        exposes :output

        def call
          set_execution_context(extra: "context")
          expose :output, "done"
        end
      end

      instance = action.send(:new, name: "test")
      instance.send(:set_execution_context, extra: "context")
      instance.call

      exec_ctx = instance.execution_context
      expect(exec_ctx[:inputs]).to include(name: "test")
      expect(exec_ctx[:outputs]).to include(output: "done")
      expect(exec_ctx).to include(extra: "context")
    end
  end
end
