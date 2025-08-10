### Flat, Linear Token Stream for Interpolation

This document proposes a flat, linear token stream interface that preserves all current token metadata (including explicit ranges) while removing nested token lists produced by interpolation. It keeps backward compatibility by offering both formats and a reversible mapping between them.

---

### Goals
- Provide a Pratt-/LL-friendly flat token stream you can peek and consume in order, without tree-unpacking during lexing.
- Preserve precise, exclusive end-position ranges on all tokens (existing behavior).
- Represent interpolation boundaries and container boundaries with explicit, synthetic marker tokens that carry precise ranges.
- Keep backward compatibility by:
  - Continuing to support the legacy “forest” format (nested lists inside string/atom/sigil parts).
  - Exposing a bidirectional transformer between linear and legacy formats.
- Ensure error-tolerance and incremental reparsing friendliness (stable begin/end spans and stable boundary markers).

---

### Current State
- Strings, charlists, heredocs, sigils, quoted atoms/keywords currently emit a token with a parts list. In those lists, interpolation segments are tuples `{StartMeta, EndMeta, Tokens}` where `Tokens` is a nested token list.
- This creates a forest (list of trees) rather than a single linear stream.
- Ranges exist for many token forms; we already emit explicit exclusive end positions for tokens and interpolation segment metas.

---

### Design Update: Explicit Container Start/End Tokens (no backtracking)
To avoid backtracking and post-hoc meta updates, the tokenizer will emit explicit container start and end tokens for all interpolating containers. This makes implementation simple and streaming-friendly: metas are known at the moment of emission, and no already-emitted token needs to be updated.

#### Containers requiring start/end tokens
- Strings and charlists:
  - `{:bin_string_start, Meta, Delimiter}` and `{:bin_string_end, Meta, Delimiter}`
  - `{:list_string_start, Meta, Delimiter}` and `{:list_string_end, Meta, Delimiter}`
- Heredocs:
  - `{:bin_heredoc_start, Meta, Delimiter}` and `{:bin_heredoc_end, Meta, Delimiter, Indentation}`
  - `{:list_heredoc_start, Meta, Delimiter}` and `{:list_heredoc_end, Meta, Delimiter, Indentation}`
- Sigils (inline and heredoc):
  - `{:sigil_start, Meta, SigilAtom, Delimiter}`
  - `{:sigil_end, Meta, SigilAtom, Delimiter, Indentation | nil}`
  - `{:sigil_modifiers, Meta, Modifiers}` (separate token emitted after `sigil_end`, covering only the modifier span). This avoids updating a prior token when modifiers are discovered.
- Quoted atoms and quoted keywords (the unsafe variants with interpolation):
  - `{:atom_unsafe_start, Meta, Delimiter}` and `{:atom_unsafe_end, Meta, Delimiter}`
  - `{:kw_identifier_unsafe_start, Meta, Delimiter}` and `{:kw_identifier_unsafe_end, Meta, Delimiter}`

All `Meta` are the standard range meta `{{StartLine, StartColumn}, {EndLine, EndColumn}, Extra}` with exclusive end positions. For container start/end:
- Start meta spans the exact opening delimiter (e.g., `"`, `'`, `"""`, `'''`, `%S"`, etc.).
- End meta spans the exact closing delimiter (including heredoc triple quotes). For sigils, modifiers are not part of the `sigil_end` meta; they get their own `sigil_modifiers` token.
- `Extra` for these markers is `nil`.

#### Interpolation markers (unchanged concept)
- `{:begin_interpolation, Meta, Kind}` and `{:end_interpolation, Meta, Kind}`
  - `Kind` ∈ `:string | :charlist | :heredoc | :sigil | :atom | :kw_identifier`.
  - Begin meta spans the literal `#{` (exclusive end after `{`).
  - End meta spans the literal `}` (exclusive end after `}`).

#### Literal fragments between markers
- `{:string_fragment, Meta, Binary}` for literal segments between interpolations (works for strings, charlists, heredocs, and sigils). The payload is the unescaped binary (as in current behavior), while the meta spans the original source.

---

### Linearization Examples

String with interpolation:
```
"foo #{1 + 2} bar"

{:bin_string_start,  MetaOpen, '"'}
{:string_fragment,   MetaFoo,  "foo "}
{:begin_interpolation, MetaHash, :string}
{:int, Meta1, ~c"1"}
{:dual_op, MetaPlus, :+}
{:int, Meta2, ~c"2"}
{:end_interpolation, MetaClose, :string}
{:string_fragment,   MetaBar,  " bar"}
{:bin_string_end,    MetaEnd,  '"'}
```

Sigil with modifiers:
```
~x/a\nsd/iu

{:sigil_start,     MetaStart, :sigil_x, '/'}
{:string_fragment, MetaBody,  "a\nsd"}
{:sigil_end,       MetaEnd,   :sigil_x, '/', nil}
{:sigil_modifiers, MetaMods,  ~c"iu"}
```

Heredoc sigil:
```
~S"""
  body
"""

{:sigil_start,       MetaStart,     :sigil_S, '"""'}
{:string_fragment,   MetaBody,      "body\n"}
{:sigil_end,         MetaEnd,       :sigil_S, '"""', 2}
```

Quoted atom with interpolation:
```
:"a #{1} b"

{:atom_unsafe_start,   MetaStart, '"'}
{:string_fragment,      MetaA,     "a "}
{:begin_interpolation,  MetaHash,  :atom}
{:int, Meta1, ~c"1"}
{:end_interpolation,    MetaRCurly, :atom}
{:string_fragment,      MetaB,     " b"}
{:atom_unsafe_end,      MetaEnd,   '"'}
```

