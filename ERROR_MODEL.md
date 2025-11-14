## Toxic Error Model and Migration Plan (Revised)

### Purpose
- **Goal**: Replace brittle, message-parsing tolerant recovery with a structured error model that is the single source of truth for both strict-mode error tuples and tolerant-mode error tokens.
- **Outcome**: Tolerant handlers pattern match on error codes instead of parsing messages; strict mode still emits Elixir-compatible messages generated from the structured model to preserve test parity.

### Design Principles
- **Single source of truth**: All errors are first-class data (struct) with a code and parameters; all text messages are rendered from the struct.
- **Compatibility**: Strict mode continues returning Elixir-style `{:error, reason_tuple, rest, state}`. Tolerant mode carries the struct inside `{:error_token, meta, error_struct}`.
- **Predictable recovery**: Tolerant recovery matches on `error.code` (and required `details`) — no string parsing.
- **Schema discipline**: Define a clear per-code contract for `details`; validate inputs to avoid drift.
- **Linear, ranged stream**: Keep tokens flat and ranged. Structural insertions remain optional and have zero-length metas.
- **Parity guardrails**: Add message snapshot tests to lock exact Elixir message parity.

### Structured Error Model
```elixir
defmodule Toxic.Error do
  @moduledoc """
  Structured error used across strict and tolerant modes.
  The module is the authoritative documentation for error codes and details.
  """

  @type domain ::
          :terminator | :interpolation | :string | :heredoc | :sigil |
          :identifier | :keyword | :map | :number | :alias | :reserved |
          :encoding | :comment | :vc | :general

  @type severity :: :error | :warning

  @type code ::
          # Terminators
          :terminator_unexpected_closer | :terminator_mismatched_closer |
          :terminator_missing_closer | :reserved_unexpected_end |
          # Interpolation/String/Sigil/Heredoc
          :interpolation_missing_terminator |
          :interpolation_not_allowed_in_quoted_identifier |
          :string_missing_terminator | :heredoc_missing_terminator |
          :heredoc_invalid_header | :sigil_invalid_name | :sigil_invalid_delimiter |
          # Map & Keyword
          :map_unexpected_space_after_percent | :map_invalid_open_delimiter |
          :keyword_missing_space_after_colon | :keyword_do_with_fn_invalid |
          # Identifier/Alias/Reserved
          :identifier_empty | :identifier_mixed_script | :identifier_confusable |
          :identifier_nfkc_needed | :identifier_unexpected_token |
          :identifier_invalid_char | :identifier_atom_length_limit |
          :identifier_nonexistent_atom_when_existing_only |
          :alias_invalid_character | :alias_unexpected_paren |
          :reserved_token_used |
          # Number
          :number_trailing_garbage | :number_invalid_float |
          # Encoding/Comment/VC
          :encoding_invalid | :comment_invalid_bidi | :comment_invalid_linebreak |
          :vc_merge_conflict_marker |
          # General fallback
          :unexpected_token | :syntax_error

  @type position :: {{pos_integer, pos_integer}, {pos_integer, pos_integer}}

  @type t :: %__MODULE__{
          code: code,
          domain: domain,
          severity: severity,
          # Span of the immediate error trigger (e.g., the unexpected closer).
          # May be nil for contextual errors whose positions are carried via details
          # (e.g., missing terminator at EOF uses start_line/start_column).
          position: position | nil,
          # Minimal display for the token that triggered the error (e.g. ")", "%(")
          token_display: charlist() | nil,
          # Free-form context used by message formatting and recovery.
          # See per-code details contracts below.
          details: map()
        }

  defstruct code: nil,
            domain: :general,
            severity: :error,
            position: nil,
            token_display: nil,
            details: %{}
end
```

#### Per-code `details` contracts (selected)
Documented in `Toxic.Error` as typespecs and `@doc` clauses; validate at creation time.

