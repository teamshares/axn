# frozen_string_literal: true

# NOTE: remnant from previous more-complex behavior, leaving just to confirm basic here.
RSpec.describe Axn::Failure do
  it "defaults to the default message" do
    expect(described_class.new.message).to eq(described_class::DEFAULT_MESSAGE)
  end

  context "with a custom message" do
    it "uses the custom message" do
      expect(described_class.new("foo").message).to eq("foo")
    end
  end
end

RSpec.describe "Axn::Failure originating-axn readers" do
  describe "#originating_axn_class" do
    it "names the axn whose fail! raised" do
      action = build_axn { def call = fail!("nope") }

      expect(action.call.exception.originating_axn_class).to eq(action)
    end

    it "is nil when no axn decided the failure" do
      expect(Axn::Failure.new("nope").originating_axn_class).to be_nil
    end
  end

  describe "#originating_result" do
    it "carries the exposures set before the fail!" do
      action = build_axn do
        exposes :code, optional: true

        def call
          expose code: "guard_x"
          fail!("nope")
        end
      end

      expect(action.call.exception.originating_result.code).to eq("guard_x")
    end

    it "is nil when no axn decided the failure" do
      expect(Axn::Failure.new("nope").originating_result).to be_nil
    end

    # The reason this reader exists rather than handing back the action instance: a consumer
    # dispatching `result` by name on that instance reads the user's field, not the outbound facade.
    it "is not shadowed by an expects :result declaration" do
      action = build_axn do
        expects :result, type: String, optional: true
        exposes :code, optional: true

        def call
          expose code: "guard_x"
          fail!("nope")
        end
      end

      exception = action.call(result: "USER STRING").exception

      expect(exception.__originating_action.result).to eq("USER STRING")
      expect(exception.originating_result.code).to eq("guard_x")
    end

    it "is not shadowed by a def result" do
      action = build_axn do
        exposes :code, optional: true

        def result = "DEF SHADOW"

        def call
          expose code: "guard_x"
          fail!("nope")
        end
      end

      exception = action.call.exception

      expect(exception.__originating_action.result).to eq("DEF SHADOW")
      expect(exception.originating_result.code).to eq("guard_x")
    end
  end
end
