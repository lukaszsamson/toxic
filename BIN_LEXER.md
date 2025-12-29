# Binary-Based Lexer Migration Plan

## Executive Summary

This document outlines a plan to migrate the Toxic lexer from charlist-based processing to binary-based processing. The goals are:

1. **Eliminate charlist conversion overhead** - avoid `String.to_charlist/1` at `Toxic.new/4`
2. **Keep Unicode position correctness** - preserve current column semantics (grapheme-aware where Toxic is grapheme-aware today)
3. **Maintain behavioral parity** - the full existing test suite must pass
4. **Improve performance (mostly ASCII-heavy code)** - use binary pattern matching and ASCII fast paths

### Non-goals (for the first migration)

- Do **not** change the public token *shape* or meta invariants.
- Do **not** change error handling semantics (strict vs tolerant) or recovery behavior.
- Do **not** change token payload types by default (many tokens currently carry charlists, while some string fragments already use binaries).

### Success Criteria (definition of “done”)

- `mix test` passes with the binary backend enabled and disabled.
- Token streams are identical (modulo allowed internal-only differences) for a curated corpus and the existing test suite.
- Performance improves for typical Elixir source (ASCII-heavy) without regressing Unicode-heavy cases.

## Current Architecture Analysis

### Input Flow
```
binary input
    |
    v
String.to_charlist/1 (conversion)
    |
    v
Toxic stream (`lib/toxic.ex`) stores remaining input as a charlist
    |
    v
Toxic.Driver.next/2 (`lib/toxic/driver.ex`) consumes 1 token at a time
    |
    v
Toxic.NormalTokenizer.next/5 and Toxic.InterpolationTokenizer.next/* (charlist pattern matching)
    |
    v
Token output (mixed payloads: many charlists; string fragments are binaries)
```

### Key Modules and Their Charlist Usage

| Module | Charlist Usage | Notes |
|--------|---------------|-------|
| `Toxic` | Input conversion, driver_source storage | Entry point |
| `Toxic.Driver` | Rest tracking, contexts | Core state machine |
| `Toxic.NormalTokenizer` | All pattern matching `[?x \| rest]` | Main lexer |
| `Toxic.InterpolationTokenizer` | String/sigil content extraction | String lexer |
| `Toxic.NormalTokenizer.Number` | Number parsing with accumulators | Uses `List.to_integer/2` |
| `Toxic.NormalTokenizer.Comment` | Comment extraction | Simple iteration |
| `Toxic.NormalTokenizer.Identifier` | Identifier tokenization | Calls String.Tokenizer |
| `Toxic.NormalTokenizer.Sigil` | Sigil name/content parsing | |
| `Toxic.String.Tokenizer` (`lib/toxic/unicode/tokenizer.ex`) | **Binary-heavy already** | Unicode identifier validation + normalization tables |
| `Toxic.Util` | `characters_to_binary/1`, `characters_to_list/1` | Conversions |

### Current `:unicode_util.gc` Usage

Located in:
- `lib/toxic/driver/position.ex:21` - Column counting during position updates
- `lib/toxic/driver/position.ex:57` - Grapheme iteration for position calculation
- `lib/toxic/interpolation_tokenizer.ex:308` - Character extraction in strings

These implement **grapheme-cluster-aware advancement** in the places Toxic is already grapheme-aware today:
- tolerant-mode recovery scan/advance (`Toxic.Driver.Position`)
- string interpolation scanning (`Toxic.InterpolationTokenizer`)

Note: the goal is not “zero grapheme ops” (that would break column semantics), but “avoid grapheme ops on the ASCII fast path”.

### Current `:unicode.characters_to_*` Usage

- `Toxic.new/4` - Convert binary to charlist for driver
- `Toxic.Util.characters_to_binary/1` - Charlist to binary
- `Toxic.Util.characters_to_list/1` - Binary to charlist
- `Toxic.String.Tokenizer:476` - NFC normalization
- `Toxic.NormalTokenizer.Identifier:146` - NFKC for confusable detection
- `Toxic.Driver.Recovery` - NFKC for identifier sanitization

## Proposed Architecture

### New Input Flow
```
binary input
    |
    v
Toxic stream stores remaining input as a binary
    |
    v
Toxic.Driver.next/2 consumes binary and dispatches to a binary backend
    |
    v
Binary NormalTokenizer + Binary InterpolationTokenizer
    |
    v
Token output: default payload types unchanged (optional “binary payload mode” can be a later phase)
```

### Binary Pattern Matching Strategy

#### ASCII Fast Path (Common Case)

