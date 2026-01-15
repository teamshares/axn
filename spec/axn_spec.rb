# frozen_string_literal: true

RSpec.describe Axn do
  it "has a version number" do
    expect(Axn::VERSION).not_to be nil
  end

  describe "initialization" do
    let(:action_class) do
      build_axn do
        expects :name
        def call
          "Hello, #{name}!"
        end
      end
    end

    it "allows instantiation via call class method" do
      result = action_class.call(name: "World")
      expect(result).to be_ok
    end
  end
end
