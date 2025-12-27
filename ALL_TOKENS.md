# Toxic Token Reference

This document lists all token shapes that Toxic can emit.
It covers:

- **Streaming (linear) tokens** produced by `Toxic.next/1`
- **Collapsed/legacy tokens** produced by `Toxic.Legacy.collapse_linear_ranges/1`
  and `Toxic.Legacy.ranges_to_legacy/1`

All token descriptions below are verified against the current implementation
(`lib/toxic/*.ex`) and tests under `test/`.

## Common Schema

- Every **streaming token** uses ranged metadata:
  - `meta :: {{start_line, start_col}, {end_line, end_col}, extra}`
  - Line/column are 1-based; end position is exclusive.
- Unless stated otherwise:
  - All tokens are 3-tuples: `{type, meta, extra}`
  - `extra` is `nil` for simple tokens
  - `extra` is a value for tokens with payloads (identifiers, literals, operators)
  - `extra` is a tuple for multi-part payloads (e.g. `not in`, sigils, heredoc ends)
- `meta.extra` is token-specific:
  - Numbers: parsed numeric value (`integer` or `float`)
  - Many identifiers/atoms: original charlist (`~c"..."`) or `nil`
  - Newline/semicolon/comma: coalesced EOL count
  - String-like starts/ends: usually `nil`

---

## Streaming Tokens (Linear Output)

These are the tokens you see from the streaming API:

```elixir
{:ok, token, stream} = Toxic.next(stream)
```

### Literals

- `{:int, meta, chars}`
  - Integer literal (`123`, `0x1F`, `0b1010`, `0o777`, with `_` separators).
  - `meta.extra` – parsed integer value (e.g. `291` for `0x123`).
  - `chars` – original charlist (e.g. `~c"0x123"`).

- `{:flt, meta, chars}`
  - Float literal (`1.23`, `1.0e-10`, with `_` separators).
  - `meta.extra` – parsed float value (e.g. `1.23e4`).
  - `chars` – original charlist (e.g. `~c"1.23e4"`).

- `{:char, meta, codepoint}`
  - Character literal (`?a`, `?\n`, `?\\0`, etc.).
  - `meta.extra` – original representation as charlist
    (e.g. `~c"?a"`, `~c"?\\n"`).
  - `codepoint` – integer codepoint (e.g. `?\n`).

### Atoms, Keywords & Reserved Words

- `{:atom, meta, atom}`
  - Colon-prefixed atoms (`:foo`, `:ok`, operator atoms like `:++`).
  - `meta.extra` – original charlist for the atom when available,
    or `nil` (e.g. operator atoms).

- `{:kw_identifier, meta, atom}`
  - Keyword identifier before `:` in `key: value`.
  - `atom` – keyword name as atom (e.g. `:foo` for `foo:`).
  - `meta.extra` – original charlist for the key (or `nil` for operator keys).

- `{true, meta, nil}`, `{false, meta, nil}`, `{nil, meta, nil}`
  - Reserved literals `true`, `false`, `nil`.

- `{:do, meta, nil}`, `{:end, meta, nil}`, `{:fn, meta, nil}`
  - Block delimiters and anonymous function keyword.

- `{:block_identifier, meta, atom}`
  - Block labels: `after`, `else`, `catch`, `rescue`.
  - `atom` – one of `:after | :else | :catch | :rescue`.

### Identifiers & Aliases

- `{:identifier, meta, atom}`
  - Regular identifiers and operator-as-identifier (e.g. `foo`, `my_var`, `==/2` as name).
  - `meta.extra` – original charlist, or `nil` when not tracked.

- `{:paren_identifier, meta, atom}`
  - Identifier immediately followed by `(` (call-like: `foo(`).

- `{:bracket_identifier, meta, atom}`
  - Identifier immediately followed by `[` (`list[` or `foo[`).

- `{:do_identifier, meta, atom}`
  - Identifier rewritten by the driver when followed by a valid `do` block
    (e.g. `if`, `case`, `try` when used with `do`).

