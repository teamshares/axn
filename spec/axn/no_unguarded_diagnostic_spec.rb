# frozen_string_literal: true

# A diagnostic is guarded; an emitter is not (PRO-3440, AGENTS.md "Errors"). Every line axn's own
# machinery emits about itself is a side channel and sits inside one `Axn::Extensions.best_effort`,
# together with everything it needs to build, render, lock and dedupe. The exceptions are the small,
# closed set of EMITTERS `best_effort`'s own failure path emits THROUGH — guarding one of those would
# put `best_effort` underneath itself — and the user-facing `log`/`debug`/`warn` DSL, whose raise is
# the author's own statement.
#
# This spec DERIVES the list rather than trusting a hand-maintained one: it walks `lib/` with
# RubyVM::AbstractSyntaxTree for every direct `Axn.config.logger.<level>` call and asks whether an
# ANCESTOR node is a block passed to `best_effort` — the same question a reviewer asks by eye, made
# mechanical. A grep-based version can't tell a `best_effort do ... end` block from any other block,
# which is exactly why this reads the syntax tree instead of the text.
#
# What this CANNOT see: a diagnostic reached through a private emitter helper (`Registry#_warn`,
# `MessageResolver#_warn`) where the `best_effort` call sits INSIDE the helper rather than lexically
# around each call site — those are pinned by name below instead, alongside the four true emitters,
# so the same failure mode (a helper whose own body stops being guarded) is still caught.
RSpec.describe "diagnostic emission policy" do
  before do
    skip "requires RubyVM::AbstractSyntaxTree (CRuby only)" unless defined?(RubyVM::AbstractSyntaxTree)
  end

  # rubocop:disable Lint/ConstantDefinitionInBlock
  LEVELS = %i[debug info warn error fatal send].freeze

  # Deliberately unguarded: the bottom of the emit stack `best_effort`'s own failure path emits
  # through (`best_effort -> Extensions._emit_warning -> Internal::ActionState.log -> Core::Logging`
  # for an instance, or straight to the configured logger for anything else). Keyed on
  # "<path>#<enclosing method>" so a rename or a line shift doesn't silently stop pinning the right
  # site — adding or removing one here is a visible policy decision, not a drive-by.
  EMITTERS = [
    "lib/axn/core/logging.rb#log",
    "lib/axn/internal/action_state.rb#log",
    "lib/axn/extensions.rb#_emit_warning",
    "lib/axn/async/exception_reporting.rb#log",
  ].freeze

  # A helper whose OWN body wraps every call it forwards in `best_effort` — verified structurally
  # below, once, rather than trusting each of its callers.
  GUARDED_EMIT_HELPERS = [
    "lib/axn/tools/registry.rb#_warn",
    "lib/axn/core/flow/handlers/resolvers/message_resolver.rb#_warn",
  ].freeze
  # rubocop:enable Lint/ConstantDefinitionInBlock

  def self.lib_files = Dir[File.join(__dir__, "../../lib/**/*.rb")]

  # A CALL's receiver is `Axn::Extensions` exactly — not merely a method NAMED `best_effort`
  # (Codex, PR #283: an unrelated `other.best_effort { ... }` must not be treated as a guard).
  def self.axn_extensions_receiver?(node)
    return false unless node.is_a?(RubyVM::AbstractSyntaxTree::Node) && node.type == :COLON2
    return false unless node.children[1] == :Extensions

    base = node.children[0]
    base.is_a?(RubyVM::AbstractSyntaxTree::Node) && base.type == :CONST && base.children[0] == :Axn
  end

  # `Axn::Extensions.best_effort(...)` (a CALL with the qualified receiver) is the only spelling any
  # real call site uses. A bare `best_effort(...)` (FCALL, no receiver) resolves to the real method
  # only from INSIDE `Axn::Extensions` itself — Ruby's own method lookup, not a convention this spec
  # invents — so it is recognized only when `file` names that one file; passed as `nil` (the default)
  # it is never accepted, since a synthetic snippet or a call elsewhere in `lib/` has no such module
  # to resolve the bare name against.
  def self.best_effort_call?(node, file: nil)
    return false unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

    case node.type
    when :FCALL then node.children[0] == :best_effort && file == "lib/axn/extensions.rb"
    when :CALL then node.children[1] == :best_effort && axn_extensions_receiver?(node.children[0])
    else false
    end
  end

  it "walks a non-empty set of library files" do
    # A guard that silently scans zero files passes forever without checking anything.
    expect(self.class.lib_files).not_to be_empty
  end

  # A pattern-based guard that never demonstrably MATCHES anything reports clean whether or not the
  # invariant holds (the lesson `no_unbound_module_reflection_spec` records). Fabricated sources,
  # parsed directly, are the positive/negative controls for the AST predicate below.
  describe "the underlying predicate" do
    def bare_logger_calls(source, file: nil)
      root = RubyVM::AbstractSyntaxTree.parse(source)
      found = []
      walk = lambda do |node, ancestors|
        next unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

        found << node if node.type == :CALL && logger_call?(node) && !guarded?(ancestors, file:)
        node.children.each { |c| walk.call(c, ancestors + [node]) }
      end
      walk.call(root, [])
      found
    end

    def logger_call?(node)
      LEVELS.include?(node.children[1]) &&
        node.children[0].is_a?(RubyVM::AbstractSyntaxTree::Node) &&
        node.children[0].type == :CALL &&
        node.children[0].children[1] == :logger
    end

    def guarded?(ancestors, file: nil)
      ancestors.any? { |a| a.type == :ITER && self.class.best_effort_call?(a.children[0], file:) }
    end

    it "flags a bare Axn.config.logger.warn" do
      expect(bare_logger_calls("Axn.config.logger.warn('x')").size).to eq(1)
    end

    it "flags a bare block-form Axn.config.logger.debug" do
      expect(bare_logger_calls("Axn.config.logger.debug { 'x' }").size).to eq(1)
    end

    it "flags Axn.config.logger.send(level, msg)" do
      expect(bare_logger_calls("Axn.config.logger.send(level, msg)").size).to eq(1)
    end

    # Codex, PR #283: a receiver-blind check would treat ANY method named `best_effort` as a guard,
    # including one that has nothing to do with `Axn::Extensions` — letting the exact unguarded
    # diagnostic this spec exists to catch slip through under someone else's method of that name.
    it "does NOT treat an unrelated object's best_effort as a guard" do
      expect(bare_logger_calls("other.best_effort('x') { Axn.config.logger.warn('x') }").size).to eq(1)
    end

    it "does not flag a call inside Axn::Extensions.best_effort (fully qualified)" do
      expect(bare_logger_calls("Axn::Extensions.best_effort('x') { Axn.config.logger.warn('x') }")).to be_empty
    end

    # The bare (unqualified) spelling only resolves to the real method from INSIDE the module that
    # defines it -- so it is recognized only when the walk is told it is looking at that one file.
    it "recognizes the bare best_effort form only when told the file is Axn::Extensions itself" do
      source = "best_effort('x') { Axn.config.logger.warn('x') }"
      expect(bare_logger_calls(source, file: "lib/axn/extensions.rb")).to be_empty
      expect(bare_logger_calls(source, file: "lib/axn/tools/registry.rb").size).to eq(1)
      expect(bare_logger_calls(source).size).to eq(1) # file: nil (default) -- never accepted
    end

    it "does not flag an unrelated logger.warn (not Axn.config.logger)" do
      expect(bare_logger_calls("some_other_logger.warn('x')")).to be_empty
    end

    it "does not flag a read of Axn.config.logger (not an emission)" do
      expect(bare_logger_calls("logger = Axn.config.logger")).to be_empty
    end
  end

  # For every file, the enclosing `def`/`def self.` around a bare call — nil for one outside any
  # method, which would itself be worth investigating (there are none today).
  def self.enclosing_method_name(ancestors)
    defn = ancestors.reverse.find { |a| %i[DEFN DEFS].include?(a.type) }
    return nil unless defn

    defn.type == :DEFN ? defn.children[0].to_s : defn.children[1].to_s
  end

  def self.bare_sites
    gem_root = File.expand_path("../..", __dir__)
    sites = []
    lib_files.sort.each do |path|
      root = RubyVM::AbstractSyntaxTree.parse_file(path)
      relative = File.expand_path(path).delete_prefix("#{gem_root}/")
      walk = lambda do |node, ancestors|
        next unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

        if node.type == :CALL
          logger_recv = node.children[0].is_a?(RubyVM::AbstractSyntaxTree::Node) &&
                        node.children[0].type == :CALL && node.children[0].children[1] == :logger
          if logger_recv && LEVELS.include?(node.children[1])
            guarded = ancestors.any? { |a| a.type == :ITER && best_effort_call?(a.children[0], file: relative) }
            sites << "#{relative}##{enclosing_method_name(ancestors)}" unless guarded
          end
        end
        node.children.each { |c| walk.call(c, ancestors + [node]) }
      end
      walk.call(root, [])
    end
    sites.uniq.sort
  end

  it "pins the exact set of bare Axn.config.logger call sites to the declared emitters" do
    expect(self.class.bare_sites).to eq(EMITTERS.sort), <<~MSG
      A new (or moved) bare `Axn.config.logger.<level>` call site appeared in lib/, outside any
      `Axn::Extensions.best_effort` block. Under the stated policy (AGENTS.md "Errors"), it must be
      either:
        - wrapped in `Axn::Extensions.best_effort("<what this diagnostic is about>", action: ...)`, or
        - added to EMITTERS above, with a comment at the site explaining why it is the bottom of the
          emit stack rather than a diagnostic (see the existing four for the shape).
      Found: #{self.class.bare_sites.inspect}
      Expected: #{EMITTERS.sort.inspect}
    MSG
  end

  it "keeps every pinned emitter reachable, so a rename can't leave a stale entry here" do
    missing = EMITTERS - self.class.bare_sites
    expect(missing).to be_empty, "pinned as an emitter but no longer found bare in lib/: #{missing.inspect}"
  end

  # The helper indirection this AST walk cannot see through on its own: each is verified here to wrap
  # its OWN emit in `best_effort`, so trusting it at every call site is sound.
  describe "guarded emit helpers" do
    GUARDED_EMIT_HELPERS.each do |site|
      path, method_name = site.split("#")

      it "wraps #{method_name}'s own emit in best_effort (#{path})" do
        full_path = File.expand_path("../../#{path}", __dir__)
        root = RubyVM::AbstractSyntaxTree.parse_file(full_path)
        defn = nil
        find = lambda do |node|
          return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

          defn = node if node.type == :DEFN && node.children[0].to_s == method_name
          node.children.each { |c| find.call(c) } unless defn
        end
        find.call(root)

        expect(defn).not_to be_nil, "could not find `def #{method_name}` in #{path}"

        wraps_best_effort = false
        walk = lambda do |node|
          return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

          wraps_best_effort ||= self.class.best_effort_call?(node, file: path)
          node.children.each { |c| walk.call(c) }
        end
        walk.call(defn)

        expect(wraps_best_effort).to be(true)
      end
    end
  end

  # `Internal::ActionState.log` is the second seam a diagnostic reaches the logger through, and unlike
  # `Axn.config.logger` above, its guard almost always lives at the CALLER rather than lexically around
  # the call — so it cannot be verified the same structural way. Pinned by name instead: every call
  # site in `lib/`, classified once, so a NEW one fails until it is too.
  describe "Internal::ActionState.log call sites" do
    # "<path>#<enclosing method>" => [how it is guarded, how many calls it makes].
    #   :own_rescue       — the call sits in a method with its own method-level rescue.
    #   :caller_guarded   — every caller of the enclosing method already runs inside a best_effort.
    #   :best_effort      — the call itself sits inside a best_effort block (verified structurally,
    #                       same predicate as above).
    # rubocop:disable Lint/ConstantDefinitionInBlock
    SITES = {
      "lib/axn/extensions.rb#_emit_warning" => [:own_rescue, 1],
      "lib/axn/configuration.rb#on_exception" => [:caller_guarded, 2], # the log line + the nested-report skip
      "lib/axn/core/contract/redaction.rb#_warn_sensitive_resolution_failure" => [:own_rescue, 1],
      "lib/axn/core/flow/handlers/matcher.rb#apply_symbol" => [:caller_guarded, 1], # via SingleRuleMatcher#call's best_effort
      "lib/axn/core/flow/handlers/matcher.rb#handle_invalid" => [:caller_guarded, 1], # via GroupMatcher#call's best_effort
      "lib/axn/core/flow/handlers/invoker.rb#call_symbol_handler" => [:best_effort, 1],
      "lib/axn/core/flow/handlers/resolvers/message_resolver.rb#_warn" => [:best_effort, 1],
    }.freeze
    # rubocop:enable Lint/ConstantDefinitionInBlock

    def self.actionstate_log_receiver?(node)
      return false unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

      case node.type
      when :CONST then node.children[0] == :ActionState
      when :COLON2 then node.children[1] == :ActionState
      else false
      end
    end

    def self.actionstate_call_sites
      gem_root = File.expand_path("../..", __dir__)
      sites = Hash.new(0)
      lib_files.sort.each do |path|
        root = RubyVM::AbstractSyntaxTree.parse_file(path)
        relative = File.expand_path(path).delete_prefix("#{gem_root}/")
        walk = lambda do |node, ancestors|
          next unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

          if node.type == :CALL && node.children[1] == :log && actionstate_log_receiver?(node.children[0])
            sites["#{relative}##{enclosing_method_name(ancestors)}"] += 1
          end
          node.children.each { |c| walk.call(c, ancestors + [node]) }
        end
        walk.call(root, [])
      end
      sites
    end

    it "pins the exact set of call sites, so a new one is classified rather than silently added" do
      expect(self.class.actionstate_call_sites.keys.sort).to eq(SITES.keys.sort), <<~MSG
        A new (or moved) `Internal::ActionState.log` call site appeared in lib/. Its guard usually
        lives at the CALLER rather than around the call itself, so it can't be verified structurally
        the way a direct `Axn.config.logger` call can — classify it here (:own_rescue, :caller_guarded,
        or :best_effort) after tracing what actually guards it.
        Found: #{self.class.actionstate_call_sites.keys.sort.inspect}
        Expected: #{SITES.keys.sort.inspect}
      MSG
    end

    it "pins how many calls each site makes, so a NEW call inside a pinned method is visible too" do
      expect(self.class.actionstate_call_sites).to eq(SITES.transform_values(&:last))
    end

    SITES.each do |site, (policy, _count)|
      it "keeps #{site} classified as #{policy.inspect}" do
        # The classification itself is carried by review (tracing an enclosing rescue or every
        # caller is not mechanically checkable); this pins that the SITE still exists, so a rename
        # can't leave a stale, unverified entry behind.
        expect(self.class.actionstate_call_sites).to have_key(site)
      end
    end

    it "verifies the :best_effort-classified sites structurally" do
      SITES.select { |_, (policy, _count)| policy == :best_effort }.each_key do |site|
        path, method_name = site.split("#")
        full_path = File.expand_path("../../#{path}", __dir__)
        root = RubyVM::AbstractSyntaxTree.parse_file(full_path)
        defn = nil
        find = lambda do |node|
          return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

          defn = node if %i[DEFN DEFS].include?(node.type) && self.class.enclosing_method_name([node]) == method_name
          node.children.each { |c| find.call(c) } unless defn
        end
        find.call(root)

        wraps = false
        walk = lambda do |node|
          return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

          wraps ||= self.class.best_effort_call?(node, file: path)
          node.children.each { |c| walk.call(c) }
        end
        walk.call(defn)

        expect(wraps).to be(true), "#{site} is classified :best_effort but no best_effort call was found wrapping it"
      end
    end
  end
end
