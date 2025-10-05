## Evaluation of ERROR_MODEL.md Migration Plan

### Overall Assessment
**Rating: Strong** – The plan is well-structured, comprehensive, and addresses the core pain point (message parsing in tolerant mode) while maintaining strict-mode compatibility. The phased migration reduces risk and the structured error model is sound.

---

### Strengths

1. **Single Source of Truth**
   - Centralizing error representation in `Toxic.Error` eliminates dual maintenance (messages + heuristics).
   - `format/1` and `to_reason_tuple/1` ensure strict parity tests remain unchanged.

2. **Predictable Recovery**
   - Pattern matching on `error.code` + `details` is cleaner and more maintainable than parsing iodata.
   - Current `adjust_recovery/5` already has ~15 message-parsing helpers that will be eliminated.

3. **Incremental Migration**
   - Starting with Driver (Phase 1) isolates the high-churn area while keeping leaf modules stable.
   - `ensure_struct/1` bridge allows mixed old/new during transition.

4. **Backward Compatibility**
   - Strict mode remains unchanged at API level (reason tuples preserved).
   - Optional `error_token_payload` option future-proofs external consumers.

5. **Code Coverage**
   - The 52 error cases in ERRORS.md map cleanly to ~40 structured codes.
   - Domain grouping (`:terminator`, `:interpolation`, etc.) provides natural organization.

---

### Potential Pitfalls & Mitigations

#### 1. **Message Parity Fragility**
**Issue**: Maintaining exact Elixir message parity in `format/1` across all 40+ codes is error-prone. Small deviations (punctuation, spacing, pluralization) will break `test/toxic_erros_test.exs`.

**Mitigation**:
- Add a **message snapshot test suite** during Phase 0: for each code, capture the expected Elixir message from current Driver reason builders and assert `Toxic.Error.format(error) == expected_message`.
- Use property-based testing to verify format/1 never returns empty messages.
- Document message templates with Elixir version notes (e.g., Elixir 1.19+ changes bidi error text).

**Recommendation**: Create `test/toxic/error_format_test.exs` in Phase 0 that locks down message strings before refactoring producers.

---

#### 2. **Details Map Schema Drift**
**Issue**: `details` is untyped (`map()`), allowing inconsistent keys across codes (e.g., `start_line` vs `opening_line`). This breaks pattern matching in `adjust_recovery/5`.

**Mitigation**:
- **Option A (Strict)**: Use a union of typed structs per domain:
  ```elixir
  @type details ::
    %Terminator{opening: atom, expected: atom, closing: atom, hint_line: pos_integer | nil} |
    %Interpolation{kind: atom, delim: charlist, start_line: pos_integer, ...} |
    ...
  ```
  Pro: Compile-time safety, dialyzer catches mismatches.
  Con: More boilerplate, harder to extend.

- **Option B (Pragmatic)**: Keep `map()` but add a **details validator** per code:
  ```elixir
  defp validate_details(:terminator_mismatched_closer, details) do
    assert Map.has_key?(details, :opening_delimiter)
    assert Map.has_key?(details, :expected_delimiter)
    # ...
  end
  ```
  Call in `Toxic.Error.new/1` or via ExUnit helper.

**Recommendation**: Start with Option B (faster iteration) and migrate to Option A if dialyzer coverage becomes critical.

---

#### 3. **Position Handling Complexity**
**Issue**: The `position` field is `position | nil`, but many errors need position for messages (e.g., "starting at line X"). The plan doesn't clarify when `position` is populated vs. extracted from `details`.

**Current State**: Driver reason builders compute positions from state (`state.line`, `state.column`) and meta tuples. After migration, who owns position calculation?

**Mitigation**:
- **Guideline**: Always populate `position` when the error is constructed at the emission site (Driver, Terminator). Leave `nil` only for errors that propagate position via `details` (e.g., missing terminator at EOF uses `start_line`/`start_column` from `details`).
- Update `to_reason_tuple/1` to merge `position` into the meta keyword list (`:line`, `:column`, `:end_line`, `:end_column`) for strict parity.

**Recommendation**: Add a field comment in the struct:
```elixir
# position: span of the error trigger (e.g., the unexpected closer)
#           May be nil if error is contextual (e.g., EOF missing terminator)
position: position | nil,
```

---

#### 4. **Tolerant Recovery Ambiguity**
**Issue**: Section "Tolerant Mode Integration" lists recovery patterns but doesn't specify **when synthesis still happens** vs. when it's skipped.

**Example**:
- Unexpected closer (`)`) with `insert_structural_closers: true` → synthesize `(` **before** or **after** error token?
- Plan says "after error" but current `emit_error_and_advance` has complex `pre_inserted`/`post_inserted` logic that isn't mapped to codes.