Quoted keyword with interpolation:
```
"a #{1} b":

{:kw_identifier_unsafe_start,  MetaStart, '"'}
{:string_fragment,              MetaA,     "a "}
{:begin_interpolation,          MetaHash,  :kw_identifier}
{:int, Meta1, ~c"1"}
{:end_interpolation,            MetaRCurly, :kw_identifier}
{:string_fragment,              MetaB,     " b"}
{:kw_identifier_unsafe_end,     MetaEnd,   '"'}
{:":", MetaColon}
```

Note on quoted dot call: interpolation in quoted calls is a tokenizer error in Elixir; in such cases we do not emit container/markers and instead return the appropriate error tuple preserving precise spans.

---

### Span Semantics
- All container starts/ends, interpolation begins/ends, and fragments carry exact ranges for their own lexemes.
- Containers themselves no longer need a single wrapper token with a parts list in linear mode. Instead, parsing logic relies on `{*_start, ...}` and `{*_end, ...}` tokens to delineate scope.
- This guarantees zero backtracking: metas are final when tokens are emitted.

---

### Public API Changes

#### New option to request linearization
- Extend options with `{linearize, boolean()}` (default: `false`).
- `tokenize_with_ranges/4` honors `{linearize, true}` and emits a linear stream composed of:
  - Container start/end tokens
  - Fragment tokens between
  - Interpolation markers with inner tokens flat
- Legacy, non-linear mode (default) remains unchanged (nested parts in container values), for backward compatibility.

#### Converters
- `legacy_to_linear/1`: walk legacy tokens, and for each container token with parts, emit the corresponding `{*_start}`, fragments, interpolation markers (recurse into nested tokens), and `{*_end}`; include `sigil_modifiers` as needed.
- `linear_to_legacy/1`: walk flat stream using a small stack to reconstruct containers and parts lists; collect fragments and nested tokens between `{*_start}`/`{*_end}` into the original container token value. Validate markers are properly balanced.

Both functions are pure transforms (no re-lexing).

---

### Changes Required in Tokenizer and Interpolation Modules

#### toxic_tokenizer.erl
- Add a `linearize` flag in scope.
- For containers (strings, charlists, heredocs, sigils, quoted atoms/keywords):
  - If `linearize=false`: keep current behavior (single token with parts list).
  - If `linearize=true`: emit `{*_start}`, then stream fragments and interpolation markers interleaved with inner tokens, and finally emit `{*_end}` (and `sigil_modifiers` when present). No container token carries a parts list in this mode.
- Ensure ranges for `{*_start}` and `{*_end}` match delimiters precisely; heredoc/sigil indentation goes in the `{*_end}` (or as separate info token if desired, but including in end is sufficient).
- For sigils, emit `sigil_modifiers` as its own token to avoid backtracking.

#### toxic_interpolation.erl
- Existing `extract/6` can remain unchanged (returns Parts). The tokenizer, when `linearize=true`, will translate Parts to flat tokens on the fly:
  - For each literal `Part`, emit a `{:string_fragment, ...}`
  - For each interpolation tuple `{StartMeta, EndMeta, Tokens}`, emit `{:begin_interpolation, StartMeta, Kind}`, then the inner tokens (already flat by the outer tokenizer), and then `{:end_interpolation, EndMeta, Kind}`.
- Error paths (missing `}`) unchanged; when `linearize=true`, only partial sequences may be emitted prior to the error.

---

### Error Handling
- Interpolation and delimiter errors already carry `{end_line, end_column}`. The markers and container ends provide exact spans for error highlighting.
- For quoted dot calls with interpolation, the tokenizer raises an error (no linearization of that construct).

---

### Incremental Parsing Considerations
- Edits to container interiors affect only fragments and inner tokens; `{*_start}`/`{*_end}` and interpolation markers remain stable unless delimiters change, enabling reliable diffs.
- Explicit container ends and separate `sigil_modifiers` allow precise span updates without rewriting previously emitted tokens.

---

### Performance Considerations
- Linear mode increases token count (start/end/fragment/markers). The approach is still single-pass and streaming-friendly with no token backtracking.
- Converters are linear in token count.

---

### Backward Compatibility Plan
- Default remains legacy forest. Linear mode is opt-in via `{linearize, true}`.
- Include the two pure converters.
- Add tests for both modes and round-trip invariants.

---

### Testing Plan
- Unit tests for:
  - Strings/charlists/heredocs/sigils with/without interpolation; modifiers and heredoc indentation; multi-line bodies.
  - Quoted atoms and keywords (`atom_unsafe`, `kw_identifier_unsafe`).
  - Adjacent and nested interpolations.
  - Escapes (LF/CRLF) ensuring spans advance correctly.
  - Error cases (interpolation missing `}`, invalid quoted dot call interpolation) verifying correct error spans and that the stream before the error is well-formed.
- Round-trip tests: `legacy |> legacy_to_linear |> linear_to_legacy == legacy` and the reverse on linear streams produced by the tokenizer.

---

### Summary of Deliverables
- New `{linearize, true | false}` option.
- Linear mode emits:
  - Container start/end tokens for all interpolating constructs.
  - Fragment tokens between, and interpolation begin/end markers enclosing inner tokens.
  - A separate `sigil_modifiers` token.
- No token backtracking or meta rewrites required.
- Converters between legacy forest and the linear form.
- Comprehensive tests including ranges and error scenarios.
