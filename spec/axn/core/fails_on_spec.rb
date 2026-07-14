# frozen_string_literal: true

RSpec.describe "fails_on" do
  before { allow(Axn.config).to receive(:on_exception) }

  describe "reclassifying a raised exception as a failure" do
    let(:action) do
      build_axn do
        fails_on ArgumentError

        def call = raise ArgumentError, "bad input"
      end
    end

    subject(:result) { action.call }

    it "settles as a failed result" do
      expect(result).not_to be_ok
    end

    it "reports the outcome as failure, not exception" do
      expect(result.outcome).to eq("failure")
      expect(result.outcome).to be_failure
    end

    it "preserves the original exception (not wrapped in Axn::Failure)" do
      expect(result.exception).to be_a(ArgumentError)
      expect(result.exception.message).to eq("bad input")
    end

    it "skips the global on_exception report" do
      result
      expect(Axn.config).not_to have_received(:on_exception)
    end
  end

  describe "an exception class that is NOT declared" do
    let(:action) do
      build_axn do
        fails_on ArgumentError

        def call = raise "some unexpected issue"
      end
    end

    subject(:result) { action.call }

    it "still reports as an exception" do
      expect(result.outcome).to be_exception
    end

    it "still triggers the global on_exception report" do
      result
      expect(Axn.config).to have_received(:on_exception)
    end
  end

  describe "callbacks" do
    let(:fired) { [] }
    let(:action) do
      recorder = fired
      build_axn do
        fails_on ArgumentError

        on_failure { recorder << :failure }
        on_exception { recorder << :exception }
        on_error { recorder << :error }

        def call = raise ArgumentError, "bad"
      end
    end

    it "fires on_failure and on_error, but not on_exception" do
      action.call
      expect(fired).to contain_exactly(:error, :failure)
    end
  end

  describe "message wiring" do
    it "uses a positional string message" do
      action = build_axn do
        fails_on ArgumentError, "Unable to submit"
        def call = raise ArgumentError, "raw"
      end
      expect(action.call.error).to eq("Unable to submit")
    end

    it "uses a block that receives the exception" do
      action = build_axn do
        fails_on(ArgumentError) { |e| "Bad: #{e.message}" }
        def call = raise ArgumentError, "raw"
      end
      expect(action.call.error).to eq("Bad: raw")
    end

    it "falls back to the default error message when none given" do
      action = build_axn do
        fails_on ArgumentError
        def call = raise ArgumentError, "raw"
      end
      expect(action.call.error).to eq("Something went wrong")
    end
  end

  describe "standalone: forwarding" do
    it "attaches the message under a declared base by default (standalone omitted)" do
      action = build_axn do
        error "Couldn't save widget"
        fails_on ArgumentError, "Unable to submit"
        def call = raise ArgumentError, "raw"
      end
      expect(action.call.error).to eq("Couldn't save widget: Unable to submit")
    end

    it "lets the message stand alone (replacing the base) with standalone: true" do
      action = build_axn do
        error "Couldn't save widget"
        fails_on ArgumentError, "Unable to submit", standalone: true
        def call = raise ArgumentError, "raw"
      end
      expect(action.call.error).to eq("Unable to submit")
    end

    it "forwards standalone: for the block form too" do
      action = build_axn do
        error "Couldn't save widget"
        fails_on(ArgumentError, standalone: true) { |e| "Bad: #{e.message}" }
        def call = raise ArgumentError, "raw"
      end
      expect(action.call.error).to eq("Bad: raw")
    end
  end

  describe "multiple exception classes (array)" do
    let(:action) do
      build_axn do
        fails_on [ArgumentError, KeyError], "Couldn't process"

        expects :which
        def call
          raise ArgumentError, "a" if which == :arg
          raise KeyError, "k" if which == :key

          raise "other"
        end
      end
    end

    it "reclassifies each listed class" do
      expect(action.call(which: :arg).outcome).to be_failure
      expect(action.call(which: :key).outcome).to be_failure
    end

    it "wires the message for any of them (OR semantics, not AND)" do
      expect(action.call(which: :arg).error).to eq("Couldn't process")
      expect(action.call(which: :key).error).to eq("Couldn't process")
    end

    it "leaves unlisted exceptions as reported exceptions" do
      expect(action.call(which: :other).outcome).to be_exception
    end
  end

  describe "invalid arguments" do
    it "rejects a non-Exception class" do
      expect do
        build_axn { fails_on String }
      end.to raise_error(ArgumentError, /requires one or more Exception classes/)
    end
  end
end
