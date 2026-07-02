# frozen_string_literal: true

# PRO-2854: the auto_log after-line is annotated with resolved tag/dimension facets.
# Named tags when the configured logger is a SemanticLogger; a labeled readable suffix otherwise.
RSpec.describe "auto-log facet annotation" do
  let(:log_messages) { [] }

  def after_line = log_messages.find { |m| m.include?("Execution completed") }
  def before_line = log_messages.find { |m| m.include?("About to execute") }

  def capture_levels(logger)
    Axn::Core::Logging::LEVELS.each do |level|
      allow(logger).to receive(level) { |msg| log_messages << msg }
    end
  end

  describe "plain logger (no semantic_logger)" do
    let(:logger) { instance_double(Logger, debug: nil, info: nil, warn: nil, error: nil, fatal: nil) }

    before do
      allow(Axn.config).to receive(:logger).and_return(logger)
      capture_levels(logger)
    end

    it "appends a labeled [tags: …] [dimensions: …] suffix to the after line" do
      build_axn do
        tag(:company_id) { 5 }
        dimension(:plan) { "trial" }
        def call; end
      end.call

      expect(after_line).to include("[tags: {company_id: 5}]")
      expect(after_line).to include('[dimensions: {plan: "trial"}]')
    end

    it "omits the dimensions group when no dimensions are declared" do
      build_axn do
        tag(:company_id) { 5 }
        def call; end
      end.call

      expect(after_line).to include("[tags: {company_id: 5}]")
      expect(after_line).not_to include("[dimensions:")
    end

    it "omits the tags group when no tags are declared" do
      build_axn do
        dimension(:plan) { "trial" }
        def call; end
      end.call

      expect(after_line).to include('[dimensions: {plan: "trial"}]')
      expect(after_line).not_to include("[tags:")
    end

    it "adds no suffix when no facets are declared" do
      build_axn { def call; end }.call

      expect(after_line).to be_present
      expect(after_line).not_to include("[tags:")
      expect(after_line).not_to include("[dimensions:")
    end

    it "does not annotate the before line (facets aren't resolved yet)" do
      build_axn do
        tag(:company_id) { 5 }
        def call; end
      end.call

      expect(before_line).to be_present
      expect(before_line).not_to include("[tags:")
    end

    it "truncates an oversized facet value per MAX_CONTEXT_LENGTH" do
      build_axn do
        tag(:blob) { "x" * 500 }
        def call; end
      end.call

      expect(after_line).to include("[tags:")
      expect(after_line).to include(Axn::Internal::CallLogger::TRUNCATION_SUFFIX)
    end
  end

  describe "semantic logger present" do
    let(:tagged_calls) { [] }

    before do
      captured = tagged_calls
      semantic_logger = Module.new
      logger_klass = Class.new(Logger)
      semantic_logger.const_set(:Logger, logger_klass)
      semantic_logger.define_singleton_method(:tagged) do |*_tags, **named, &blk|
        captured << named
        blk.call
      end
      stub_const("SemanticLogger", semantic_logger)

      logger = logger_klass.new(File::NULL)
      capture_levels(logger)
      allow(Axn.config).to receive(:logger).and_return(logger)
    end

    it "forwards namespaced named tags to SemanticLogger.tagged" do
      build_axn do
        tag(:company_id) { 5 }
        dimension(:plan) { "trial" }
        def call; end
      end.call

      # Two tagged contexts open: the in-flight body context and the completion line. Both carry
      # the (input-phase) facets here, since neither is marked result:.
      expect(tagged_calls).not_to be_empty
      expect(tagged_calls).to all(eq({ "axn.tag.company_id": 5, "axn.dimension.plan": "trial" }))
    end

    it "routes input facets to the in-flight context and adds result facets only at the completion line" do
      build_axn do
        tag(:company_id) { 5 }               # input phase (default)
        tag(:charged, from: :result) { 9 }   # result phase
        def call; end
      end.call

      # The in-flight body context opens first (before the body) with input facets only; the
      # completion-line context opens at settle with the merged (input + result) facets.
      expect(tagged_calls.first).to eq({ "axn.tag.company_id": 5 })
      expect(tagged_calls.last).to eq({ "axn.tag.company_id": 5, "axn.tag.charged": 9 })
    end

    it "does not append a readable suffix when forwarding to the semantic logger" do
      build_axn do
        tag(:company_id) { 5 }
        def call; end
      end.call

      expect(after_line).not_to include("[tags:")
    end

    it "does not call SemanticLogger.tagged when no facets are declared" do
      build_axn { def call; end }.call

      expect(tagged_calls).to be_empty
    end
  end
end