- `{:op_identifier, meta, atom}`
  - Identifier rewritten from a space-sensitive dual operator used in identifier position
    (e.g. `def +/2`).

- `{:alias, meta, atom}`
  - Module alias (`Foo`, `MyApp.Context`, etc.).
  - `meta.extra` – original charlist for the alias (`~c"Foo"`).

### Operators

All operator tokens share the general shape:

```elixir
{operator_type, meta, op_atom}
```

`meta.extra` is typically `nil` or a coalesced EOL count used for layout-sensitive behavior.

- `{:unary_op, meta, op}`
  - Unary operators: `:!`, :`^`, and deprecated `:"~~~"`.

- `{:dual_op, meta, op}`
  - Space-sensitive `+` / `-` that can be unary or binary.

- `{:mult_op, meta, op}`
  - Multiplicative operators: `:*`, `:/`.

- `{:rel_op, meta, op}`
  - Relational operators: `:<`, `:>`, `:<=`, `:>=`.

- `{:comp_op, meta, op}`
  - Comparison operators: `:==`, `:!=`, `:=~`, `:===`, `:!==`.

- `{:and_op, meta, op}`
  - Boolean/bitwise AND: `:&&`, `:&&&`, `:and`.

- `{:or_op, meta, op}`
  - Boolean/bitwise OR: `:||`, `:|||`, `:or`.

- `{:xor_op, meta, op}`
  - Bitwise XOR: `:^^^` (deprecated).

- `{:concat_op, meta, op}`
  - Concatenation operators: `:++`, `:--`, `:+++`, `:---`, `:<>`.

- `{:arrow_op, meta, op}`
  - Arrow-like operators:
    - `:|>`, `:~>`, `:<~`
    - `:<<<`, `:>>>`, `:~>>`, `:<<~`, `:<~>`, `:"<|>"`

- `{:power_op, meta, op}`
  - Power operator: `:**`.

- `{:range_op, meta, op}`
  - Range operator: `:..`.

- `{:in_match_op, meta, op}`
  - Match-ish operators: `:<-`, `:"\\\\"`.

- `{:type_op, meta, op}`
  - Type operator: `:"::"`.

- `{:stab_op, meta, op}`
  - Stab operator: `:->`.

- `{:match_op, meta, op}`
  - Match operator: `:=`.

- `{:pipe_op, meta, op}`
  - Pipe operator: `:|`.

- `{:ellipsis_op, meta, op}`
  - Ellipsis operator: `:...`.

- `{:ternary_op, meta, op}`
  - Ternary separator operator: `://`.

- `{:assoc_op, meta, :"=>"}}`
  - Map association operator `=>`.

- `{:at_op, meta, :@}`
  - Module attribute operator `@`.

- `{:capture_op, meta, :&}`
  - Capture operator `&` (when not followed directly by a digit without space).

- `{:capture_int, meta, :&}`
  - Capture-arity marker `&N` (e.g. `&1`); the integer `N` itself is a separate `:int` token.

### Keyword Operators (`when` / `in` / `not in`)

- `{:when_op, meta, :when}`
  - Guard `when` operator.

- `{:in_op, meta, :in}`
  - `in` operator for guards/comprehensions.

- `{:in_op, meta_span, {:"not in", in_meta}}`
  - Combined `not in` operator.
  - `meta_span` – covers the full `not in` span.
  - `in_meta` – meta for the `in` keyword position within the combined operator.

### Punctuation & Delimiters

- `{:., meta, nil}`
  - Dot operator used for field access / remote calls (`foo.bar`).

- `{:dot_call_op, meta, :.}`
  - Dot-call operator for anonymous function invocation (`foo.(args)`).
  - Emitted when `.` is immediately followed by `(`.

- `{:",", meta, nil}`
  - Comma separator.
  - `meta.extra` – coalesced EOL count when the comma also serves as an EOL marker (e.g. `",\n"`).

- `{:";", meta, nil}`
  - Semicolon separator.
  - `meta.extra` – coalesced EOL count when the semicolon also serves as an EOL marker (`";\n"`).

