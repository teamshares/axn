# frozen_string_literal: true

require "ripper"

# Every constant a Ruby file's CODE references, DERIVED from the file's parse tree — and whether each one
# resolves in the process asking.
#
# Derived rather than listed, because a list of the same thing was stale within a round: the first version of
# `spec/axn/standalone_require_spec.rb` enumerated four constants per entry point by hand, a fifth was added to
# one of those files days later, and the very defect the spec existed to catch (`Axn::Internal::NativeMethods`
# referenced but never required) went on being green. A parse tree cannot go stale, and it is what makes the
# derivation safe in the other direction too: a constant NAMED IN A COMMENT is not a reference (the first
# throwaway version of this check matched `Reflection::Schema` inside a comment and reported a confident false
# positive), and neither is one inside a string or a Symbol, because Ripper hands back none of them as constants.
#
# Loaded by path — never from `spec_helper` — because its consumer is a fresh Ruby that has deliberately loaded
# ONE axn file and must not load the rest.
module ConstantReferences
  # `[[nesting, "Some::Const"], …]`, where nesting is the lexical module/class nesting the reference appears in
  # (`[["module", "Axn"], ["module", "Internal"], ["module", "Reflection"]]`). The nesting is carried because that is
  # what decides where a relative reference resolves: `Values` inside `module Axn; module Internal; module Reflection`
  # is `Axn::Internal::Reflection::Values`.
  def self.in_source(source)
    found = []
    walk(Ripper.sexp(source), [], found)
    found.uniq
  end

  # The references in `path` that do NOT resolve in this process, as `[nesting_string, reference]` pairs.
  def self.unresolved_in(path)
    in_source(File.read(path)).reject { |nesting, reference| resolves?(nesting, reference) }
                              .map { |nesting, reference| [nesting.map(&:last).join("::"), reference] }
  end

  # Resolved by EVALUATING the reference in its own nesting, rather than by trying candidate fully-qualified
  # names: that is Ruby's own lookup, including the two places a candidate list gets it wrong — a lexical parent
  # (`Values` from inside `PropertyNames`) and a private constant, which is visible from the module's own body
  # and not through `Object.const_get`.
  #
  # In the TOP-LEVEL binding, because eval'd code inherits the cref of the site it runs at: evaluated from a
  # method of this module, `module Axn` reopens `ConstantReferences::Axn` instead, and every reference then reads
  # as unresolved — a check that fails on everything is as useless as one that passes on everything.
  def self.resolves?(nesting, reference)
    source = [*nesting.map { |keyword, name| "#{keyword} #{name}" }, reference, *(["end"] * nesting.size)].join("\n")
    TOPLEVEL_BINDING.eval(source)
    true
  rescue NameError
    false
  end

  def self.walk(node, nesting, found)
    return unless node.is_a?(Array)

    case node[0]
    when :module then return walk(node[2], nesting + [["module", const_path(node[1])]], found)
    when :class
      # The superclass expression is evaluated in the OUTER nesting, the body in the inner one.
      walk(node[2], nesting, found)
      return walk(node[3], nesting + [["class", const_path(node[1])]], found)
    when :var_ref, :const_path_ref, :top_const_ref, :const_path_field, :top_const_field
      path = const_path(node)
      if path
        found << [nesting, path]
        return
      end
    end

    node.each { |child| walk(child, nesting, found) if child.is_a?(Array) }
  end
  private_class_method :walk

  # The dotted spelling of a constant-path node (`"Foo::Bar"`, `"::Foo"`), or nil for a node that is not one —
  # `:var_ref` also wraps local variables and keywords, which carry no `:@const`.
  def self.const_path(node)
    return nil unless node.is_a?(Array)

    case node[0]
    when :@const then node[1]
    when :const_ref, :var_ref then const_path(node[1])
    when :top_const_ref, :top_const_field then "::#{const_path(node[1])}"
    when :const_path_ref, :const_path_field
      base = const_path(node[1])
      base && "#{base}::#{const_path(node[2])}"
    end
  end
  private_class_method :const_path
end
