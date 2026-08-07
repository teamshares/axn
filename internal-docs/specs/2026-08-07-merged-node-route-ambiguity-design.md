# A merged wire node picks its supplying config by declaration order (PRO-3068)

/ Linear: https://linear.app/teamshares/issue/PRO-3068/axn-a-merged-wire-node-picks-its-supplying-config-by-declaration-order

## Problem

Two subfield declarations can reach the same wire node by different spellings of one route, and the node then holds both configs. Two consumers pick one of those configs by `configs.first` — so declaration order, and nothing else, decides which config's transform supplies the value.

The first consumer is parent resolution. `ContractForSubfields._reader_config` (`contract_for_subfields.rb:72`) is `node.configs.first`, and `_deepest_reader_name` (`:82`) reads it whenever the deepest reader-bearing ancestor is not the config's own `on:` anchor. So a descendant whose `on:` crosses a merged node resolves through whichever route was declared first, and swapping two lines that both describe the same wire slot silently changes the value the descendant sees.

The second is the model lookup token. `sibling_id_configs` (`:465`) picks `candidates.find { |c| usable_id_token_default?(c) }` — the first-declared defaulted route on a merged `<field>_id` node — and `_declared_id_token` then reads that route's reader to supply the finder. The comment there leans on PRO-2901 to rule the ambiguity out ("PRO-2901 forbids two defaults on one node, so this is the node's one default"), which is the only thing standing between that `find` and an order-dependent lookup.

This is released behaviour, not a regression. The reflected wire path does not move either way — both spellings name the same node — so nothing in the emitted schema flags it.

## What the probe found

Every line below was run, not reasoned, on this branch.

The defect reproduces with nothing but two spellings, and flips on line order alone:

```
expects :baz, on: "foo.bar", as: :b1, preprocess: -> { merge(src: "route-1") }
expects :baz, on: :bar,      as: :b2, preprocess: -> { merge(src: "route-2") }
expects :src, on: "foo.bar.baz"

  dotted route declared first  → src == "route-1"
  reader route declared first  → src == "route-2"
```

A merge requires `as:` on one side, and cannot be built on one spelling at all — so two spellings of one route is the only construction that reaches a merged node:

```
two `expects :baz` on different spellings, no as:  → ArgumentError: expects does not support
                                                     duplicate sub-keys (`baz` is already defined)
same on:, same field, two distinct as:             → DuplicateFieldError: Duplicate field(s)
                                                     declared: cid
```

That second rejection is `_duplicate_fields`' key (`contract.rb:741`), which is `[c.on.to_s, canonical_wire_key(c.field)]` — keyed on the SPELLING of the route rather than the resolved node. The merged node exists because of that, not by design.

A dotted tail is only load-bearing over an UNDECLARED intermediate. Over a declared one it is redundant with `on: :reader`, and that redundancy is the whole defect:

```
expects :count, on: "payload.meta"   # meta UNDECLARED (implicit node) → legal, and unwritable any other way
expects :count, on: "payload.bar"    # bar DECLARED → legal, and identical to `on: :bar`
```

Instrumenting the tree walk and running the whole suite (5344 examples, 0 failures) counts every dotted tail that crosses a declared node — 142 events, 26 distinct declarations:

```
tail crosses a DECLARED node, single config                    22
  …single config, some route carries a transform                3
  …crosses a MERGED node, no route carries a transform          1     (`:y on: "bar.baz.x"`)
  …crosses a MERGED node, some route carries a transform        0
```

So nothing in the suite exercises the bug, and exactly one fixture crosses a merged node at all. It appears at two call sites (`spec/axn/internal/subfield_tree_spec.rb:225` and `spec/axn/internal/reflection/schema_spec.rb:4022`).

A merged node whose configs share ONE reader name is order-INDEPENDENT, so the ambiguity is about reader names rather than config count. A `confirmation:` companion beside the author's own same-named declaration is exactly that shape, and the declaration wins by `reader_rank` regardless of order:

