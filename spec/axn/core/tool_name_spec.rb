# frozen_string_literal: true

RSpec.describe "Axn tool_name derivation" do
  def tool_klass(name)
    Class.new do
      include Axn
      define_singleton_method(:name) { name }
    end
  end

  it "snake_cases a single leaf" do
    expect(tool_klass("AgentTools::ListCompanies").tool_name).to eq("list_companies")
  end

  it "keeps non-prefix intermediate segments" do
    expect(tool_klass("AgentTools::Users::ListCompanies").tool_name).to eq("users_list_companies")
  end

  it "strips a leading `actions` prefix" do
    expect(tool_klass("Actions::Company::DoThing").tool_name).to eq("company_do_thing")
  end

  it "strips a leading run of prefixes only (stops at first non-match)" do
    expect(tool_klass("Actions::Tools::Foo::BarTool").tool_name).to eq("foo_bar_tool")
  end

  it "strips the whole leading run of prefixes (contiguous prefixes are all leading)" do
    expect(tool_klass("AgentTools::Tools::Foo").tool_name).to eq("foo")
  end

  it "a `tools` segment after the run is broken survives (leading-run, not anywhere)" do
    expect(tool_klass("AgentTools::Users::Tools::Foo").tool_name).to eq("users_tools_foo")
  end

  it "restricts to a provider-safe charset and collapses separators" do
    expect(tool_klass("Weird::Na me!!Thing").tool_name).to eq("weird_na_me_thing")
  end

  it "falls back to `tool` when derivation is empty" do
    k = tool_klass("Actions::Tools") # every segment is a stripped prefix
    expect(k.tool_name).to eq("tools") # last segment fallback
  end

  it "honors a per-class stripped-prefix override" do
    k = tool_klass("AgentTools::ListCompanies")
    k.tool_name_stripped_prefixes(%w[]) # no stripping
    expect(k.tool_name).to eq("agent_tools_list_companies")
  end

  it "falls back to the derived name when a stored override sanitizes to empty (defense-in-depth)" do
    # Bypass the `tool` DSL guard by writing the class_attribute directly: `tool_name` must
    # still never return blank, so it falls through to the derived-name path.
    k = tool_klass("AgentTools::ListCompanies")
    k._tool_name_override = "!!!"
    expect(k.tool_name).to eq("list_companies")
  end

  it "derives from the stable class name, not the mutable axn_name display override" do
    k = tool_klass("AgentTools::ListCompanies")
    k.axn_name "List companies in CRM"

    expect(k.tool_name).to eq("list_companies")
    expect(k.resolved_axn_name).to eq("List companies in CRM")
  end

  it "an explicit `tool name:` override still wins over both the class name and axn_name" do
    k = tool_klass("AgentTools::ListCompanies")
    k.axn_name "List companies in CRM"
    k.tool name: "custom"

    expect(k.tool_name).to eq("custom")
  end

  it "falls back to `tool` for an anonymous class (nil name), even with axn_name set" do
    k = Class.new do
      include Axn
      axn_name "List companies in CRM"
    end

    expect(k.tool_name).to eq("tool")
  end

  describe "an inherited `tool name:` override does not leak into a subclass's own redeclaration" do
    def named_klass(name, &blk)
      Class.new do
        include Axn
        define_singleton_method(:name) { name }
        class_eval(&blk) if blk
      end
    end

    it "a subclass redeclaring `tool` (no name:) derives its OWN name, not the parent's override" do
      parent = named_klass("AgentTools::ParentTool") { tool name: "custom_parent" }
      expect(parent.tool_name).to eq("custom_parent")

      sub = Class.new(parent) { define_singleton_method(:name) { "AgentTools::SubTool" } }
      sub.tool # fresh declaration without name: → clears inherited override

      expect(sub.tool_name).to eq("sub_tool")
      # The parent is unaffected.
      expect(parent.tool_name).to eq("custom_parent")
    end

    it "a subclass redeclaring `tool name:` uses its own explicit override" do
      parent = named_klass("AgentTools::ParentTool") { tool name: "custom_parent" }

      sub = Class.new(parent) { define_singleton_method(:name) { "AgentTools::SubTool" } }
      sub.tool name: "sub_custom"

      expect(sub.tool_name).to eq("sub_custom")
      expect(parent.tool_name).to eq("custom_parent")
    end
  end
end
