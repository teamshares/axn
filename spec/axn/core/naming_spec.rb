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

RSpec.describe "Axn class-level description" do
  it "defaults to nil and stores a string" do
    klass = Class.new { include Axn }
    expect(klass.description).to be_nil
    klass.description "Does a thing."
    expect(klass.description).to eq("Does a thing.")
  end

  it "inherits and can be overridden" do
    parent = Class.new do
      include Axn
      description "parent"
    end
    child = Class.new(parent)
    expect(child.description).to eq("parent")
    child.description "child"
    expect(child.description).to eq("child")
    expect(parent.description).to eq("parent")
  end

  it "does not collide with the field-level description: metadata key" do
    klass = Class.new do
      include Axn
      description "class desc"
      expects :foo, description: "field desc"
    end
    expect(klass.description).to eq("class desc")
    config = klass.internal_field_configs.find { |c| c.field == :foo }
    expect(config.description).to eq("field desc")
  end
end
