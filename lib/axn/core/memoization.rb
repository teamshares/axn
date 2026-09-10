# frozen_string_literal: true

module Axn
  module Core
    module Memoization
      def self.included(base)
        base.class_eval do
          extend ClassMethods
        end
      end

      module ClassMethods
        def memo(*method_names)
          # `memo` took exactly one required positional before this went variadic, so a bare `memo`
          # (or `memo(*names)` with an unexpectedly-empty `names`) raised a loud arity error. A splat
          # accepts zero silently instead -- there is no legitimate "memoize nothing" call here (unlike
          # `expects`/`before`'s own long-standing tolerance of a truly empty declaration), so an empty
          # list is always the caller's mistake: the intended method is left unmemoized with no
          # complaint. Reject it.
          raise ArgumentError, "memo requires at least one method name" if method_names.empty?

          method_names.each do |method_name|
            if _memo_wise_available?
              _ensure_memo_wise_prepended
              memo_wise(method_name)
            else
              _memo_minimal(method_name)
            end
          end
        end

        private

        def _memo_wise_available?
          defined?(MemoWise)
        end

        def _ensure_memo_wise_prepended
          return if ancestors.include?(MemoWise)

          prepend MemoWise
        end

        def _memo_minimal(method_name)
          method = instance_method(method_name)
          params = method.parameters
          has_args = params.any? { |type, _name| %i[req opt rest keyreq key keyrest].include?(type) }

          if has_args
            raise ArgumentError,
                  "Memoization of methods with arguments requires the 'memo_wise' gem. " \
                  "Please add 'memo_wise' to your Gemfile or use a method without arguments."
          end

          # Wrap the method with memoization
          Axn::Internal::Memoization.define_memoized_reader_method(self, method_name) do
            method.bind(self).call
          end
        end
      end
    end
  end
end
