# frozen_string_literal: true

RSpec.describe "Additional logging context" do
  before do
    @original_handler = Axn.config.instance_variable_get(:@on_exception)
    Axn.config.instance_variable_set(:@on_exception, nil)
    allow(Axn.config).to receive(:on_exception)
  end

  after do
    Axn.config.instance_variable_set(:@on_exception, @original_handler)
  end

  describe "set_logging_context" do
    let(:action) do
      build_axn do
        expects :name, type: String

        def call
          set_logging_context(current_record_id: 123, batch_index: 5)
          raise "Processing failed" if name == "error"
        end
      end
    end

    it "includes additional context in exception logging" do
      expect(Axn.config).to receive(:on_exception).with(
        an_instance_of(RuntimeError),
        hash_including(
          action: an_instance_of(action),
          context: hash_including(
            inputs: hash_including(
              name: "error",
              current_record_id: 123,
              batch_index: 5,
            ),
          ),
        ),
      ).and_call_original

      action.call(name: "error")
    end

    it "accumulates context across multiple calls" do
      action = build_axn do
        def call
          set_logging_context(step: "initialization")
          set_logging_context(step: "processing", record_id: 456)
          raise "Failed"
        end
      end

      expect(Axn.config).to receive(:on_exception).with(
        anything,
        hash_including(context: hash_including(inputs: hash_including(step: "processing", record_id: 456))),
      ).and_call_original

      action.call
    end

    it "does not include additional context in pre/post logging" do
      action = build_axn do
        log_calls :info

        def call
          set_logging_context(extra: "context")
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
  end

  describe "additional_logging_context hook method" do
    let(:action) do
      build_axn do
        expects :name, type: String

        def call
          @current_record = { id: 789, type: "User" }
          raise "Processing failed" if name == "error"
        end

        private

        def additional_logging_context
          return {} unless @current_record

          {
            current_record_id: @current_record[:id],
            record_type: @current_record[:type],
          }
        end
      end
    end

    it "includes hook context in exception logging" do
      expect(Axn.config).to receive(:on_exception).with(
        an_instance_of(RuntimeError),
        hash_including(
          action: an_instance_of(action),
          context: hash_including(
            inputs: hash_including(
              name: "error",
              current_record_id: 789,
              record_type: "User",
            ),
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

        def additional_logging_context
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
  end

  describe "set_logging_context and additional_logging_context together" do
    let(:action) do
      build_axn do
        expects :name, type: String

        def call
          @current_record = { id: 111, type: "Order" }
          set_logging_context(batch_id: "batch-123", step: "processing")
          raise "Failed" if name == "error"
        end

        private

        def additional_logging_context
          return {} unless @current_record

          {
            current_record_id: @current_record[:id],
            record_type: @current_record[:type],
          }
        end
      end
    end

    it "merges both contexts in exception logging" do
      expect(Axn.config).to receive(:on_exception).with(
        an_instance_of(RuntimeError),
        hash_including(
          action: an_instance_of(action),
          context: hash_including(
            inputs: hash_including(
              name: "error",
              batch_id: "batch-123",
              step: "processing",
              current_record_id: 111,
              record_type: "Order",
            ),
          ),
        ),
      ).and_call_original

      action.call(name: "error")
    end

    it "hook method context overrides set_logging_context when keys conflict" do
      action = build_axn do
        def call
          set_logging_context(step: "from_setter")
          raise "Failed"
        end

        private

        def additional_logging_context
          { step: "from_hook" }
        end
      end

      expect(Axn.config).to receive(:on_exception).with(
        anything,
        hash_including(context: hash_including(inputs: hash_including(step: "from_hook"))),
      ).and_call_original

      action.call
    end
  end

  describe "context_for_logging in action-specific handlers" do
    let(:action) do
      build_axn do
        expects :name, type: String

        def call
          set_logging_context(record_id: 999)
          raise "Failed" if name == "error"
        end

        on_exception do
          context = context_for_logging
          log "Failed with context: #{context.inspect}"
        end
      end
    end

    it "action-specific handler can access additional context via context_for_logging" do
      expect_any_instance_of(action).to receive(:log).with(
        a_string_including("record_id"),
      )

      action.call(name: "error")
    end

    it "context_for_logging includes both set_logging_context and hook context" do
      captured_context = nil
      action = build_axn do
        expects :name, type: String

        def call
          set_logging_context(setter_value: "from_setter")
          raise "Failed" if name == "error"
        end

        on_exception do
          captured_context = context_for_logging
        end

        private

        def additional_logging_context
          { hook_value: "from_hook" }
        end
      end

      action.call(name: "error")

      expect(captured_context).to include(
        name: "error",
        setter_value: "from_setter",
        hook_value: "from_hook",
      )
    end
  end

  describe "clear_logging_context" do
    it "clears previously set context" do
      action = build_axn do
        def call
          set_logging_context(step: "before")
          clear_logging_context
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

  describe "context is only included for exception logging (direction is nil)" do
    it "does not include additional context when direction is :inbound" do
      action = build_axn do
        expects :name, type: String

        def call
          set_logging_context(extra: "context")
        end
      end

      instance = action.send(:new, name: "test")
      context = instance.send(:context_for_logging, :inbound)

      expect(context).not_to include(:extra)
      expect(context).to include(name: "test")
    end

    it "does not include additional context when direction is :outbound" do
      action = build_axn do
        expects :name, type: String
        exposes :output

        def call
          set_logging_context(extra: "context")
          expose :output, "done"
        end
      end

      instance = action.send(:new, name: "test")
      instance.call
      context = instance.send(:context_for_logging, :outbound)

      expect(context).not_to include(:extra)
      expect(context).to include(output: "done")
    end

    it "includes additional context when direction is nil (exception case)" do
      action = build_axn do
        expects :name, type: String

        def call
          set_logging_context(extra: "context")
          raise "Failed"
        end
      end

      instance = action.send(:new, name: "test")
      # Set the context before checking
      instance.send(:set_logging_context, extra: "context")

      # Check that context_for_logging with nil includes the additional context
      context = instance.send(:context_for_logging, nil)
      expect(context).to include(extra: "context", name: "test")
    end
  end
end