```elixir
# Terminator mismatch
@type terminator_mismatched_details :: %{
  opening_delimiter: atom,
  expected_delimiter: atom,
  closing_delimiter: atom,
  hint_line: pos_integer | nil
}

# Missing terminator (scope or context)
@type terminator_missing_details :: %{
  opening_delimiter: atom,
  expected_delimiter: atom,
  start_line: pos_integer,
  start_column: pos_integer
}

# Missing string terminator (may include escape at EOF flag)
@type string_missing_details :: %{
  opening_delimiter: atom,
  expected_delimiter: atom,
  line: pos_integer,
  column: pos_integer,
  end_line: pos_integer,
  end_column: pos_integer,
  suffix_iolist: iolist,
  escape_at_eof?: boolean  # Optional: true if error was triggered by backslash at EOF
}

# Interpolation not allowed in quoted identifier
@type interpolation_in_qid_details :: %{
  delim: charlist() | integer(),
  start_line: pos_integer,
  start_column: pos_integer
}
```

Implementation note: Start with a pragmatic validator per `code` that asserts required keys are present. Consider introducing typed detail structs later if/when dialyzer coverage becomes critical.

### Message Rendering API
```elixir
# Single source of truth for user-facing text
Toxic.Error.format(%Toxic.Error{} = err) :: iodata()

# Strict-mode compatibility
Toxic.Error.to_reason_tuple(%Toxic.Error{} = err) :: {keyword(), iodata(), iodata() | []}

# Migration bridge (accepts old tuple/atom and produces struct)
Toxic.Error.ensure_struct(old_reason) :: %Toxic.Error{}
```
- `format/1`: Produces Elixir-compatible text using `code` and `details`.
- `to_reason_tuple/1`: Outputs legacy `{meta_list, message_iodata, token_chars}` for strict-mode parity.
- `ensure_struct/1`: Converts current `{meta, message, token_chars}` or older atoms into a struct. Implement exhaustive patterns with a safe fallback and temporary warning log during migration.

### Recovery behavior per error code
Documenting recovery removes ambiguity and lets tests assert behavior directly.

| Code | Recovery behavior |
|------|-------------------|
| terminator_unexpected_closer | Emit error; if synthesis enabled, synthesize matching opener AFTER error; then emit actual closer; do not consume closer during error span. |
| terminator_mismatched_closer | Emit error; if synthesis enabled, synthesize expected closer AFTER error; leave actual closer to be processed normally next. |
| terminator_missing_closer | At EOF or pending error: emit error; if enabled, synthesize expected closer and pop one stack frame; repeat until cleared. |
| reserved_unexpected_end | Emit error; consume `end` keyword (and optional newline) to prevent stray `:end` token in stream. |
| interpolation_missing_terminator | Emit error; if enabled, synthesize `{:end_interpolation, ...}` AFTER error and pop frame. |
| interpolation_not_allowed_in_quoted_identifier | Emit error; consume interpolation sequence minimally; continue quoted identifier. |
| string_missing_terminator | Emit error; if enabled, synthesize `{:_end, ...}` (bin/list/sigil/quoted identifier end) AFTER error. |
| heredoc_invalid_header | Emit error; if enabled, synthesize appropriate heredoc end AFTER error. |
| map_unexpected_space_after_percent | Emit `%` token BEFORE error; error spans the offending `{}` header; resume normally. |
| map_invalid_open_delimiter | Emit `%` token BEFORE error; error consumes the invalid `(` or `[`; subsequent `(` or `[` tokenizes normally. |
| identifier errors in map context | When identifier error follows `%{}` or `{` token: pre-insert synthetic `%` token before error to preserve map structure for downstream tools. |
| keyword_missing_space_after_colon | Emit error at `:`; consume only `:` so following identifier remains. |
| alias_unexpected_paren | Emit error at `(`; still emit `:(` token after error to preserve call boundary. |
| unexpected_token (ternary missing slash) | Special case for `..//` pattern without trailing `/`: Emit error, then post-insert `{:identifier, meta, :..//}` token with zero-length meta AFTER error to preserve operator structure. |
| number_trailing_garbage | Emit error covering the full malformed number span; do not salvage partial numeric token; resume at sync. |
| number_invalid_float | Emit error covering exponent suffix; resume at sync. |
| encoding/comment/VC (invalid chars, bidi, VC marker) | Emit error; advance minimally (1 cp) or to configured sync (newline/space) depending on category; do not alter terminator stack. |
| consecutive semicolons | Emit error at the second `;`; then emit a single `;` token and consume extra. |