For ASCII characters, use single-byte patterns:
```elixir
# Old (charlist)
def next([?# | rest], line, column, scope, tokens) do

# New (binary)
def next(<<?#, rest::binary>>, line, column, scope, tokens) do
```

#### UTF-8 Codepoint Extraction

For Unicode codepoints, use `::utf8` specifier:
```elixir
# Old (charlist)
def next([head | tail] = list, ...) when head > 127 do

# New (binary)
def next(<<codepoint::utf8, rest::binary>> = bin, ...) when codepoint > 127 do
```

#### Multi-byte Lookahead

```elixir
# Old (charlist)
def next([?:, ?:, ?: | rest], line, column, ...) do

# New (binary)
def next(<<?:, ?:, ?:, rest::binary>>, line, column, ...) do
```

### Grapheme Cluster Handling

When operating on **binary input**, use `String.next_grapheme/1` for the specific places Toxic currently needs grapheme semantics (position scanning + string extraction), and keep a tight ASCII fast path to avoid calling it for common cases:

```elixir
# New (binary-based)
case String.next_grapheme(rest) do
  {grapheme, new_rest} ->
    # grapheme is a binary (could be multi-codepoint)
    codepoints = String.to_charlist(grapheme)
    # Use first codepoint for classification, count as 1 column
  nil ->
    # End of input
end
```

**Important**: Keep the current semantics: advance by 1 column per grapheme cluster in the places that do grapheme-aware advancement today.

### Token Value Types

Current: Many token payloads use charlists (e.g., `~c"123"` for int original representation), while some string tokens already emit binaries (e.g. `:string_fragment`).

Plan for success: keep token payload types unchanged by default during the migration. If emitting binaries for numeric/identifier payloads is desired, introduce it as an explicit opt-in later (e.g. `token_payloads: :charlist | :binary`), with a dedicated compatibility pass and clear release notes.

This affects:
- `{:int, meta, original_representation}` - currently charlist
- `{:flt, meta, original_representation}` - currently charlist
- `{:atom, meta, value}` - atom (unchanged)
- `{:bin_string, meta, value}` - will be binary
- Error message formatting

## Migration Phases

### Phase 0: Lock Compatibility Contract (must happen first)

1. Decide and document what is *guaranteed identical* between backends:
   - token kind sequence
   - meta start/end positions and `meta.extra`
   - error token emission and recovery behavior in tolerant mode
   - warning emission (ordering and positions)
2. Decide what is allowed to differ (ideally: nothing user-visible).
3. Add a small “parity harness” test helper that can run both backends over the same inputs and compare token streams.

### Phase 1: Introduce Backend Switch (low risk)

1. Add `lexer_backend: :charlist | :binary` option (default `:charlist`).
2. Thread it into the stream and driver initialization.
3. Ensure the existing charlist path is untouched and remains the reference implementation.

Definition of done:
- Existing tests pass with default settings (charlist backend).
- A minimal “smoke” suite passes for the binary backend (even if incomplete at this phase).

### Phase 2: Binary Driver + Position Tracking (core plumbing)

This phase is primarily about the *input representation* and position advancement, not tokenization rules.

1. Add a binary driver path that:
   - accepts `rest :: binary()`
   - returns `new_rest :: binary()`
   - preserves the existing Driver state machine and output/deferrals semantics
2. Implement binary equivalents in `Toxic.Driver.Position`:
   - `consume_one/2` on binary with ASCII fast path
   - `scan_to_sync/2` on binary with ASCII fast path
   - use `String.next_grapheme/1` only for non-ASCII bytes / when needed

Definition of done:
- A small corpus can be tokenized end-to-end using the binary backend without crashing.
- Column tracking matches the charlist backend for the same inputs.

### Phase 3: NormalTokenizer Conversion (largest surface area)

Convert `lib/toxic/normal_tokenizer.ex` and submodules:

#### 3.1 NormalTokenizer.ex (Main Entry)

Pattern matching conversion for ~150 clauses:

```elixir
# Before
def next([?0, ?x, h | t], line, column, scope, _tokens) when is_hex(h) do

# After
def next(<<?0, ?x, h, rest::binary>>, line, column, scope, _tokens) when is_hex(h) do
```

**Submodule Order:**
1. `NormalTokenizer.Comment` - Simplest, good starting point
2. `NormalTokenizer.Number` - Self-contained, clear patterns
3. `NormalTokenizer.Operator` - Macro-generated guards work unchanged
4. `NormalTokenizer.Terminator` - Minimal changes
5. `NormalTokenizer.Keyword` - Depends on previous
6. `NormalTokenizer.String` - Heredoc header extraction
7. `NormalTokenizer.Sigil` - Sigil name parsing
8. `NormalTokenizer.Alias` - Unicode character validation
9. `NormalTokenizer.Identifier` - Complex, calls String.Tokenizer
10. `NormalTokenizer.Dot` - Depends on several others

