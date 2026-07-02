# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Axn axn_name" do
  it "defaults resolved_axn_name to the class name" do
    klass = Class.new do
      include Axn
      def self.name = "MyAction"
    end
    expect(klass.axn_name).to be_nil
    expect(klass.resolved_axn_name).to eq("MyAction")
  end

  it "overrides the resolved name when axn_name is set" do
    klass = Class.new do
      include Axn
      axn_name "custom_tool"
    end
    expect(klass.axn_name).to eq("custom_tool")
    expect(klass.resolved_axn_name).to eq("custom_tool")
  end

  it "falls back to 'Anonymous Axn' for a truly anonymous, unnamed class" do
    klass = Class.new do
      include Axn
      def self.name = nil
    end
    expect(klass.resolved_axn_name).to eq("Anonymous Axn")
  end

  it "inherits axn_name but a subclass can override it" do
    parent = Class.new do
      include Axn
      axn_name "parent_tool"
    end
    child = Class.new(parent)
    expect(child.resolved_axn_name).to eq("parent_tool")
    child.axn_name "child_tool"
    expect(child.resolved_axn_name).to eq("child_tool")
    expect(parent.resolved_axn_name).to eq("parent_tool")
  end
end