- `{:"<<", meta, nil}`, `{:">>", meta, nil}`
  - Bitstring open/close (`<<` / `>>`).

- `{:"(", meta, nil}`, `{:")", meta, nil}`
  - Parentheses.

- `{:"[", meta, nil}`, `{:"]", meta, nil}`
  - Square brackets.

- `{:"{", meta, nil}`, `{:"}", meta, nil}`
  - Braces (tuples/maps).

- `{:%, meta, nil}`
  - Percent for maps/structs (`%`).

- `{:%{}, meta, nil}`
  - `%{` map opener token, emitted together with a `{:"{", ...}` token to match Elixir behavior.

### Strings, Charlists & Interpolation (Linear)

These tokens represent the **linearized** form of string-like constructs.

#### Starts & Ends

- `{:bin_string_start, meta, ?\"}`
  - Start of a double-quoted binary string (`"..."`).

- `{:bin_string_end, meta, ?\"}`
  - End of a binary string.

- `{:list_string_start, meta, ?'}`
  - Start of a single-quoted charlist (`'...'`).

- `{:list_string_end, meta, ?'}`
  - End of a charlist.

#### Interpolation Markers & Fragments

- `{:string_fragment, meta, binary}`
  - Literal text chunk inside any interpolated context:
    - Regular strings
    - Sigils
    - Heredocs
    - Quoted atoms / keywords / identifiers
  - `binary` – UTF-8 binary fragment; for heredocs/sigil heredocs, the leading
    newline that Elixir prepends is stripped in the driver to avoid position drift.

- `{:begin_interpolation, meta, kind}`
  - Start of `#{...}` interpolation inside a string-like construct.
  - `kind :: :string | :charlist | :atom_safe | :atom_unsafe | :bin_heredoc | :list_heredoc | :sigil | :quoted_identifier`.

- `{:end_interpolation, meta, kind}`
  - End of an interpolation for the given `kind`.
  - May be synthesized in tolerant mode when a closer is missing.

### Heredocs (Linear)

- `{:bin_heredoc_start, meta, [?", ?", ?"]}`
  - Start of binary heredoc (`"""..."""`).

- `{:list_heredoc_start, meta, [?', ?', ?']}`
  - Start of list (charlist) heredoc (`'''...'''`).

- `{:bin_heredoc_end, meta, {[?", ?", ?"], indent}}`
  - End of binary heredoc.
  - `indent` – computed indentation level.

- `{:list_heredoc_end, meta, {[?', ?', ?'], indent}}`
  - End of list heredoc.
  - `indent` – computed indentation level.

### Sigils (Linear)

- `{:sigil_start, meta, {sigil_atom, delim}}`
  - Start of sigil (`~r/.../`, `~S"""..."""`, etc.).
  - `sigil_atom` – e.g. `:sigil_r`, `:sigil_s`, `:sigil_S`, `:sigil_M`.
  - `delim` – closing delimiter:
    - For regular sigils: a one-byte binary `<<"/">>`, `<<"[">>`, `<<"\"">>`, etc.
    - For heredoc sigils: `<<"\"\"\"">>` or `"'''"`.

- `{:sigil_end, meta, {delim, indent}}`
  - End of a sigil.
  - `delim` – closing delimiter:
    - For regular sigils: integer codepoint (e.g. `34` for `?"`, `47` for `?/`).
    - For heredoc sigils: charlist (e.g. `~c"\"\"\""`).
  - `indent` – indentation for heredoc-style sigils, or `0` / `nil` for non-heredoc sigils.

- `{:sigil_modifiers, meta, modifiers}`
  - Sigil trailing modifiers as a charlist (`~c"iu"` for `~r/foo/iu`).

### Quoted Atoms & Quoted Keywords (Linear)

These appear while the tokenizer is in the interpolated string mode for atoms/keywords.

- `{:atom_safe_start, meta, delim}`, `{:atom_unsafe_start, meta, delim}`
  - Start of a quoted atom (`:"foo"` style).
  - `delim` – quote character, typically `?"` or `?'`.
  - `:atom_safe_start` is used when `existing_atoms_only: true`; otherwise `:atom_unsafe_start`.