#### 3.2 NormalTokenizer.Number Conversion

```elixir
# Before
def tokenize_hex([h | t], acc, length) when is_hex(h) do
  tokenize_hex(t, [h | acc], length + 1)
end

# After
def tokenize_hex(<<h, rest::binary>>, acc, length) when is_hex(h) do
  tokenize_hex(rest, <<acc::binary, h>>, length + 1)
end

# Or use iolist accumulator for efficiency:
def tokenize_hex(<<h, rest::binary>>, acc, length) when is_hex(h) do
  tokenize_hex(rest, [acc, h], length + 1)
end
```

**Number Parsing Strategy:**
- Use `Integer.parse/2` and `Float.parse/1` instead of `List.to_integer/2`
- Accumulate original representation as binary or iolist

#### 3.3 NormalTokenizer.Comment Conversion

```elixir
# Before
def tokenize_comment([?\n | _] = rest, acc) do
  {rest, Enum.reverse(acc)}
end

# After
def tokenize_comment(<<?\n, _::binary>> = rest, acc) do
  {rest, IO.iodata_to_binary(acc)}
end
```

### Phase 4: InterpolationTokenizer Conversion (high risk, string-heavy)

Convert `lib/toxic/interpolation_tokenizer.ex`:

#### 4.1 Buffer Handling

Current approach uses charlist accumulator:
```elixir
def next([char | rest], buffer, ...) do
  next(rest, [char | buffer], ...)
end
```

New approach with iolist accumulator:
```elixir
def next(<<byte, rest::binary>>, buffer, ...) when byte <= 127 do
  next(rest, [buffer, byte], ...)
end

def next(<<codepoint::utf8, rest::binary>>, buffer, ...) do
  next(rest, [buffer | <<codepoint::utf8>>], ...)
end
```

#### 4.2 Grapheme Handling

Replace `:unicode_util.gc/1` in `extract_char/9`:
```elixir
# Before
defp extract_char(rest, buffer, ...) do
  case :unicode_util.gc(rest) do
    [char | new_rest] when is_list(char) ->
      next(new_rest, :lists.reverse(char, buffer), ...)
    [char | new_rest] when is_integer(char) ->
      next(new_rest, [char | buffer], ...)
    [] ->
      next([], buffer, ...)
  end
end

# After
defp extract_char(rest, buffer, ...) do
  case String.next_grapheme(rest) do
    {grapheme, new_rest} ->
      # Check for bidi/break characters on first codepoint
      <<first_cp::utf8, _::binary>> = grapheme
      if bidi(first_cp) or break(first_cp) do
        # Error handling
      else
        next(new_rest, [buffer, grapheme], ...)
      end
    nil ->
      next(<<>>, buffer, ...)
  end
end
```

### Phase 5: Entry Point Updates (remove conversion)

Update `Toxic.new/4` so binary input does not become a charlist, and the stream carries binary rest for the binary backend.

Definition of done:
- With `lexer_backend: :binary`, `Toxic.new/4` does not call `String.to_charlist/1`.
- With `lexer_backend: :charlist`, current behavior remains unchanged.

### Phase 6: Utility Functions and Cleanup

#### 6.1 Update Toxic.Util

```elixir
# Remove or deprecate charlist functions
# Keep binary conversion functions

def unsafe_to_atom(binary, line, column, scope) when is_binary(binary) do
  # Direct binary handling
  case byte_size(binary) do
    len when len > 255 -> {:error, ...}
    _ -> safe_to_atom(binary, scope)
  end
end
```

#### 6.2 Character Classifier Guards

Guards in `Toxic.CharacterClassifier` work with codepoints (integers), so they remain unchanged. They work correctly with both:
- `[head | _]` where head is codepoint
- `<<head, _::binary>>` where head is byte (for ASCII)
- `<<head::utf8, _::binary>>` where head is codepoint

#### 6.3 Strip Functions

```elixir
# Before
def strip_horizontal_space([h | t], counter) when is_horizontal_space(h) do
  strip_horizontal_space(t, counter + 1)
end

# After
def strip_horizontal_space(<<h, rest::binary>>, counter) when is_horizontal_space(h) do
  strip_horizontal_space(rest, counter + 1)
end
```

### Phase 7 (Optional): Token Payload Binaries (explicit opt-in)

Only after parity is proven and performance goals are met:
- Add an opt-in to emit selected payloads as binaries (e.g., numeric original representations).
- Keep the default as today to avoid breaking downstream consumers.