Notes:
- "AFTER error" means tokens appear in the stream after the `:error_token` (zero-length metas for synthetic tokens).
- When synthesis is disabled, synthetic tokens are omitted; ordering of remaining tokens remains consistent.
- **Closer consumption**: To guarantee forward progress, unexpected and mismatched closers may be consumed during error recovery. The actual closer is then re-inserted with zero-length meta after the error and any synthetic tokens. This ensures the stream is balanced while maintaining deterministic advancement.

### How messages are built (parity with Elixir)
- Provide a formatter clause per `error.code` matching current text. Where Elixir versions differ (e.g., bidi/linebreak messages), document version notes and gate tests accordingly.
- Add a message snapshot suite to lock strings before migrating producers.

### Tolerant Mode Integration
- `emit_error_and_advance/3` and pending-EOF paths attach `%Toxic.Error{}` to `:error_token`.
- `adjust_recovery/5` pattern matches on `error.code` and validated `details` (no string parsing). The temporary bridge `Toxic.Error.ensure_struct/1` converts legacy tuples during migration.
- Optional future enhancement: a non-persistent `recovery_hint` derived inside `adjust_recovery` (not stored on the struct) if additional clarity is needed for complex cases.

### Strict Mode Integration
- Producers create `%Toxic.Error{}`; strict callers convert via `to_reason_tuple/1` and return the legacy shape unchanged. Existing tests remain valid.

### Migration Plan (Phased)
- **Phase 0 – Scaffolding (plus guardrails)**
  - Add `Toxic.Error` with struct, `format/1`, `to_reason_tuple/1`, `ensure_struct/1`.
  - Implement per-code `details` validators (Option B) and document details via `@doc`/typespecs.
  - Add message snapshot tests: `test/toxic/error_format_test.exs` to assert `format/1` parity for representative samples.
  - Add error-code scaffold tests: `test/toxic/error_code_test.exs` with one test per domain, asserting `error.code` from tolerant mode. Expand to full coverage in Phase 5.
  - Implement exhaustive `ensure_struct/1` with a safe fallback logging unmapped shapes.

- **Phase 1 – Driver adoption (low churn, high impact)**
  - Refactor Driver reason builders (`missing_*_reason`, `mismatched_delimiter_reason`, `interpolation_in_quoted_identifier_reason`) to build `%Toxic.Error{}`.
  - Strict: convert to reason tuples via `to_reason_tuple/1`.
  - Tolerant: store struct in `:error_token`; update `adjust_recovery/5` to branch on `error.code`.

- **Phase 2 – String/Sigil/Heredoc/Interpolation (leaf producers)**
  - Migrate `lib/toxic/string.ex`, `lib/toxic/sigil.ex`, `lib/toxic/interpolation.ex` to structured errors.
  - Ensure details include `kind`, `delim`, `start_line`, `start_column` for suffix messages and synthesis.

- **Phase 3 – Terminator**
  - Migrate `lib/toxic/terminator.ex` to structured errors with delimiter details and indentation hints.

- **Phase 4 – Tokenizer, Identifier, Number, Keyword, Alias**
  - Convert remaining producers (`tokenizer.ex`, `identifier.ex`, `number.ex`, `keyword.ex`, `alias.ex`).

- **Phase 5 – Cleanup & hardening**
  - Remove message-parsing helpers from Driver; keep only code-based recovery.
  - Expand message snapshot and error-code tests to cover all codes (40+).
  - Add dialyzer specs for `Toxic.Error` APIs and builder functions; enable CI check (`mix dialyzer --halt-exit-status`).
  - Centralize documentation: make `Toxic.Error` the authority; update `ERRORS.md` to reference/generated-from it.
  - Utilities: add `Toxic.errors/1` to collect all error tokens for editor UIs.

- **Phase 6 – Optional: unify warnings**
  - Represent warnings with `%Toxic.Error{severity: :warning, code: ...}` and emit `{:warning_token, meta, error}`. Add stream options to preserve/filter warnings.

### Backwards compatibility and options
- Strict mode API unchanged; reason tuples preserved.
- Tolerant mode: default `:error_token` payload becomes a struct. Provide `error_token_payload: :struct | :tuple | :both` for external consumers that expect tuples.