- `{:atom_safe_end, meta, delim}`, `{:atom_unsafe_end, meta, delim}`
  - End of a quoted atom (with/without interpolation).

- `{:kw_identifier_safe_end, meta, delim}`, `{:kw_identifier_unsafe_end, meta, delim}`
  - End of a quoted keyword identifier (`"foo":` style).
  - `delim` – quote character.
  - When collapsing, these may become either `{:kw_identifier, ...}` or
    container tokens `:kw_identifier_safe` / `:kw_identifier_unsafe`.

### Quoted Identifiers (Linear)

- `{:quoted_identifier_start, meta, delim}`
  - Start of a quoted identifier (after a dot or sigil):
    - `Module."quoted name"()`
  - `delim` – quote character, typically `?"` or ?' (single quotes deprecated, but supported).

- `{:quoted_identifier_end, meta, delim}`
  - End of a quoted identifier with no immediate `(` / `[` / `do`.

- `{:quoted_paren_identifier_end, meta, delim}`
  - End of quoted identifier immediately followed by `(`.
  - When collapsing, this becomes a `{:paren_identifier, meta, atom}` token.

- `{:quoted_bracket_identifier_end, meta, delim}`
  - End of quoted identifier immediately followed by `[` (e.g. `foo."bar"[...]`).
  - When collapsing, this becomes a `{:bracket_identifier, meta, atom}` token.

- `{:quoted_do_identifier_end, meta, delim}`
  - End of quoted identifier rewritten to `do`-identifier position
    (via driver’s `:transform_into_do_identifier` deferral).
  - When collapsing, this becomes a `{:do_identifier, meta, atom}` token.

- `{:quoted_op_identifier_end, meta, delim}`
  - End of quoted identifier rewritten as operator identifier
    (via driver’s `:dual_op_identifier` deferral).
  - When collapsing, this becomes a `{:op_identifier, meta, atom}` token.

### Structural & Error Tokens

- `{:eol, meta, nil}`
  - End-of-line marker for coalesced newlines.
  - `meta.start` – position of the first newline.
  - `meta.end` – position at the start of the line after the last newline.
  - `meta.extra` – count of consecutive newline groups (1 for a single line break,
    2 for two consecutive line breaks, etc.).

- `{:error_token, meta, %Toxic.Error{}}`
  - Inline error token emitted in **tolerant** mode.
  - `meta` – span from error start to the position after recovery/sync.
  - The error struct carries:
    - `code` – error code atom
    - `domain` – error domain (`:string`, `:terminator`, `:identifier`, etc.)
    - `position` / span (for some errors)
    - `token_display` – display representation
    - `details` – map with domain-specific data
  - May be followed by synthesized structural tokens (e.g. missing closing braces)
    depending on driver configuration.

Note: `{:eof, state}` is **returned by the driver/stream**, but `:eof` is *not*
emitted as a token in the stream.

---

## Collapsed / Legacy Tokens

These tokens are **not** emitted directly by `Toxic.next/1`.
They are produced when you collapse the linear stream using:

- `Toxic.Legacy.collapse_linear_ranges/1` – keeps ranged metas
- `Toxic.Legacy.ranges_to_legacy/1` – converts metas to legacy `{line, column, extra}` format

The shapes below describe the **collapsed** forms (before or after meta conversion).

### Collapsed Strings & Charlists

- `{:bin_string, meta, parts}`
  - Collapsed binary string from a sequence of:
    `:bin_string_start` → `:string_fragment` / interpolations → `:bin_string_end`.
  - `parts :: [binary | interpol_part]`
    - `binary` – literal string chunk.
    - `interpol_part :: {start_meta, end_meta, [token]}` – collapsed interpolation span.

- `{:list_string, meta, parts}`
  - Collapsed charlist string (`'...'`) with the same `parts` structure.

### Collapsed Heredocs

