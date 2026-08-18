# frozen_string_literal: true

# An error path names the thing it is reporting on. Where that thing is a caller-supplied class, the
# name is READ from bound base implementations — a class defining its own `to_s`/`inspect`/`name` would
# otherwise get to replace the failure being reported with one of its own. See AGENTS.md.
RSpec.describe "bound reads in guard and error paths" do
  describe "fails_on with an unreachable exception class" do
    it "names the offending class without running its inspect" do
      unreachable = Class.new(Interrupt) do
        def self.name = raise(NotImplementedError, "name must not run in the error path")
        def self.inspect = raise(NotImplementedError, "inspect must not run in the error path")
      end
      # A real constant, so the bound `Module#to_s` has a constant path to answer with — pinning both
      # halves at once: the right name appears, and neither override ran to produce it.
      stub_const("HostileSignal", unreachable)

      expect do
        build_axn { fails_on unreachable }
      end.to raise_error(ArgumentError, /fails_on cannot reclassify HostileSignal/)
    end
  end

  describe "two config sources claiming one namespace" do
    it "names the owning source without running its to_s" do
      owner = Module.new do
        extend Axn::Configurable
        config_namespace :hostile_dup
        setting :foo, default: 1, overridable: true

        def self.to_s = raise(NotImplementedError, "to_s must not run in the error path")
      end
      second = Module.new do
        extend Axn::Configurable
        config_namespace :hostile_dup
        setting :bar, default: 2, overridable: true
      end
      owner_mixin = owner.overrides
      second_mixin = second.overrides

      expect do
        Class.new do
          include owner_mixin
          include second_mixin
        end
      end.to raise_error(ArgumentError, /namespace :hostile_dup is already owned/)
    end
  end

  describe "injecting a parent into a nested form" do
    it "injects based on the method table, not on what the child class reports" do
      # A recognize-then-invoke predicate: a child form answering the reflection wrongly would silently
      # lose its parent rather than fail, which is the same shape as the guards above.
      child = Class.new(Axn::FormObject) do
        def self.name = "ChildForm"

        attr_accessor :child_field, :parent_form

        def self.instance_methods(*) = []
        def self.private_instance_methods(*) = []
      end
      parent = Class.new(Axn::FormObject) do
        def self.name = "ParentForm"
      end
      parent.nested_forms(child_form: child)

      form = parent.new(child_form: { child_field: "value" })
      expect(form.child_form.parent_form).to be(form)
    end
  end
end
