# frozen_string_literal: true

require "active_support/isolated_execution_state"
require "axn/internal/reflection/property_names"

module Axn
  module Core
    module Contract
      # How a declaration-time refusal names the declaration it refuses: the direction and the field as the author
      # wrote it — `expects :company`, `exposes :total`, `expects payload.company_id` for a subfield, and
      # `shape member `sku` in expects :rows` for a member of a block-form shape.
      #
      # A refusal is raised many calls below the `expects`/`exposes` that knows the direction, through helpers that
      # are handed only the field names (and through `FieldConfig`'s and `ShapeConfig`'s constructors, which are
      # handed neither). So the label is set once, where the declaration starts, and read wherever a refusal is
      # composed — rather than threaded through every signature between the two, where a helper that forgot to
      # pass it on would silently drop the direction from every message beneath it.
      #
      # Held in `ActiveSupport::IsolatedExecutionState` (the store every per-execution value axn keeps uses), and set
      # only for the length of one declaration: a nested declaration (a block-form shape
      # member, or a class built while another is declared) restores the outer label when it finishes, raise or
      # not, and nothing outside a declaration ever sees one — so a message composed at runtime names no
      # direction rather than a stale one.
      #
      # Keyed by FIBER inside that slot. Under `isolation_level = :thread` every fiber of a thread shares the one
      # slot, and a block-form declaration can yield from its block: two declarations interleaved on two fibers
      # (resumed by hand, no scheduler) would read each other's label, and each `leave` would restore the other's.
      # A declaration's entries are strictly nested on its own fiber (each one leaves from an `ensure`), so a stack
      # per fiber is exact, and a fiber's key is removed when its last entry leaves, so nothing accumulates.
      # Under `:fiber` isolation the slot is already per fiber and holds one key. The nesting stack's own
      # interleaving heal (`NestingTracking`) answers a different question — which entry a SHARED stack should pop
      # — and would still let one fiber read another's label from the shared top, so it is not reused here.
      module DeclarationLabel
        KEY = :__axn_declaration_label
        private_constant :KEY

        Label = Data.define(:text, :top)
        Entry = Data.define(:previous)
        private_constant :Label, :Entry

        class << self
          # Makes the declaration `direction` (`:expects`/`:exposes`) of `fields`, on `on:`'s route, the current
          # one, answering a token for `leave`. A pair rather than a block so `expects`/`exposes` can enter once
          # their names are canonical and leave from their own `ensure`, whatever path they return or raise by.
          #
          # A declaration naming no field has no label to give (`expects` with nothing in it is a legal no-op), so
          # it enters none and answers nil.
          def enter(direction, fields, on: nil)
            return nil if fields.empty?

            entry = Entry.new(previous: _label)
            _store(Label.new(text: _fields_text(direction, fields, on), top: nil))
            entry
          end

          # Restores whatever was current on this fiber before `enter`; a nil token (the declaration raised before
          # entering) leaves the label alone.
          def leave(entry)
            _store(entry.previous) unless entry.nil?
          end

          # Runs the block as the block-form shape member `name` of the declaration currently being judged. A
          # member is placed by the FIELD it belongs to rather than by every member between, so a member nested in
          # a member reads as one of that field's, the way the author finds it in the source.
          def declaring_member(name, &)
            top = _top
            return yield if top.nil?

            _within(Label.new(text: member(name), top:), &)
          end

          # How a shape member is named wherever a refusal is about it: `shape member `sku` in expects :rows`, or
          # the member alone outside a declaration. Read from the declaration's FIELD rather than from `current`,
          # so a refusal about one member raised while its sibling's label is current still names the right one.
          def member(name) = "shape member `#{PropertyNames.renderable_label(name)}`#{placement}"

          # `" in <field's label>"`, or nothing outside a declaration — what places a member described some other
          # way (by its class, when it has no name) in the declaration it belongs to.
          def placement = (top = _top) ? " in #{top}" : ""

          # A declared subfield config named as its declaration is (`expects payload.company_id`), for a refusal
          # about a config other than the one being declared — a re-anchored subfield, a crossed route.
          def subfield(config) = _fields_text(:expects, [config.field], config.on)

          # The closing sentence of a refusal whose subject (`named`) is some OTHER declaration than the one being
          # judged — a parent a later subfield strands, a config re-anchored onto a new root, the field whose path
          # allowance a member's walk ran out — naming the declaration that tripped it, so the author is pointed at
          # both lines: ` Found while declaring expects payload.id.` Nothing when the two are the same, or outside a
          # declaration. A sentence of its own, after the gist, so the refusal still leads with its subject.
          def found_while(named)
            label = current
            label.nil? || label == named ? "" : " Found while declaring #{label}."
          end

          # The current declaration's label, or nil outside a declaration.
          def current = _label&.text

          # The label of the FIELD being declared, even while one of its members is current — for a refusal about
          # the declaration as a whole (its graph's size), wherever in it the walk was when it found out.
          def declaration = _top

          # `" on <label>"`, or `outside` (nothing, by default) outside a declaration — for a message whose subject
          # is an option rather than the field, so the sentence still reads whole where there is no declaration.
          def locator(outside = "") = (label = current) ? " on #{label}" : outside

          private

          def _within(label)
            previous = _label
            _store(label)
            yield
          ensure
            _store(previous)
          end

          def _top
            label = _label
            label && (label.top || label.text)
          end

          # This fiber's label: the slot maps fibers (by identity) to labels.
          def _label
            labels = ActiveSupport::IsolatedExecutionState[KEY]
            labels && labels[Fiber.current]
          end

          # Sets (or, given nil, clears) this fiber's label, dropping the slot once no fiber holds one.
          def _store(label)
            labels = ActiveSupport::IsolatedExecutionState[KEY]
            if label.nil?
              return if labels.nil?

              labels.delete(Fiber.current)
              ActiveSupport::IsolatedExecutionState[KEY] = nil if labels.empty?
            else
              labels ||= ActiveSupport::IsolatedExecutionState[KEY] = {}.compare_by_identity
              labels[Fiber.current] = label
            end
          end

          # Each name through `PropertyNames`, never its own `to_s`. A top-level field keeps its Symbol spelling
          # (`:company`); a subfield is written as the path the author's `on:` names, which is how it is found in
          # a payload (`payload.company_id`).
          def _fields_text(direction, fields, on)
            names = if on.nil?
                      fields.map { |field| PropertyNames.inspect_field_name(field) }
                    else
                      route = PropertyNames.renderable_label(on)
                      fields.map { |field| "#{route}.#{PropertyNames.renderable_label(field)}" }
                    end
            "#{direction} #{names.join(', ')}"
          end
        end

        PropertyNames = Axn::Internal::Reflection::PropertyNames
        private_constant :PropertyNames
      end
    end
  end
end
