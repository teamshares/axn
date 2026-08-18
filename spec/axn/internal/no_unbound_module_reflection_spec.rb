# frozen_string_literal: true

# A guard or an error path that ASKS a caller-supplied class about its own method table lets the class
# decide the verdict. Every such read goes through `Axn::Internal::NativeMethods`, which binds Ruby's own
# implementation. See AGENTS.md, and `no_shadowable_dispatch_spec.rb` for the instance-name twin of this
# rule.
#
# SCOPE, stated rather than implied: this covers the method-table operators, whose legitimate uses are
# mechanically distinguishable. It does NOT cover `.name`/`.inspect`/`.to_s` on a caller's class — axn has
# roughly a hundred legitimate `descriptor.name`/`setting.name` reads on its OWN objects, so a pattern
# there is all noise and the rule is carried by review instead.
RSpec.describe "unbound reflection on a caller-supplied module" do
  # A receiver that arrived from a caller: a bare local or parameter. Deliberately NOT an ivar — an
  # `@__singleton` holds a module axn built itself, where the same read is a question about its own
  # state — and not a constant, which is either Ruby's own class (`::Module.instance_method(...)`,
  # the bound-constant definitions themselves) or one of axn's modules.
  let(:receiver) { /(?<![\w@.])[a-z_]\w*/ }

  # `ancestors` is absent by necessity, not oversight: `path.ancestors` throughout
  # `contract_for_subfields.rb` / `subfield_tree.rb` is axn's own `ResolvedPath`, and a pattern cannot
  # tell it from a Module's. That read goes through `NativeMethods.module_ancestors`.
  let(:operators) do
    %w[method_defined? private_method_defined? public_method_defined?
       instance_method instance_methods private_instance_methods singleton_class]
  end

  # Operators are ESCAPED: a bare `method_defined?` reads as "method_define" plus an optional "d" in a
  # Regexp, so the unescaped spelling matched none of the real sites — the positive control below is what
  # caught it.
  let(:pattern) { /#{receiver}\.(?:#{operators.map { |op| Regexp.escape(op) }.join('|')})(?![\w?!])/ }

  let(:lib_files) { Dir[File.join(__dir__, "../../../lib/**/*.rb")] }

  it "walks a non-empty set of library files" do
    # A guard that silently scans zero files passes forever without checking anything.
    expect(lib_files).not_to be_empty
  end

  # The lesson from `no_shadowable_dispatch_spec`, whose first version matched only `action`/`@action`
  # receivers and scored zero offenders on a file containing four: a pattern-based guard that is never
  # shown to MATCH anything reports clean whether or not the invariant holds.
  it "flags every shape it exists to flag" do
    offending = [
      "if base.method_defined?(:reset!) || base.private_method_defined?(:reset!)",
      "owner = base.instance_method(:reset!).owner",
      "raise ArgumentError unless resolved_type.public_method_defined?(:valid?)",
      "if (target.instance_methods(false) + target.private_instance_methods(false)).include?(:call)",
      "target.singleton_class.prepend(CallCollisionGuard)",
      "child_params[:parent_form] = self if klass.instance_methods.include?(:parent_form=)",
    ]

    expect(offending.grep_v(pattern)).to be_empty
  end

  it "leaves the legitimate spellings alone" do
    allowed = [
      "MODULE_ANCESTORS = ::Module.instance_method(:ancestors)",
      "KERNEL_SINGLETON_CLASS = ::Kernel.instance_method(:singleton_class)",
      "Axn::Internal::NativeMethods.declared_instance_method(mod, name)",
      "return if @__singleton.method_defined?(predicate_name)",
      "ClassMethods.instance_method(method_name).parameters",
      "MODULE_INSTANCE_METHOD.bind_call(mod, name)",
    ]

    expect(allowed.grep(pattern)).to be_empty
  end

  it "does not appear anywhere in lib/" do
    offenders = lib_files.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        next if line.strip.start_with?("#")
        next unless line.match?(pattern)

        "#{path.sub(%r{.*/lib/}, 'lib/')}:#{index + 1}: #{line.strip}"
      end
    end

    expect(offenders).to be_empty, <<~MSG
      A guard or error path must not ask a caller-supplied class about its own method table — a class
      that answers wrongly inverts the verdict. Read it through Axn::Internal::NativeMethods instead
      (`declared_instance_method`, `declares_own_instance_method?`, `public_instance_method?`,
      `module_ancestors`, `includes_module?`, `module_singleton_class`), after establishing the receiver
      IS a Module via `Identity.kind?`.
      Offending lines:

      #{offenders.join("\n")}
    MSG
  end
end
