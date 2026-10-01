# frozen_string_literal: true

# A `model:` route's generated `<leaf>_id` key is the convention's answer, never re-derived here.
require "axn/internal/field_config"
require "axn/internal/reflection/schema/vocabulary"

module Axn
  module Internal
    module Reflection
      module Schema
        # The walk that nests a subfield tree into its parent's emitted property: each explicit child's property
        # built from its routes and conjoined with any ancestor `shape:` member at its key, each implicit
        # intermediate emitted as a bare object, each `model:` route's generated `<leaf>_id`, and each child's
        # place in its parent's `required` list. It reads the annotation map `Requiredness` builds and never
        # writes it, and hands every collision it finds to `Merge`. Two things are settled only after a parent's
        # whole child loop has run — a `model:` id merged into an explicit sibling, and a required id's `null`
        # branch stripped — because a sibling visited later can still write that key.
        module Nesting
          include Vocabulary

          # What one `apply_children!` loop hands each `model:` child it visits: the parent's property, its subfield
          # tree, routes and annotation map, the shape members carried from a shallower hop, and the two lists the
          # loop settles only after every key has run (`required_model_ids`, `model_id_siblings`).
          ChildLoop = Data.define(:prop, :children, :parent_configs, :ann, :carried, :required_model_ids, :model_id_siblings)

          # Whether a declaration beneath `node` resolves its path with `method_call:`, and so reads a method off
          # this node's value where that value is not a Hash rather than settling absent.
          def subtree_reads_methods?(node)
            node.children.each_value.any? { |child| child.configs.any?(&:method_call) || subtree_reads_methods?(child) }
          end

          # Whether something beneath `node` that reads by plain KEY is required on every call — which is what rejects a
          # value at `node` that is not an object, since a key read off anything else settles absent. A `method_call:`
          # declaration proves nothing about that: it reads a method off whatever is there (`"abc".size`), so its own
          # requiredness is left out, and so is everything reached only through it. The same own-level rule
          # `node_optional?` applies, asked of a child's plain-key, ungated routes alone.
          def subtree_requires_object?(node, ann)
            node.children.each_value.any? do |child|
              next subtree_requires_object?(child, ann) if child.implicit?

              child.configs.any? do |config|
                next false if config.method_call || requiredness_conditionally_relaxable?(config)

                !usable_default?(config, subfield: true) &&
                  (!nil_tolerance_rescues_absence?(config) || subtree_requires_object?(child, ann))
              end
            end
          end

          # Mutates `prop` to nest the node's children as `prop[:properties]`/`prop[:required]`, recursing
          # through the whole subtree. Forces the parent to `type: object` (it now has structure). The parent
          # is nullable only when it tolerates nil AND strands no required descendant: runtime treats a nil
          # parent as "subfields absent" (PRO-2857), so a nil-accepting parent with an all-optional subtree
          # accepts `null`, while a required descendant (which a nil parent can't yield) keeps it object-only.
          # Only applies when EVERY admissible parent type is object-shaped (Hash/`:params`/untyped) — a
          # non-object parent (`type: Array`) or a mixed union (`type: [Hash, Array]`) keeps its declared
          # type(s) and its subfields' shape is omitted, since object properties can't represent a non-object
          # branch (deep descendants there are in dropped_deep_subfields; its children still shape
          # requiredness via required_child?, matching runtime).
          # `node`'s own representative config (the FIRST non-model config at a merged node) decides the
          # annotation's nullability — see Requiredness::NodeAnnotation — and every route's own check is
          # conjoined onto the property by `apply_explicit_child!`. `node.configs` is EVERY config at the
          # node: it decides both whether to nest at all (node_configs_block_nesting?, the same predicate the
          # drop pass uses, so a route the tree drops from is never re-nested) and, threaded on as parent
          # configs, which `shape:` members might collide with an implicit child.
          def apply_nested_subfields!(prop, node, ann, carried: NO_SHAPE_MEMBERS)
            children = node.children
            return if children.empty?

            node_configs = node.configs
            if node_configs_block_nesting?(node_configs)
              # A non-nestable parent (non-object type, mixed union, or model route) omits its children's
              # SHAPE but NOT their OBLIGATION: field_optional? still forces the parent required when a child
              # requires presence, so its nullability must agree. A nil parent yields every descendant absent
              # (PRO-2857), stranding the required descendant, so strip the parent's `null` admission
              # (reject_null! handles both a type array and an anyOf union) — mirroring the nested-child guard
              # in apply_children!. Predicate: children_require_presence?(children), the same transitive
              # presence test as the nested analog's subtree_requires_presence?(node); required_child?'s
              # shape-synthesis clause is inert for a non-object parent, so the plain presence test is exact
              # and keeps the two sites' reasoning identical.
              reject_null!(prop) if children_require_presence?(children, ann)
              return
            end

            prop.delete(:format)
            prop[:properties] ||= {}
            prop[:required] ||= []

            apply_children!(prop, children, node_configs, ann, carried:)

            prop[:required] = prop[:required].uniq
            # A nil parent yields its subfields as absent, so `null` is admissible exactly when the parent
            # accepts nil and no required nested obligation is stranded (required_child? — which counts a
            # required shape member only when the parent's OWN default materializes it). Read from the
            # precomputed annotation (derive_annotations already applied this same rule to `node`), NOT
            # `prop[:required]`, which also carries shape members that a bare nil parent never triggers.
            #
            # The node is typed `object` only where the runtime rejects every other value too: a type check that
            # runs on every call, or a required child read by key, which a non-object value leaves absent. Otherwise
            # — an untyped parent, or one whose type check is gated — a String or Array reaches the children as
            # nothing and passes, and `properties` (which JSON Schema applies to objects alone) says all there is to
            # say; a child read by `method_call:` reads a method off it instead, which is named, exactly as at an
            # implicit intermediate (`apply_implicit_node!`).
            object_only = nested_node_object_only?(node, node_configs, ann)
            prop.replace(record_residue(prop, METHOD_READ_RESIDUE)) if !object_only && subtree_reads_methods?(node)
            if object_only
              prop[:type] = ann[node].nullable ? %w[object null] : "object"
            elsif !preprocessed?(node_configs) &&
                  node_configs.any? { |c| presence_rejects_blank?(gate_closed_validations(c, c.validations)) }
              # Untyped, a presence check still rejects every blank — nil among them — as a value set.
              prop[:not] = blank_refusal(nullable: ann[node].nullable)
            elsif !ann[node].nullable
              reject_null!(prop)
            end
            prop[:required] = nil if prop[:required].empty?
          end

          # Never for a node that preprocesses its value: its children read the Proc's output, so the wire value
          # may be anything that becomes an object (a JSON String the Proc parses).
          def nested_node_object_only?(node, node_configs, ann)
            return false if preprocessed?(node_configs)

            node_configs.any? { |c| gate_closed_validations(c, c.validations).key?(:type) } || subtree_requires_object?(node, ann)
          end

          def preprocessed?(configs) = configs.any? { |c| c.respond_to?(:preprocess) && c.preprocess }

          # Emits one level of children into `prop` (which must already have :properties/:required arrays),
          # recursing into each child's own subtree. `parent_configs` are the configs whose subfields these
          # children are — used to decide, by the same predicate as the drop pass, whether an implicit child
          # may merge into a colliding shape member. They are the top-level/subfield configs at an explicit
          # parent (ALL of them at a merged node, mirroring SubfieldTree), or the shape members an implicit
          # intermediate merged into (so nested members block at depth), or empty for a fresh implicit
          # intermediate that claimed no shape member.
          #
          # A single wire path can be declared via two routes (Node#configs size > 1), and the routes can
          # disagree on kind: a `model:` route emits the generated `<leaf>_id` while a plain route emits the
          # object property. Both are enforced at runtime, so both are emitted, each required per its OWN
          # route's configs — not the node as a whole.
          #
          # At a merged model+non-model node the non-model route's raw-key property admits values the runtime
          # always rejects — the model resolver reads the raw key as the record, and a JSON value is never a model
          # instance, so only a blank passes. That looseness is named on the property (`name_model_lookups!`), and
          # the generated `<leaf>_id` advertises the working path.
          def apply_children!(prop, children, parent_configs, ann, carried: NO_SHAPE_MEMBERS)
            required_model_ids = []
            model_id_siblings = []
            # Hoisted: every child asks the same question of the same two lists, and this is a hot loop.
            ancestor_configs = carried.empty? ? parent_configs : parent_configs + carried
            # Asked ONCE rather than per child, and it is the difference between this costing nothing and costing
            # a discarded list per child: a contract declaring no `shape:` at this node — the common case by far —
            # has no member to collide with at any key, so the per-key lookup below is skipped outright. Measured
            # at +15% allocations for a shape-free action with 21 subfield children before this guard, ~0 after.
            ancestor_shapes = ancestor_configs.any? { |c| c.validations[:shape] }
            # What the ancestor actually EMITTED at a child's key is named through `property_routes`, the one owner
            # of which routes a property is built from, so the member a child is conjoined with is judged by the
            # configs that produced it.
            emitted_ancestor_configs = property_routes(parent_configs) + carried
            transforming_routes = transforming_routes_beside_wire_routes(parent_configs)
            transformed_keys = []
            child_loop = nil
            model_routes_first(children).each do |key, node|
              transformed = collect_transformed_keys!(transformed_keys, key, node, children, transforming_routes)
              if node.implicit?
                apply_implicit_node!(prop, key, node, ancestor_configs, ann)
                next
              end

              model_configs = node.configs.select { |c| c.validations[:model] }
              non_model_configs = node.configs.reject { |c| c.validations[:model] }
              # The object property is built from the representative and conjoined with every other non-model route
              # (`conjoined_route_property`); `property_routes` names them for every layer that must.

              unless model_configs.empty?
                child_loop ||= ChildLoop.new(prop:, children:, parent_configs:, ann:, carried:, required_model_ids:, model_id_siblings:)
                apply_model_id_child!(child_loop, key, node, model_configs, derived: model_id_derived?(transformed, key, model_configs, children))
              end

              representative = property_representative(node.configs)
              next unless representative

              members = ancestor_shapes ? shape_members_at(ancestor_configs, key) : NO_SHAPE_MEMBERS
              emitted_members = ancestor_shapes ? shape_members_at(emitted_ancestor_configs, key) : NO_SHAPE_MEMBERS
              apply_explicit_child!(prop, key, node, representative, non_model_configs, members, emitted_members, ann)
              apply_child_requiredness!(prop, key, node, non_model_configs, ann)
            end
            # The sibling's OWN entry (a plain child of this same loop) always wins the property outright
            # regardless of visitation order, so `prop[:properties][id_field]` is only guaranteed to hold
            # the sibling's FINAL emission once every key has been visited — merging mid-loop risked
            # reading a not-yet-overwritten model placeholder.
            #
            # Ordered BEFORE the required-null pass just below, not after: merging the declared `id_type:`
            # in uses the SIBLING's OWN `allow_nil:`/`allow_blank:` to decide whether `"null"` joins the
            # merged type (an untyped `company_id, allow_nil: true` sibling beside a REQUIRED model
            # reconstructed `type: ["integer", "null"]`) — but requiredness here is decided by the MODEL,
            # not the sibling, and a required model id can never actually resolve from `nil` at runtime.
            # Merging first and then letting the null pass strip `"null"` from whatever type it finds lets
            # that pass win regardless of which ran the type in; the reverse order let the sibling's own
            # nullability reintroduce a null branch the null pass had already correctly removed, silently
            # admitting a value runtime always rejects for a required id (top-level
            # `apply_model_id_requiredness!` never had this bug — its merge already ran before its own
            # `reject_null!`, being a single sequential method rather than two loops here).
            model_id_siblings.each do |id_field, model_configs, explicit_id|
              merge_model_id_type_into_sibling!(prop[:properties][id_field], model_configs, explicit_id) if prop[:properties][id_field]
            end
            name_model_lookups!(prop, children, ann, model_id_siblings.to_h { |id_field, _configs, explicit_id| [id_field, explicit_id] })
            # A required nested model id can't be null (a null token resolves the model to nil at runtime).
            # Done after the loop so it survives an explicit id subfield declared after the model: subfield.
            required_model_ids.each { |id_field| reject_null!(prop[:properties][id_field]) if prop[:properties][id_field] }
            # Last, once every key's property and `required` entry is final — whichever path wrote it: an explicit
            # or implicit child, a `model:` route's generated id (written before the loop reaches the route's own
            # property, and absent a representative at all for a `model:`-only child), or the drains above.
            transformed_keys.uniq.each { |key| stand_down_transformed_child!(prop, key) }
          end

          # Whether this child reads a transforming route, recording the keys it writes that stand down if so.
          def collect_transformed_keys!(transformed_keys, key, node, children, transforming_routes)
            return false unless reads_transformed_route?(node, transforming_routes)

            transformed_keys.concat(transformed_child_keys(key, node, children))
            true
          end

          # The keys a child anchored on a transforming route writes: its own, and a `model:` route's generated id
          # when nothing else is declared at the id's key — the Proc's output then supplies the token. A declared
          # sibling keeps its own property: its own anchor decides it on its own visit.
          def transformed_child_keys(key, node, children)
            model_configs = node.implicit? ? [] : node.configs.select { |c| c.validations[:model] }
            return [key] if model_configs.empty? || model_id_reading(key, model_configs, children) != :generated

            [key, Internal::FieldConfig.model_id_key(key)]
          end

          # Whether a `model:` child's generated id carries the model's own requirement: always, unless the child reads
          # a transforming route and its lookup reads past a sibling declared at the id's key.
          def model_id_derived?(transformed, key, model_configs, children)
            !transformed || model_id_reading(key, model_configs, children) != :unread_sibling
          end

          # Where a `model:` child's lookup reads its token: `:generated` when nothing is declared at the `<field>_id`
          # key, `:sibling` when every model route reads a declaration there — asked of the runtime's own selector
          # (`FieldConfig.id_token_routes`, which `ContractForSubfields.sibling_id_configs` calls over the same
          # candidates) — and `:unread_sibling` when one is declared but a route reads past it, off its own
          # (transformed) parent.
          def model_id_reading(key, model_configs, children)
            sibling = children[Internal::FieldConfig.model_id_key(key)]
            return :generated if sibling.nil? || sibling.implicit?

            read = model_configs.all? { |config| Internal::FieldConfig.id_token_routes(config, sibling.configs).any? }
            read ? :sibling : :unread_sibling
          end

          # At a node two routes declare, the routes that transform the value (`preprocess:`) while another reads it
          # as sent. A node every route transforms stands down whole, children included (`emitted_input_property`,
          # the collision's own stand-down), so only the mixed node has a child to judge on its own.
          def transforming_routes_beside_wire_routes(parent_configs)
            routes = parent_configs.reject { |c| c.validations[:model] }
            transforming = routes.select { |c| transforms_wire_value?([c]) }
            transforming.size < routes.size ? transforming : NO_TRANSFORMING_ROUTES
          end

          NO_TRANSFORMING_ROUTES = [].freeze
          private_constant :NO_TRANSFORMING_ROUTES

          # Whether any declaration in this child's subtree is anchored on a transforming route: its `on:` names
          # that route's reader, so it reads the Proc's output rather than the wire value — the reading a child of
          # a transformed parent declared alone takes. A dotted `on:` naming the node itself is refused at
          # declaration when two routes declare it, so a reader name is the only way to reach one route.
          def reads_transformed_route?(node, transforming_routes)
            return false if transforming_routes.empty?

            readers = transforming_routes.map { |route| route.reader_as.to_sym }
            subtree_configs(node).any? { |config| readers.include?(config.on.to_s.split(".").first&.to_sym) }
          end

          def subtree_configs(node) = node.configs + node.children.each_value.flat_map { |child| subtree_configs(child) }

          # The child's checks judge the Proc's output, so none of them is stated on the wire form — the same
          # stand-down a transformed parent's whole property takes (`emitted_input_property`), its description and
          # default kept and the rest named. Nor is it required: the transform may supply it.
          def stand_down_transformed_child!(prop, key)
            child = prop[:properties][key]
            return if child.nil?

            prop[:properties][key] = stand_down_from(child.slice(:description, :default), child.except(:description, :default), TRANSFORM_RESIDUE)
            prop[:required].delete(required_key(key))
          end

          # The children with a `model:` route first, each group in declaration order. A dotted child reaching a
          # model's generated `<leaf>_id` (`on: "payload.company_id"`) makes that key an implicit node, which merges
          # into whatever the key already holds; visited first, it wrote the key itself and the model's own id
          # property — its "ID of the … record." description and its `id_type:` — was never built. The model
          # route writes the key first whichever was declared first, so the document is the same either way.
          def model_routes_first(children)
            modelled, rest = children.partition { |_key, node| !node.implicit? && node.configs.any? { |c| c.validations[:model] } }
            modelled.empty? ? children : modelled + rest
          end

          # A child is required when its routes require it with every gate closed — the routes a gate can relax
          # are left out, exactly as the ancestor-propagation annotation leaves them out — and a requirement
          # only a gate imposes is named on the child's property instead.
          def apply_child_requiredness!(prop, key, node, configs, ann)
            return if node_optional?(node, ann, configs)
            # Already required unconditionally by something else at this position (an ancestor's shape member).
            return if prop[:required].include?(required_key(key))

            if node_optional?(node, ann, configs.reject { |c| requiredness_conditionally_relaxable?(c) })
              prop[:properties][key] = with_gated_requirement(prop[:properties][key], configs)
            else
              prop[:required] << required_key(key)
            end
          end

          # Builds and writes the property for one EXPLICIT child. Extracted from `apply_children!`'s loop for the
          # reason `apply_model_id_child!` was: conjoining an ancestor `shape:` member here pushed that single
          # method back over this file's own complexity budget, and another key folded into one already-large loop
          # body is what the earlier extraction was avoiding.
          #
          # An ancestor `shape:` may describe this very key, and `apply_structured_schema!` has already emitted
          # its property into `prop[:properties][key]` (from `build_property`, before `apply_children!` ran at
          # all). Runtime enforces the member and the node alike, so the two are CONJOINED rather than one
          # replacing the other — the merged (object-shaped) members are carried down so a deeper hop sees a
          # member-of-a-member, the same thing `apply_implicit_node!` does at an implicit child. Without this
          # branch advertised a bare object for a position the contract still held to every nested member it
          # declared: the document was looser than the runtime, and the same contract spelled with a dotted `on:`
          # emitted it correctly (PRO-3399).
          #
          # PRO-3405: the conjoin runs whenever `member_prop` exists, not only when `merged_members` came back
          # non-empty. `merged_explicit_members`'s gates (the node must nest; every colliding member must be
          # object-shaped) answer a DIFFERENT question — whether to carry the member down for a deeper hop's
          # member-of-a-member test — and the conjunction itself needs neither: conjoin_shape_member_property
          # already knows how to combine two object-shaped properties (a keyword union) and how to combine
          # anything else (a sibling `allOf` branch), so a member the node "cannot nest" rides alongside as its
          # own `allOf` branch rather than being dropped.
          #
          # For an untransformed node the merge precedes descent: the nested pass reads `child_prop[:properties]` to
          # decide whether a generated `<leaf>_id` still needs writing, and `apply_implicit_node!` reads it again
          # to place a blocked merge's obligation on the member's own property. Merging afterwards left both of
          # them looking at a property the member's contribution had not reached yet.
          #
          # `member_configs`/`own_configs` (the collision's two sides, as ROUTE lists — `emitted_members` and
          # `[representative]` here) let `conjoin_shape_member_property` judge each side's DECLARED type before
          # trusting its emitted property as an exact constraint worth conjoining — see that method for the two
          # separate reasons a side can be untrustworthy (a transform, or an unknown class) and how each is
          # handled, and for how the same judgment recurses through `merge_emitted_maps` for a name colliding one
          # level down. `emitted_members` are the members of the routes the parent's property was built from
          # (`property_routes`), plus the carried ones; `members` (every ancestor config) stays for nullability just
          # below, an ENFORCED question.
          #
          # `null` survives only when every non-model route tolerates nil (runtime enforces all of them), EVERY
          # colliding shape member tolerates nil
          # too — merged or not, since a member this node declined to merge is still enforced, and a non-nullable
          # one forbids nil however permissive the node's own declaration is — and no required descendant is
          # stranded, a nil node yielding every descendant absent (PRO-2857), so a required one below it forbids
          # nil even for a non-object node whose subfield shape isn't nested here. The members are read via
          # nil_allowed?, the predicate `apply_implicit_node!` reads them with, never sniffed off the emitted
          # property: an untyped nil-tolerant member emits no `type`, leaving no null branch to find.
          def apply_explicit_child!(prop, key, node, representative, non_model_configs, members, emitted_members, ann)
            merged_members = merged_explicit_members(node, members)
            member_prop = prop[:properties][key]
            child_prop = conjoined_route_property(representative, non_model_configs)
            # Descendants of a transformed value belong to its post-transform contract. Finish that
            # subtree before the collision can stand it down; otherwise descent rewrites the retained
            # wire type and attaches post-transform children to it.
            if member_prop && transforms_wire_value?([representative])
              child_prop = conjoin_shape_member_property(member_prop, child_prop, member_configs: emitted_members, own_configs: [representative]) do |projected|
                apply_nested_subfields!(projected, node, ann)
              end
            else
              child_prop = conjoin_shape_member_property(member_prop, child_prop, member_configs: emitted_members, own_configs: [representative]) if member_prop
              apply_nested_subfields!(child_prop, node, ann, carried: merged_members)
              child_prop = emitted_input_property(child_prop, representative) unless member_prop
            end
            # A route carrying `preprocess:` is NOT exempted from its own `nil_allowed?` here, though the Proc
            # runs on a `nil` (and an absent) value too, and a constant `preprocess: ->(_) { "x" }` rescues it. That
            # is the one stated exception to a transformed value saying less than the runtime: its requiredness and
            # nullability stay as declared, since reflection cannot tell a nil-rescuing Proc from the far more
            # common nil-preserving one (`->(v) { v.strip }`) without running it, and dropping both from every
            # preprocessed field would stop the schema saying a field must be sent at all. A value supplied for a
            # missing one is `default:`'s job, and that the schema reflects.
            null_ok = non_model_configs.all? { |c| nil_admitted_with_gates_closed?(c) } &&
                      members.all? { |m| nil_admitted_with_gates_closed?(m) } &&
                      !subtree_requires_presence?(node, ann)
            reject_null!(child_prop) unless null_ok
            prop[:properties][key] = child_prop.compact
          end

          # The nested twin of `build_input`'s own model branch — its own method rather than another key
          # folded into `apply_children!`'s single already-large loop body, which the conflict/reconciliation
          # logic here had pushed past this file's complexity budget. Mutates `prop`/`required_model_ids` in
          # place, exactly as the inlined code it replaces did.
          #
          # `derived: false` is a child of a merged node's transforming route whose lookup reads past a declared
          # sibling id: the Proc's output supplies the token, so the sibling keeps exactly the property and
          # requiredness it declares and nothing of the model is added to it.
          def apply_model_id_child!(child_loop, key, node, model_configs, derived: true)
            # The id key derives from the LEAF wire segment (a dotted model name digs `<leaf>_id` off
            # the same nested parent at runtime). A user may declare an explicit NON-model nested
            # `<field>_id` subfield — its own entry in `children`, keyed by that same id, visited
            # independently of this one — and it always wins the property, so `model_id_property` is
            # skipped rather than built and discarded: for an ActiveRecord model that call dispatches
            # `primary_key`/`type_for_attribute` (PRO-3384), and there is no reason to pay that (or the
            # DB/schema access behind it) for a result an explicit sibling is about to replace anyway.
            #
            # Gated on `explicit_id`, not merely `sibling_node`'s presence: a sibling node whose OWN
            # field is itself a `model:` (e.g. `company_id, model: ...` beside `company, model: ...`)
            # never writes to THIS key at all — it emits its own generated id one level deeper
            # (`company_id_id`) — so treating its mere existence as "something will write here" skipped
            # the only thing that would have.
            id_field = Internal::FieldConfig.model_id_key(key)
            sibling_node = child_loop.children[id_field]
            explicit_id = sibling_node&.configs&.find { |c| !c.validations[:model] }
            # A `shape:` member on the PARENT (`parent_configs`) can ALSO claim `id_field` by name — a
            # wire-property source `apply_structured_schema!` merges into `prop[:properties]` BEFORE this
            # method ever runs (called from `build_property`, ahead of `apply_nested_subfields!`), entirely
            # outside the subfield tree `children` searches: `field :company_id, type: String` inside a
            # `do...end` block beside `expects :company, on: ..., model: { id_type: Integer }` left
            # `explicit_id` nil (no SUBFIELD sibling exists), so the model's own property was built and then lost to
            # the shape member's, with nothing deciding between them.
            #
            # Searched among the routes the parent's property was built FROM (`property_routes`) plus the members
            # carried from a shallower hop — the ancestor's shape reaches this node's property too (PRO-3399), so a
            # carried `field :company_id, type: String` claims the key exactly as one on the node's own route does,
            # and leaving the carry out would discard the declared `id_type:` one level up.
            explicit_id ||= emitted_shape_member_at(child_loop.prop, property_routes(child_loop.parent_configs), child_loop.carried, id_field)
            return unless derived || explicit_id.nil?

            if explicit_id
              # Deferred rather than merged here directly (see the post-loop pass in `apply_children!`):
              # this sibling's OWN entry in `children` hasn't necessarily been visited yet, so
              # `prop[:properties][id_field]` isn't guaranteed to hold its FINAL emission until every key
              # in this loop has run.
              child_loop.model_id_siblings << [id_field, model_configs, explicit_id]
            elsif !child_loop.prop[:properties].key?(id_field)
              id_type = reconciled_model_id_type_token(model_configs)
              _, subprop = model_id_property(model_configs.first, id_type)
              child_loop.prop[:properties][id_field] ||= subprop
            end
            return if node_optional?(node, child_loop.ann, model_configs)
            # A sibling id whose default supplies the lookup token on the omitted call rescues it, by the one
            # predicate the annotation credit and the declaration guard share.
            return if sibling_id_rescued?(child_loop.children, key, node)

            if node_optional?(node, child_loop.ann, model_configs.reject { |c| requiredness_conditionally_relaxable?(c) })
              child_loop.prop[:properties][id_field] = with_gated_requirement(child_loop.prop[:properties][id_field], model_configs)
              return
            end

            child_loop.prop[:required] << id_field.to_s
            child_loop.required_model_ids << id_field
          end

          # The `shape:` member claiming `id_field`, but ONLY where that member's property was actually EMITTED
          # — asked of `prop[:properties]` itself rather than inferred from which route declared it.
          #
          # Declaring a member and emitting one are not the same thing, and the gap is what this guards: a member
          # is found by `shape_members_at` whether or not anything of it reached the document (a gated `shape:`,
          # or a route whose transform stood it down). Treating such a member as the sibling that claims the key
          # skipped the generated id property, and the
          # deferred `merge_model_id_type_into_sibling!` pass then found nothing at that key to merge into:
          # `id_field` came out `required` with no entry in `properties` at all, which JSON Schema reads as "any
          # value permitted" — looser than emitting nothing, and the same failure the route restriction here was
          # originally written to prevent.
          #
          # A `prop[:properties]` question rather than a route question, because it is the one the emitter can
          # actually answer at this point: a shape member's property is written by `build_property` (and the
          # ancestor merge) strictly before `apply_children!` runs, while a subfield SIBLING at the same key is
          # found through `children` above and has already set `explicit_id` by the time this is reached.
          def emitted_shape_member_at(prop, routes, carried, id_field)
            return nil unless prop[:properties].key?(id_field)

            shape_members_at(carried.empty? ? routes : routes + carried, id_field).first
          end

          # An implicit node (a dotted-path intermediate with no declaration of its own) emits a bare object
          # property whose only content is its children. When a `shape:` member of any `parent_configs`
          # claims the key, merge into it only if EVERY colliding member is `nestable_as_object?` — the SAME
          # predicate on the SAME member configs that blocking_ancestor? uses (it scans ALL of
          # the node's configs), so emission and the drop pass agree: a non-nestable member (a scalar, or a
          # mixed union like `type: [Hash, Array]`) on ANY route blocks and its deep configs stay in
          # dropped_deep_subfields rather than forcing a self-contradictory property. The block is judged from
          # the member configs directly, NOT from a pre-seeded property: a member whose property never reached
          # the document (a gated `shape:`, or a route whose transform stood it down) seeds nothing to collide
          # with, yet must still block (matching SubfieldTree, which scans every config).
          #
          # A blocked merge omits the deep SHAPE but not the deep OBLIGATION: runtime validates the dropped
          # subfields regardless of representability, so when the dropped subtree requires presence
          # (subtree_requires_presence? — the same predicate used everywhere) the colliding member's own
          # property still inherits that obligation. The member is forced required and its `null` admission
          # stripped (reject_null! handles both `type:` arrays and `anyOf` unions) — because a nil/absent
          # member strands the required descendant (PRO-2857). Nothing else about the member is touched (no
          # forced object type, no properties — its shape stays dropped). An all-optional dropped subtree
          # strands nothing, so the member keeps its declared flags (runtime accepts omission/nil there).
          def apply_implicit_node!(prop, key, node, parent_configs, ann)
            members = shape_members_at(parent_configs, key)
            if members.any? { |member| !nestable_as_object?(member) }
              if subtree_requires_presence?(node, ann)
                prop[:required] << required_key(key)
                reject_null!(prop[:properties][key]) if prop[:properties][key]
              end
              return
            end

            # Carry the (all-nestable) colliding members as the parent configs for this node's own children,
            # so a deeper implicit hop tests their NESTED shape members (a member-of-a-member). Same members
            # the drop pass carries, so the two agree at depth.
            existing = prop[:properties][key]
            target = existing || {}
            target.delete(:format)
            target[:properties] ||= {}
            target[:required] ||= []
            apply_children!(target, node.children, members, ann)
            target[:required] = target[:required].uniq
            # An implicit intermediate's annotation is nullable exactly when nothing beneath requires presence (a
            # nil parent digs every descendant to nil, PRO-2857). With no colliding member, that same condition
            # means nothing at this key rejects a value that is not an object either: a descendant read off a
            # String or a number settles absent too (PRO-2886) — and so does one whose only required descendants
            # read by `method_call:`, which accept whatever answers the method (`subtree_requires_object?`). So such
            # a node adds only its `properties`, which JSON Schema applies to an object alone, and states no `type`
            # of its own — whatever the key already carries (a `model:` route's generated id, a declared type's
            # member placeholder) keeps its own. A `method_call:` descendant is the exception to "settles absent":
            # it reads a method off whatever is there, and what that method returns is checked, so that is named.
            #
            # A colliding shape member changes none of that: the property it already emitted states its own type
            # and nullability, which the member enforces whatever the dotted descendants read. An untyped member, or
            # one whose type check is gated, admits a String the descendants read as absent, so the node is made an
            # object only where something beneath it requires one — the same rule as with no member at all.
            if ann[node].nullable || !subtree_requires_object?(node, ann)
              target = record_residue(target, METHOD_READ_RESIDUE) if subtree_reads_methods?(node)
            else
              target[:type] = "object"
            end
            target[:required] = nil if target[:required].empty?
            prop[:properties][key] = target.compact
            prop[:required] << required_key(key) if ann[node].required
          end

          # Each nested model route's residues, named once the id's property is final, whichever declaration wrote it.
          # `explicit_ids` maps an id key to the declaration that owns it (`apply_model_id_child!`'s `explicit_id`).
          def name_model_lookups!(prop, children, ann, explicit_ids)
            children.each do |key, node|
              next if node.implicit?

              model_configs = node.configs.select { |c| c.validations[:model] }
              next if model_configs.empty?

              explicit_id = explicit_ids[Internal::FieldConfig.model_id_key(key)]
              name_model_routes!(prop[:properties], key, model_configs, descendants: descendants_reject_nil_ancestor(node.children, ann), explicit_id:)
            end
          end
        end
      end
    end
  end
end
