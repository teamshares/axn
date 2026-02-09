# frozen_string_literal: true

RSpec.describe Axn do
  describe "Axn.config#on_exception" do
    subject { action.call(name: "Foo", ssn: "abc", extra: "bang", outbound: 1) }

    before do
      allow(Axn.config).to receive(:on_exception)
    end

    let(:action) do
      build_axn do
        expects :name
        expects :ssn, sensitive: true
        exposes :outbound

        def call
          raise "Some internal issue!"
        end
      end
    end

    let(:filtered_context) do
      { inputs: { name: "Foo", ssn: "[FILTERED]" }, outputs: { outbound: 1 } }
    end

    it "is given a filtered context (sensitive values filtered + inputs and outputs separated)" do
      expect(Axn.config).to receive(:on_exception).with(anything,
                                                        action:,
                                                        context: filtered_context).and_call_original
      is_expected.not_to be_ok
    end
  end

  describe "Action #on_exception" do
    context "base case" do
      let(:action) do
        build_axn do
          expects :exception_klass, default: RuntimeError

          on_exception(if: RuntimeError) do |e|
            log "in on_exception handler: #{e.class.name} - #{e.message}: #{method_for_handler(e.class)}"
          end

          def call
            raise exception_klass, "Some internal issue!"
          end

          private

          def method_for_handler(klass) = klass.to_s
        end
      end

      it "calls the action's on_exception method when exception matches" do
        expect_any_instance_of(action).to receive(:method_for_handler).with(RuntimeError).and_call_original
        expect(action.call).not_to be_ok
      end

      it "does not call the action's on_exception method when exception does not match" do
        expect_any_instance_of(action).not_to receive(:method_for_handler)
        expect(action.call(exception_klass: ArgumentError)).not_to be_ok
      end
    end

    context "triggers all that match" do
      let(:action) do
        build_axn do
          on_exception(if: RuntimeError) do
            log "Handling RuntimeError (specific)"
          end

          on_exception do
            log "Handling StandardError (general)"
          end

          def call
            raise "Some internal issue!"
          end
        end
      end

      it "triggers all handlers that match the exception" do
        expect_any_instance_of(action).to receive(:log).with(
          "#{'#' * 10} Handled exception (RuntimeError): Some internal issue! #{'#' * 10}",
        ).once
        expect_any_instance_of(action).to receive(:log).with("Handling RuntimeError (specific)").once
        expect_any_instance_of(action).to receive(:log).with("Handling StandardError (general)").once
        expect(action.call).not_to be_ok
      end

      context "in production" do
        before do
          allow(Axn.config).to receive(:env).and_return(ActiveSupport::StringInquirer.new("production"))
        end

        it "logs less aggressively" do
          expect_any_instance_of(action).to receive(:log).with("Handled exception (RuntimeError): Some internal issue!").once
          expect_any_instance_of(action).to receive(:log).with("Handling RuntimeError (specific)").once
          expect_any_instance_of(action).to receive(:log).with("Handling StandardError (general)").once
          expect(action.call).not_to be_ok
        end
      end
    end
  end

  context "when on_exception handler itself raises" do
    let(:action) do
      build_axn do
        on_exception(if: RuntimeError) do
          raise StandardError, "fail in handler"
        end
        def call
          raise "Some internal issue!"
        end
      end
    end

    before do
      allow(Axn::Internal::Logging).to receive(:piping_error).and_call_original
    end

    it "calls Axn::Internal::Logging.piping_error when on_exception handler raises" do
      action.call
      expect(Axn::Internal::Logging).to have_received(:piping_error).with(
        a_string_including("executing callback"),
        hash_including(action:, exception: an_object_satisfying { |e| e.is_a?(StandardError) && e.message == "fail in handler" }),
      )
    end
  end

  context "when event handler matcher raises" do
    let(:action) do
      build_axn do
        on_exception(if: ->(_e) { raise StandardError, "fail in matcher" }) do
          # handler body doesn't matter
        end
        def call
          raise "Some internal issue!"
        end
      end
    end

    before do
      allow(Axn::Internal::Logging).to receive(:piping_error).and_call_original
    end

    it "calls Axn::Internal::Logging.piping_error when event handler matcher raises" do
      action.call
      expect(Axn::Internal::Logging).to have_received(:piping_error).with(
        a_string_including("determining if handler applies to exception"),
        hash_including(action:, exception: an_object_satisfying { |e| e.is_a?(StandardError) && e.message == "fail in matcher" }),
      )
    end
  end
end