### Testing Strategy
- Keep current strict suite (`test/toxic_erros_test.exs`) — should stay green post-migration.
- Keep tolerant suite (`test/toxic_tolerant_mode_test.exs`) — it mostly asserts token kinds and ordering.
- Add:
  - `error_format_test.exs`: snapshot tests for message parity per code.
  - `error_code_test.exs`: asserts tolerant payload `code` and recovery behavior for each domain initially, all codes by Phase 5.
  - Helper for tolerant assertions:

```elixir
defp assert_error_code(input, expected_code, opts \\ []) do
  tokens = tokenize_tolerant(input, opts)
  error_token = Enum.find(tokens, &match?({:error_token, _, _}, &1))
  assert {:error_token, _meta, %Toxic.Error{code: ^expected_code}} = error_token
end
```

### Example end-to-end flows
```elixir
# 1) Mismatched delimiter: "([)"
%Toxic.Error{code: :terminator_mismatched_closer,
  domain: :terminator,
  token_display: ~c")",
  details: %{opening_delimiter: :"[", expected_delimiter: :"]", closing_delimiter: :")"}}
# Strict -> reason tuple; tolerant -> error token; recovery synthesizes "]" AFTER error.

# 2) Map invalid opener: "%( ) + x"
# Stream: :%, :error_token (code: :map_invalid_open_delimiter), :"(", :")", :dual_op, :identifier
# Recovery: emit % BEFORE error, consume invalid open, resume.

# 3) Missing interpolation terminator at EOF: """"
# Stream (with synthesis): :begin_interpolation, ... , :error_token (code: :interpolation_missing_terminator),
# :end_interpolation (synthetic), :error_token (code: :string_missing_terminator), :bin_string_end (synthetic)

# 4) Identifier mixed script: "foo«cyrillic_a»bar + 1"
# Stream: :error_token (code: :identifier_mixed_script), optional sanitized :identifier,
# :dual_op, :int
```

### Conclusion
This revision clarifies `details` contracts and validation, specifies recovery behavior per code, adds parity guardrails with message snapshot tests, reorders migration to reduce bridge complexity, and outlines stronger test and type-safety plans. The result is a low-risk path to a maintainable, predictable tolerant mode while preserving strict-mode compatibility and message parity.


## Fixes needed after Phases 0-4

  • I’ll address the reviewer’s Phase 0–4 gaps: complete key formatters, add a minimal details validator, and start
    transitioning recovery to code-based checks for a few top cases without breaking behavior.
  • Changes to make now:
    • Complete high-impact formatters in Toxic.Error.format/1:
      • Add clauses for: :string_missing_terminator, :heredoc_missing_terminator, :sigil_invalid_name,
        :sigil_invalid_delimiter, :comment_invalid_bidi, :comment_invalid_linebreak, :vc_merge_conflict_marker,
        :number_trailing_garbage, :identifier_invalid_char, :reserved_token_used, :keyword_do_with_fn_invalid,
        :map_unexpected_space_after_percent, :map_invalid_open_delimiter. These directly unblock many strict tests.
    • Add details validation (Option B) in Toxic.Error:
      • Introduce a validate_details!/2 private helper and call it inside to_reason_tuple/1 or a small new/1 constructor
        for common codes we just added. Start with 3 validators used by formatters above (terminator missing, mismatched
        closer, map errors).
    • Begin code-based recovery in Driver for 3 common codes (keep fallback for others):
      • In adjust_recovery/5, first case error.code to handle:
        • :keyword_missing_space_after_colon → consume : only.
        • :map_invalid_open_delimiter → emit % then continue (existing helper).
        • :string_missing_terminator when escape_at_eof? in details → consume newline (no message parsing).
      • Leave remaining cases using existing legacy heuristics to avoid broad changes.
  • What remains (Phase 5 items; not implemented here):
    • Fill remaining format/1 clauses (identifier variants, alias errors, NFKC/confusable messages).
    • Finish code-based recovery for all codes and remove message parsing helpers.
    • Add more validators per code and enable snapshot/code tests; migrate Number.ex to emit a struct.
  • Impact:
    • Reduces strict-mode failures by covering the most frequent message shapes.
    • Starts the shift to code-based tolerant recovery for key paths.
    • Adds a guard against malformed details to prevent runtime mis-match later.
