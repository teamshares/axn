# frozen_string_literal: true

require "tmpdir"

# Discovery against a registry whose directory this spec writes, so every route a non-entry constant can
# take into the registry is present at once: inherited from Internal::Registry, defined by the registry
# class itself, defined beside an entry in its file, and defined in a `_`-prefixed helper file.
RSpec.describe Axn::Internal::Registry do
  around do |example|
    Dir.mktmpdir("axn-registry-spec") do |dir|
      @dir = dir
      example.run
    end
  end

  let(:registry) do
    dir = @dir
    Class.new(described_class) do
      const_set(:LookupError, Class.new(StandardError))
      const_set(:Settings, Module.new)

      define_singleton_method(:registry_directory) { dir }
    end
  end

  def write_entry(basename, body)
    FileUtils.mkdir_p(File.join(@dir, "registry_spec_widgets"))
    File.write(File.join(@dir, "registry_spec_widgets", "#{basename}.rb"), body)
  end

  before do
    stub_const("RegistrySpecWidgets", registry)
  end

  it "lists only the module each entry file is named for" do
    write_entry("_shared", "class RegistrySpecWidgets; module Shared; end; end")
    write_entry("alpha", <<~RUBY)
      class RegistrySpecWidgets
        class AlphaError < StandardError; end
        module AlphaHelper; end
        module Alpha; end
      end
    RUBY
    write_entry("beta_gamma", "class RegistrySpecWidgets; class BetaGamma; end; end")

    expect(registry.built_in).to eq(alpha: RegistrySpecWidgets::Alpha, beta_gamma: RegistrySpecWidgets::BetaGamma)
  end

  it "keeps the base error classes reachable under their names" do
    expect(described_class::NotFound).to be < StandardError
    expect(described_class::DuplicateError).to be < StandardError
  end

  it "refuses an entry file that defines no module named for it" do
    write_entry("delta", "class RegistrySpecWidgets; module NotDelta; end; end")

    expect { registry.built_in }.to raise_error(NotImplementedError, /delta\.rb must define the module RegistrySpecWidgets::Delta/)
  end

  it "does not take an inherited constant for an entry file's module" do
    write_entry("not_found", "class RegistrySpecWidgets; end")

    expect { registry.built_in }.to raise_error(NotImplementedError, /not_found\.rb must define the module RegistrySpecWidgets::NotFound/)
  end
end
