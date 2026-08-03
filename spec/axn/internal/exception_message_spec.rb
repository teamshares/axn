# frozen_string_literal: true

RSpec.describe Axn::Internal::ExceptionMessage do
  it "returns an ordinary message unchanged" do
    expect(described_class.of(ArgumentError.new("boom"))).to eq("boom")
  end

  it "renders bytes with no UTF-8 rendering into text that can be interpolated" do
    error = ArgumentError.new("caf\xE9".dup.force_encoding(Encoding::ASCII_8BIT))

    rendered = described_class.of(error)
    expect(rendered.encoding).to eq(Encoding::UTF_8)
    expect { "prose: #{rendered}" }.not_to raise_error
  end

  it "falls back to Exception#to_s when #message returns a non-String" do
    klass = Class.new(StandardError) do
      def message = :not_a_string
    end

    expect(described_class.of(klass.new("stored"))).to eq("stored")
  end

  it "falls back to Exception#to_s when #message raises" do
    klass = Class.new(StandardError) do
      def message = raise(NotImplementedError, "hostile reader")
    end

    expect(described_class.of(klass.new("stored"))).to eq("stored")
  end

  it "falls back to the class name when even Exception#to_s cannot answer" do
    hostile = Object.new
    hostile.define_singleton_method(:to_s) { raise(NotImplementedError, "hostile message object") }
    error = Class.new(StandardError).new(hostile)

    expect(described_class.of(error)).to eq(Axn::Internal::ClassName.of(error))
  end
end