```
expects :password, on: :bar, confirmation: true, preprocess: -> { merge(src: "companion") }
expects :password_confirmation, on: "foo.bar", preprocess: -> { merge(src: "declaration") }
expects :src, on: "foo.bar.password_confirmation"   → "declaration"
```

On the model lookup side, the borrowed token is found by WIRE KEY, so an `as:`-renamed route on a different spelling than the model still supplies it:

```
expects :company_id, on: "payload.thing", as: :other_id, optional: true, default: 7
expects :company, on: :thing, model: { klass: ProbeCo, finder: :find }
call(payload: { thing: { other: 1 } })   → company.id == 7
```

There is no way to point the model at a particular id route: `ModelValidator.apply_syntactic_sugar` (`validation/validators/model_validator.rb:9`) accepts `klass` and `finder` only, the wire key is always `<field>_id`, and the generated reader is always `<reader_as>_id`.

At depth 0 that borrowing is not cross-route at all, because every top-level config has `on: nil` and so matches the model's own route:

```
top-level model config on: nil
sibling_id_configs      → [[:company_id, :co_id, nil]]
own_route matches       → true
```

`apply_inbound_defaults!` no longer exists. Defaults resolve on the read path per config (`executor.rb:244`, PRO-2903/2908), so PRO-2901's user-facing message — "the first-declared default writes the wire key; every later route then sees the key present and is silently skipped" — describes a mechanism that was deleted.

## Decisions

### 1. Reject the ambiguous REFERENCE, not the observed divergence

A dotted `on:` tail may not cross a node whose configs carry more than one distinct reader name.

The alternative was a taxonomy of value-supplying declarations (`preprocess:`, `default:`, `model:`, `method_call:`, `coerce:`) and a rejection only when the crossed node's routes provably differ. That is strictly worse: it cannot decide coercion driven by the `coerce_input_types` setting rather than an explicit `coerce:`, two Procs can never be compared, and every future value-affecting kwarg has to be added to the list or it silently reopens the hole. Rejecting the reference needs none of that, and it is the rule `_validate_subfield_reader_names!` already applies to duplicate readers, which raises even when both would have worked.

### 2. The crossing predicate is extracted, not re-derived

`_deepest_reader_name` computes the anchor's chain index inline (`path.parent_index - (config.on.to_s.split(".").size - 1)`). That expression, and the `reader_index != anchor_index` comparison built on it, move to one seam on `ContractForSubfields` that both the runtime resolver and the declaration check read. A second derivation in the check is the drift this repo has been bitten by before.

Crossing is exactly "a dotted tail over a reader-bearing node": the anchor's node always bears a reader, and only tail segments sit between the anchor index and the `on:` target, so `reader_index > anchor_index` is unreachable without a dotted tail. A config anchored ON a merged node — `on: :b2`, or `on: "b2.deeper"` — takes the named branch and stays legal.

### 3. Shared-reader-name nodes are exempt by mechanism, not by carve-out

When every config at the crossed node answers to one reader name, `configs.first.reader_as` is that name whichever order they were declared in, and `_read_deepest_reader` dispatches it through the reader-owner rule — whose order-independence `SubfieldTree.yields_reader_name?` already documents and relies on. The confirmation-companion pair measured above is that case, and it needs no special-casing to stay legal.

### 4. Ambient subfields are exempt, because they resolve by a different mechanism

Ambient configs never enter the shared tree, so `resolve_parent` falls through to `_resolve_parent_by_recipe`: the `on:` root is read through its reader (which names one config) and every tail segment is a raw dig (which reads no reader at all). No route is ever picked, so the check cannot apply. `_check_ambient_subfield_contradictions!` (`ambient_context.rb:62`) opts out explicitly rather than the check inferring it from the synthetic ambient root, which a top-level field named `ambient_context` would defeat.

### 5. The model's lookup token is whatever the public `<field>_id` reader yields

