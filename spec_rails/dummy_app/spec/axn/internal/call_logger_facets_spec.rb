# frozen_string_literal: true

require "semantic_logger"
require "stringio"

# PRO-2854: the non-Rails spec/axn/internal/call_logger_facets_spec.rb stubs SemanticLogger with a
# double (the gem isn't a dependency there). Here we confirm the real forwarding against an actual
# SemanticLogger::Logger — the object rails_semantic_logger installs as Rails.logger — so a declared
# tag/dimension really lands as named tags on the auto_log completion line.
RSpec.describe "auto-log facet annotation with a real SemanticLogger" do
  let(:io) { StringIO.new }

  around do |example|
    SemanticLogger.sync! # synchronous processing — no background appender thread to flush/hang
    original_level = SemanticLogger.default_level
    SemanticLogger.default_level = :trace
    appender = SemanticLogger.add_appender(io:, formatter: :json, level: :trace)
    original_logger = Axn.config.logger
    Axn.config.logger = SemanticLogger["AxnFacetTest"]
    example.run
  ensure
    Axn.config.logger = original_logger
    SemanticLogger.remove_appender(appender)
    SemanticLogger.default_level = original_level
  end

  def events = io.string.each_line.map { |line| JSON.parse(line) }
  def after_event = events.find { |e| e["message"].to_s.include?("Execution completed") }
  def before_event = events.find { |e| e["message"].to_s.include?("About to execute") }

  it "forwards declared facets as namespaced named tags on the completion line" do
    build_axn do
      tag(:company_id) { 7 }
      dimension(:plan) { "pro" }
      def call; end
    end.call

    expect(after_event["named_tags"]).to eq("axn.tag.company_id" => 7, "axn.dimension.plan" => "pro")
  end

  it "annotates in-flight log lines during call with input-phase facets" do
    build_axn do
      tag(:company_id) { 7 }
      def call
        log("in-flight line")
      end
    end.call

    inflight = events.find { |e| e["message"].to_s.include?("in-flight line") }
    expect(inflight["named_tags"]).to eq("axn.tag.company_id" => 7)
  end

  it "keeps result-phase facets off in-flight lines but on the completion line" do
    build_axn do
      tag(:company_id) { 7 } # input phase
      tag(:charged, from: :result) { 99 } # result phase
      def call
        log("in-flight line")
      end
    end.call

    inflight = events.find { |e| e["message"].to_s.include?("in-flight line") }
    expect(inflight["named_tags"]).to eq("axn.tag.company_id" => 7)
    expect(after_event["named_tags"]).to eq("axn.tag.company_id" => 7, "axn.tag.charged" => 99)
  end

  it "does not append the readable suffix when forwarding to a SemanticLogger" do
    build_axn do
      tag(:company_id) { 7 }
      def call; end
    end.call

    expect(after_event["message"]).not_to include("[tags:")
  end

  it "does not annotate the before line (facets aren't resolved yet)" do
    build_axn do
      tag(:company_id) { 7 }
      def call; end
    end.call

    expect(before_event).to be_present
    expect(before_event["named_tags"]).to be_nil
  end

  it "emits no facet named tags when none are declared" do
    build_axn { def call; end }.call

    expect(after_event["named_tags"]).to be_nil
  end
end