- `{:bin_heredoc, meta, indent, parts}`
  - Collapsed binary heredoc (`"""..."""`).
  - `indent` – indentation used for stripping.
  - `parts` – list of binaries or `interpol_part` entries, with indentation stripped.

- `{:list_heredoc, meta, indent, parts}`
  - Collapsed list/heredoc (`'''...'''`) with the same structure.

### Collapsed Sigils

- `{:sigil, meta, sigil_atom, parts, modifiers, indent, delim}`
  - Collapsed sigil including its content and modifiers.
  - `sigil_atom` – e.g. `:sigil_r`, `:sigil_s`, `:sigil_S`, `:sigil_M`.
  - `parts` – list of binaries and `interpol_part` entries.
  - `modifiers` – charlist (e.g. `~c"iu"`).
  - `indent` – heredoc indentation (`0`/`nil` for non-heredoc sigils).
  - `delim` – closing delimiter (binary).

### Collapsed Quoted Atoms

Depending on content, quoted atoms collapse to either a simple quoted atom
or a container form with parts:

- `{:atom_quoted, meta, atom}`
  - Quoted atom without interpolation (e.g. `:"foo"`, `:''`).
  - `atom` – resulting atom value (`:""`, `:foo`).

- `{:atom_safe, meta, parts}`
  - Quoted atom that was tokenized in a context where only existing atoms are allowed,
    and that required quoting (e.g. multi-part / interpolated content).
  - `parts` – list of binaries and/or `interpol_part` entries.

- `{:atom_unsafe, meta, parts}`
  - Quoted atom in the general case (no `existing_atoms_only` restriction),
    where the content cannot be collapsed into a single atom safely
    (typically interpolated).

### Collapsed Quoted Keywords

- `{:kw_identifier, meta, atom}`
  - Collapsed quoted keyword that simplified to a plain atom key
    (e.g. `"foo":` with no interpolation).

- `{:kw_identifier_safe, meta, parts}`
  - Quoted keyword identifier in `existing_atoms_only` context with interpolated/multi-part content.

- `{:kw_identifier_unsafe, meta, parts}`
  - Quoted keyword identifier in general context with interpolated/multi-part content.

### Collapsed Quoted Identifiers

Collapsed quoted identifiers do **not** use a distinct `:quoted_identifier` token.
After collapsing, they become the same identifier categories as unquoted ones,
with metas adjusted to span from the opening quote to just after the closing quote:

- `{:identifier, meta, atom}`
- `{:paren_identifier, meta, atom}`
- `{:bracket_identifier, meta, atom}`
- `{:do_identifier, meta, atom}`
- `{:op_identifier, meta, atom}`

Where:

- `atom` – name converted from the quoted content (or `:""` for empty).
- `meta.extra` – the closing delimiter (`?"` or `?'`) when produced by `collapse_linear_ranges/1`,
  or other token-specific extra when converted via `ranges_to_legacy/1`.

### Legacy Metadata Conversion (`ranges_to_legacy/1`)

`Toxic.Legacy.ranges_to_legacy/1` converts:

- `meta :: {{sl, sc}, {el, ec}, extra}` → `{sl, sc, extra}`
- Container parts `interpol_part` – both `start_meta` and `end_meta` are converted.

Token shapes remain the same except for metas. One notable case:

- `{:in_op, meta_span, {:"not in", info_meta}}` becomes
  `{:in_op, legacy_meta(meta_span), :"not in", legacy_meta(info_meta)}`.

---

## Notes & Non-Tokens

- `:eof` is a **return tag**, not a token:
  - `{:eof, stream}` (or `{:eof, driver}`) signals end-of-input.
- Comments are handled via a callback (`:preserve_comments` in `Toxic.new/4`)
  and are **not** emitted as tokens (`:comment` / `:comment_eol` do not exist in the token stream).

If you need clarification on any specific token or want examples for a subset
(e.g. all sigil-related tokens), you can cross-check `test/toxic/valid_code_test.exs`
and `test/toxic_test.exs`, which exercise every token shape described here.