`sibling_id_configs`' order-picked `default_route` is replaced by the route that OWNS the canonical `<field>_id` reader name — `model_id_key(model_config.reader_as)`, the name the model's own generated companion answers to. Reader names are unique, so that selects at most one config; `own_route` is unique too, since a second config with the same `on:` and the same wire key is a duplicate-field error. Both selectors become structurally single-valued, so nothing is left to pick by order and this half of the ticket needs no rejection at all.

The final `[candidates.first]` fallback goes with it. A lone id route that owns the canonical name is already selected by name; a lone route that does NOT own it is an alias the author never pointed at the model, and `sibling_id_configs` returning empty makes the caller read the wire key raw — which is the honest answer when no named reader claims the id.

This is what PRO-2910 was reaching for through ordering rules. The generated `<field>_id` reader and the finder token stop merely agreeing and start sharing a source.

### 6. Why the borrowed alias is worth removing

The observable effect of `default: 7` on a route the author named `other_id` is a 7 appearing under the generated `company_id` reader and in the finder — which reads like the default was written into `provided_data`. It is not: the wire stays pristine, so serialization, async enqueue arguments, `_memoized_raw_extract` and raw-read facets all still see the slot absent, and a third route declaring `company_id` resolves its own value.

The accurate diagnosis is that the model has no reader of its own for the id, so it borrows one — the same unnamed cross-route read as decision 1, one level down. Naming it correctly is what keeps the canonical case legal: when the defaulted route owns the reader `company_id`, the borrowed reader is the one the author declared under that exact name, and PRO-2910's "the token agrees with the `<field>_id` reader" is an explicit promise rather than a hidden coupling. Post-PRO-2903 there is no such thing as "the wire slot's default" for the invisible case to appeal to — only "reading via `other_id` yields 7."

### 7. Reflection narrows in lockstep

`sibling_id_rescued?` (`reflection/schema.rb:551`) and `SubfieldContradictions#model_omittable?` both ask `configs.any? { usable_id_token_default? }` today. Both must ask it of the own-route/name-owner config instead, or the schema will credit a rescue the runtime no longer performs. `credit_sibling_id_defaults!` reads through `sibling_id_rescued?` and follows for free.

This is also what keeps the behaviour change from landing silently: an action whose omitted record used to resolve via an aliased off-route default now resolves nil, and at the same moment its generated `<field>_id` stops being credited as rescued and starts reflecting as required.

### 8. PRO-2901's blanket two-default rejection is deleted

`check_conflicting_defaults!`, `raise_conflicting_defaults!` and `describe_default` go. Two differently-defaulted readers over one wire slot become legal — one raw with a String default, one coerced with an Integer default is a coherent contract, and each reader resolves its own default on its own read path.

The node-level justification does not survive inspection: `node_optional?`'s satisfiability credit gets MORE accurate with two defaults, since both routes then rescue an omitted slot. The one place two defaults genuinely bit was the order-picked lookup token, and decision 5 removes the pick rather than the declaration. Deleting the check outright (rather than rewriting its stale rationale) also matches the pre-alpha convention of removing dead guards instead of tombstoning them.

### 9. `model: { id_reader: … }` is noted, not built

Under decision 5 the only unexpressible contract is "look this model up through an aliased id route that is neither the model's own route nor the canonical name owner." Reaching it requires deliberately aliasing the id AND putting it on a different spelling than the model, and both merged-id fixtures in the suite put the transforming route beside the model, which own-route selection honours natively. An `id_reader:` option in the model bag is a clean additive escape hatch if a real consumer turns up; it is not built on speculation.

## Surfaces to thread

`lib/axn/core/contract_for_subfields.rb` — extract the crossing seam out of `_deepest_reader_name`; replace `default_route` in `sibling_id_configs` and drop its `candidates.first` fallback; rewrite the route-precedence comment.

`lib/axn/core/contract/subfield_contradictions.rb` — add the crossing check to `check!`, ordered after `check_unanswerable_segments!` (an unreachable path moots any ambiguity on it) and before `check_dead_nil_tolerance!`; delete the conflicting-defaults check and its two helpers; narrow `model_omittable?`.