**Mitigation**:
- Add a **`recovery_hint` field** to `Toxic.Error`:
  ```elixir
  @type recovery_hint ::
    {:consume, non_neg_integer} |  # consume N codepoints
    {:synthesize_before, [token]} |
    {:synthesize_after, [token]} |
    {:skip_to_sync} |
    :none

  recovery_hint: recovery_hint | nil
  ```
  This makes recovery intent explicit and testable.

- Alternatively, keep `recovery_hint` outside the struct (in `adjust_recovery` only) but **document** the pattern per code in ERROR_MODEL.md.

**Recommendation**: Add a "Recovery Behavior" column to the error code table in ERROR_MODEL.md:
```markdown
| Code                              | Recovery                          |
|-----------------------------------|-----------------------------------|
| terminator_unexpected_closer      | synthesize opener after error     |
| terminator_mismatched_closer      | synthesize expected closer after  |
| keyword_missing_space_after_colon | consume `:` only                  |
| identifier_mixed_script           | sanitize + insert identifier      |
```

---

#### 5. **Migration Phase Order Risk**
**Issue**: Phase 2 (Terminator) runs before Phase 3 (String/Sigil/Interpolation), but terminator errors often reference string context (e.g., missing `}` in interpolation). If Terminator emits structs but Interpolation still emits tuples, the bridge gets messy.

**Current Flow**:
1. Interpolation detects missing `}` → returns `{:error, reason_tuple}`
2. Driver catches it → calls `missing_interpolation_reason/2` → emits error token

After Phase 2, Terminator emits structs but Interpolation tuples still flow through Driver's bridge.

**Mitigation**:
- **Reorder**: Swap Phase 2 and Phase 3. Migrate Interpolation/String/Sigil first (they are leaf error producers), then Terminator (which aggregates context).
- **Rationale**: Interpolation errors (`interpolation_missing_terminator`, `string_missing_terminator`) are simpler (fewer details) and don't depend on terminator stack state.

**Recommendation**: Revise migration order to:
1. Phase 0: Scaffolding
2. Phase 1: Driver (reason builders only)
3. **Phase 2: String/Sigil/Heredoc/Interpolation** (leaf producers)
4. **Phase 3: Terminator** (context aggregator)
5. Phase 4: Tokenizer/Identifier/Number/Keyword/Alias
6. Phase 5: Cleanup

---

#### 6. **Test Coverage Gaps**
**Issue**: Plan mentions "add formatter parity tests" and "assert `error_token` payload `code`" but doesn't specify **which subset** of 40+ codes gets explicit tests.

**Risk**: Untested codes may have silent message regressions or recovery bugs.

**Mitigation**:
- **Mandatory Coverage**: Every code must have:
  1. One strict-mode test verifying `to_reason_tuple/1` message parity (already covered by `test/toxic_erros_test.exs` post-migration).
  2. One tolerant-mode test verifying `error.code` and recovery behavior (new tests in `test/toxic_tolerant_mode_test.exs`).

- **Test Generator**: Add a helper that takes an error code + sample input and asserts:
  ```elixir
  defp assert_error_code(input, expected_code, opts \\ []) do
    tokens = tokenize_tolerant(input, opts)
    error_token = Enum.find(tokens, &match?({:error_token, _, _}, &1))
    assert {:error_token, _meta, %Toxic.Error{code: ^expected_code}} = error_token
  end
  ```

**Recommendation**: Add to Phase 0:
> - Scaffold `test/toxic/error_code_test.exs` with one test per domain (10 tests total).
> - In Phase 5, expand to full code coverage (40+ tests).

---

#### 7. **Ensure_struct/1 Bridge Complexity**
**Issue**: `ensure_struct/1` must handle **all legacy shapes**:
- Old atoms: `{:error, :vc_marker}` (no meta, no message)
- Old tuples: `{meta_kw, message, token_chars}`
- Mixed: `{:error, reason_tuple}` from propagated errors

**Risk**: Incomplete pattern matching causes runtime crashes during migration.

**Mitigation**:
- **Exhaustive Patterns**: Document all input shapes in `ensure_struct/1` docstring and add guards:
  ```elixir
  def ensure_struct(%Toxic.Error{} = err), do: err
  def ensure_struct({meta_kw, msg, tok}) when is_list(meta_kw), do: from_reason_tuple(...)
  def ensure_struct(atom) when is_atom(atom), do: from_legacy_atom(atom)
  def ensure_struct(other), do: raise "Unknown error shape: #{inspect(other)}"
  ```
- Add **fallback logging** during bridge period to detect unmapped shapes:
  ```elixir
  def ensure_struct(other) do
    IO.warn("Unmapped error shape: #{inspect(other)}")
    %Toxic.Error{code: :syntax_error, details: %{legacy: other}}
  end
  ```

**Recommendation**: Add to Phase 0:
> - Implement `ensure_struct/1` with exhaustive patterns and fallback.
> - Add unit tests covering all legacy shapes from ERRORS.md.

---