## Avoiding Expensive Unicode Operations

### `:unicode.characters_to_list/1` Elimination

**Location**: `Toxic.Util.characters_to_list/1`

**Solution**: Work directly with binaries, only convert to charlist when absolutely necessary (e.g., for Elixir's `:unicode` NFC normalization which requires charlist input).

### `:unicode_util.gc/1` Replacement

**Locations**:
- `lib/toxic/driver/position.ex` - Column counting
- `lib/toxic/interpolation_tokenizer.ex` - Character extraction

**Solution (binary backend)**: Use `String.next_grapheme/1` which:
- Takes binary input directly
- Returns `{grapheme_binary, rest_binary}`
- Handles all Unicode grapheme cluster rules

**Performance Note**: Even with `String.next_grapheme/1`, still prioritize an ASCII fast path; grapheme decoding should be reserved for non-ASCII bytes.

### NFC Normalization

**Locations**: `Toxic.String.Tokenizer:476`

**Current**: `:unicode.characters_to_nfc_list/1` requires charlist

**Solution**: Use `:unicode.characters_to_nfc_binary/1` which works directly on binaries:
```elixir
# Before
original_acc = :lists.reverse(original_acc)
acc = :unicode.characters_to_nfc_list(original_acc)

# After
acc = :unicode.characters_to_nfc_binary(original_binary)
```

## Testing Strategy

### Test Categories

1. **ASCII-only inputs** - Should work identically, performance improvement expected
2. **Unicode identifiers** - e.g., `привет`, `日本語` - must tokenize correctly
3. **Grapheme clusters** - e.g., `e\u0301` (e + combining accent), emoji sequences
4. **String interpolation** - `"Hello #{name}"` with Unicode content
5. **Heredocs** - Multi-line strings with proper indentation handling
6. **Sigils** - `~r/pattern/`, `~s"string"` with various delimiters
7. **Error recovery** - Malformed Unicode, unexpected bytes

### Compatibility Tests

Run against Elixir tokenizer reference output (optional but valuable):
```elixir
defmodule Toxic.CompatibilityTest do
  # For each test case:
  # 1. Tokenize with :elixir_tokenizer
  # 2. Tokenize with Toxic
  # 3. Compare token streams (accounting for meta format differences)
end
```

### Performance Benchmarks

```elixir
Benchee.run(%{
  "charlist backend" =>
    fn ->
      Toxic.new(large_source, 1, 1, lexer_backend: :charlist)
      |> Toxic.to_stream()
      |> Enum.to_list()
    end,
  "binary backend" =>
    fn ->
      Toxic.new(large_source, 1, 1, lexer_backend: :binary)
      |> Toxic.to_stream()
      |> Enum.to_list()
    end
}, inputs: %{
  "ASCII code" => ascii_heavy_source,
  "Unicode code" => unicode_heavy_source,
  "Mixed" => mixed_source
})
```

## Risk Assessment

### High Risk Areas

1. **Heredoc indentation handling** - Relies on character-by-character iteration
2. **Interpolation state machine** - Complex with many edge cases
3. **Error position reporting** - Column numbers must account for grapheme clusters

### Mitigation

- Comprehensive test suite comparing with Elixir tokenizer
- Incremental migration with feature flags
- Parallel tokenization for verification during development

## API Compatibility

**Initial migration (recommended): no breaking changes**
- Token payloads remain as they are today by default.
- `Toxic.slice/6` already slices binaries; it should continue to work unchanged.

**Potential future breaking changes (only if you opt into “binary payload mode”):**
- Token payloads that are currently charlists may become binaries under an explicit option.

**Non-Breaking:**
- Token type atoms unchanged
- Token structure unchanged
- Error handling unchanged

## Estimated Effort

| Phase | Estimated Lines Changed | Complexity |
|-------|------------------------|------------|
| Phase 1 | ~50 | Low |
| Phase 2 | ~150 | Medium |
| Phase 3 | ~500 | High |
| Phase 4 | ~250 | High |
| Phase 5 | ~50 | Low |
| Phase 6 | ~100 | Low |
| Testing | ~300 | Medium |

**Total**: ~1400 lines of changes

## Conclusion

Migrating to binary-based lexing will:
1. **Eliminate** the `String.to_charlist/1` overhead at input
2. **Avoid** list-walking costs on the ASCII path (binary matching is typically faster)
3. **Preserve** Unicode column semantics by keeping grapheme-aware advancement where needed
4. **Maintain** full Toxic behavior (tests + tolerant mode recovery)

The migration should be done incrementally, with each phase validated against the existing test suite and Elixir tokenizer reference output.