`lib/axn/internal/reflection/schema.rb` — narrow `sibling_id_rescued?`.

`lib/axn/core/ambient_context.rb` — opt the ambient tree out of the crossing check.

## Testing

Rule 1, the crossing: the ticket's repro rejected; both remedies accepted (`on: :b2`, and dropping one route's transform); a crossed node with no transform anywhere ALSO rejected, which is decision 1's whole point; a tail over an implicit intermediate accepted; a tail over a single-config declared node accepted; a crossed confirmation-companion node accepted; a config anchored on a merged node by reader name accepted, including `on: "b2.deeper"`; an ambient dotted tail crossing a merged ambient node accepted; the rejection fires regardless of which order the crossing and the merge are declared in, since `check!` re-scans the whole candidate tree.

Two existing fixtures move: `subfield_tree_spec.rb:225` and `schema_spec.rb:4022` both declare `expects :y, on: "bar.baz.x"` over a merged `:baz`. Both become `on: "<route-1 reader>.x"`, which preserves each example's actual point — that route 2's non-nestable shape member still blocks the deep structure even though the deep config attached through route 1.

Rule 2, the lookup token: an aliased off-route defaulted id no longer rescues an omitted record, and the generated `<field>_id` reflects as required in the same contract; a canonically-named off-route defaulted id still rescues; the model's own route still wins over any other route, present token or default. `on_subfields_spec.rb:2272` ("still rescues an ABSENT merged id via a different route's credited default") inverts — it is the direct expression of the behaviour decision 5 removes, and its remedy is one word: declare the default on the model's own route, or leave the id unaliased.

Staying green, verified as unaffected: `on_subfields_spec.rb:2196` and `:2530` (both id routes aliased, model prefers its own route); `:2691` and `:2705` (aliased id on the model's own route, PRO-2910's transform agreement); `top_level_write_back_spec.rb:725` (top-level aliased id, where `on: nil` on both sides makes the declared id the own route).

PRO-2901's specs: the two-literal-defaults and two-Proc-defaults rejections become acceptances, and `subfield_contradictions_spec.rb:474`'s node grows a crossing descendant to keep a rejection example on the same shape. `on_subfields_spec.rb:2819` (the merged-defaults node carrying a `model:` and a `method_call:` descendant) inverts to an acceptance: its model sits on `:thing` and so does the defaulted `thing_company_id` route, which makes that route the own route and the lookup unambiguous — the example should assert 42 supplies the token. Its fixture comment also appeals to the deleted write-back ("untyped, so an opaque parent refuses the write-back") and needs rewriting to the read-path mechanism.

## Out of scope

The emitted property at a merged node is built from `property_representative` (the first non-model config) and its generated `<leaf>_id` from `model_configs.first`, so `of:`, `shape:`, `default:` and the description are all declaration-order-dependent in reflection. That is pre-existing, deliberately specced as an accepted divergence (`property_name_collision_spec.rb:2903`), and orthogonal to value supply — but deleting the two-default rejection widens exposure to it, so it gets its own ticket rather than silence.

Requiring `on:` to name a reader and nothing else would make the crossing structurally impossible, and was rejected: an implicit intermediate has no reader to name, so `expects :count, on: "payload.meta"` over an undeclared `meta` would become unwritable, every intermediate would have to be declared (acquiring a contract of its own in the process), and merely typing an intermediate later would retro-raise every deep reference to it.

## Docs and changelog

`[BREAKING]` against `v0.1.0.pre.alpha.5.1`, two entries: a dotted `on:` may no longer cross a merged node (remedy: anchor on the route's reader), and a model's `<field>_id` lookup token now comes from the route that owns the canonical `<field>_id` reader or the model's own route, so an `as:`-renamed route on another spelling no longer supplies it. The relaxation — two `default:` declarations on one merged node — is a non-breaking note in the same release.

The subfield docs need the invariant stated where dotted `on:` is introduced: a dotted tail addresses a NODE, and a node is not a route.