#### 8. **Dialyzer Type Safety**
**Issue**: Plan doesn't mention dialyzer/typespecs. Current Driver has minimal specs; after migration, `Toxic.Error.t()` will flow through all error paths.

**Risk**: Type mismatches (e.g., `details` map vs expected struct) won't be caught until runtime.

**Mitigation**:
- Add `-spec` for key functions:
  ```elixir
  @spec format(t()) :: iodata()
  @spec to_reason_tuple(t()) :: {keyword(), iodata(), iodata() | []}
  @spec ensure_struct(term()) :: t()
  ```
- Run `mix dialyzer` in CI after each phase.
- Use `@opaque` for internal `details` if switching to typed structs later.

**Recommendation**: Add to Phase 5:
> - Add comprehensive typespecs to `Toxic.Error` and all reason builders.
> - Run `mix dialyzer --halt-exit-status` in CI.

---

### Improvements

#### 1. **Error Code Namespacing**
Currently codes are flat atoms (`:terminator_unexpected_closer`). As the codebase grows, consider **namespacing**:
```elixir
@type code ::
  {:terminator, :unexpected_closer | :mismatched_closer | :missing_closer} |
  {:interpolation, :missing_terminator | :not_allowed} |
  ...
```
**Pros**: Clearer grouping, easier pattern matching (`{:terminator, _}`).
**Cons**: More verbose, breaks flat atom simplicity.

**Recommendation**: Keep flat atoms for Phase 0-4 (simpler migration). Revisit if error categories exceed 10 domains.

---

#### 2. **Severity Field Usage**
Plan includes `:severity` but only mentions `:error` | `:warning`. Current Driver already emits warnings via `Toxic.Scope.prepend_warning/4` (e.g., charlist deprecation, unnecessary quotes).

**Opportunity**: Unify warnings under `Toxic.Error` with `severity: :warning`:
- Emit `{:warning_token, meta, %Toxic.Error{severity: :warning, code: :charlist_deprecated}}`
- Tolerant mode can filter/preserve warnings based on options.

**Recommendation**: Add to Phase 5 (after core error migration stable):
> - Migrate warning emissions to `Toxic.Error` structs.
> - Add `preserve_warnings: boolean()` option to TokenStream.

---

#### 3. **Error Aggregation for Batch Reporting**
Some editors want **all errors** in a file, not just the first. Tolerant mode enables this but requires collecting error tokens.

**Enhancement**: Add a `TokenStream.errors/1` helper:
```elixir
def errors(%TokenStream{} = stream) do
  stream
  |> to_list()
  |> Enum.filter(&match?({:error_token, _, _}, &1))
  |> Enum.map(fn {:error_token, meta, error} -> {meta, error} end)
end
```

**Recommendation**: Add to Phase 5 as a utility (not migration-critical).

---

#### 4. **Documentation Examples**
ERROR_MODEL.md includes one end-to-end example (mismatched delimiter). Add **2-3 more** covering:
- Identifier sanitization with mixed script
- Map `%(` with percent emission
- Missing interpolation `}` with heredoc context

This helps implementers visualize the full flow.

**Recommendation**: Expand "Example End-to-End" section in ERROR_MODEL.md with:
- Identifier mixed script → sanitization
- Keyword `foo:bar` → consume `:` only
- String `"#{foo` at EOF → synthesize `}` and `"`

---

### Final Recommendations Summary

| Priority | Action | Phase |
|----------|--------|-------|
| **High** | Add message snapshot tests (`error_format_test.exs`) | Phase 0 |
| **High** | Reorder phases: String/Interpolation before Terminator | Plan update |
| **High** | Document recovery behavior per code (add table column) | ERROR_MODEL.md |
| **Medium** | Add `details` validation (Option B: map validator) | Phase 0 |
| **Medium** | Clarify `position` field usage (add struct comment) | Phase 0 |
| **Medium** | Implement exhaustive `ensure_struct/1` with fallback | Phase 0 |
| **Medium** | Add error code coverage tests (`error_code_test.exs`) | Phase 0 & 5 |
| **Low** | Add dialyzer specs and CI check | Phase 5 |
| **Low** | Expand end-to-end examples in ERROR_MODEL.md | Documentation |
| **Future** | Unify warnings under `Toxic.Error` | Phase 6 (post-migration) |

---

### Conclusion

The migration plan is **sound and well-scoped**. The main risks are:
1. **Message parity drift** (mitigate with snapshot tests)
2. **Details schema inconsistency** (add validation)
3. **Recovery ambiguity** (document per-code behavior)

With the recommended additions to Phase 0 (tests, validation, documentation) and the phase reordering, the migration is **low-risk and high-value**. The structured error model will make tolerant mode maintainable and extensible for future error categories (e.g., macro expansion, type hints).

**Verdict**: Proceed with plan after incorporating Phase 0 scaffolding enhancements and documentation updates.
