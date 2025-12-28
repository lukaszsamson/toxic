# Binary-Based Lexer Migration Plan

## Executive Summary

This document outlines a plan to migrate the Toxic lexer from charlist-based processing to binary-based processing. The goals are:

1. **Eliminate charlist conversion overhead** - Currently `String.to_charlist/1` is called on input
2. **Reduce `:unicode_util.gc` calls** - Expensive grapheme cluster iteration
3. **Maintain parity with legacy Elixir lexer** - All edge cases must be preserved
4. **Improve performance** - Binary pattern matching is often more efficient for ASCII

## Current Architecture Analysis

### Input Flow
```
binary input
    |
    v
String.to_charlist/1 (conversion)
    |
    v
Toxic.Driver (charlist-based state)
    |
    v
NormalTokenizer.next/5 (charlist pattern matching)
    |
    v
InterpolationTokenizer.next/9 (charlist pattern matching)
    |
    v
Token output with charlist values
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
| `Toxic.String.Tokenizer` | **Already converted to binary** | Unicode identifier validation |
| `Toxic.Util` | `characters_to_binary/1`, `characters_to_list/1` | Conversions |

### Current `:unicode_util.gc` Usage

Located in:
- `lib/toxic/driver/position.ex:21` - Column counting during position updates
- `lib/toxic/driver/position.ex:57` - Grapheme iteration for position calculation
- `lib/toxic/interpolation_tokenizer.ex:308` - Character extraction in strings

These are used for **grapheme cluster handling** - essential for proper column counting with combined characters (emojis, accented letters, etc.).

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
Toxic.Driver (binary-based state)
    |
    v
NormalTokenizer.next/5 (binary pattern matching)
    |
    v
InterpolationTokenizer.next/9 (binary pattern matching)
    |
    v
Token output with binary values
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

Replace `:unicode_util.gc/1` with `String.next_grapheme/1`:

```elixir
# Old (charlist-based)
case :unicode_util.gc(rest) do
  [char | new_rest] when is_list(char) ->
    # Extended grapheme cluster (e.g., combining characters)
  [char | new_rest] when is_integer(char) ->
    # Single codepoint
  [] ->
    # End of input
end

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

**Important**: For column counting, a grapheme cluster counts as 1 column regardless of byte length or number of codepoints.

### Token Value Types

Current: Token values use charlists (e.g., `~c"123"` for int original representation)
New: Token values will use binaries (e.g., `"123"`)

This affects:
- `{:int, meta, original_representation}` - currently charlist
- `{:flt, meta, original_representation}` - currently charlist
- `{:atom, meta, value}` - atom (unchanged)
- `{:bin_string, meta, value}` - will be binary
- Error message formatting

## Migration Phases

### Phase 1: API and Type Changes (Non-Breaking Preparation)

1. Update `@type` specifications to accept/return binaries
2. Add `source_binary` field to stream struct (already exists)
3. Create binary-based utility functions alongside charlist versions
4. Update token construction to use binaries for original representations

**Key Changes:**
- `Toxic.Token.int/2` - Accept binary for original representation
- `Toxic.Token.flt/2` - Accept binary for original representation
- Error structs - Use binaries for message components

### Phase 2: NormalTokenizer Conversion

Convert `lib/toxic/normal_tokenizer.ex` and submodules:

#### 2.1 NormalTokenizer.ex (Main Entry)

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

#### 2.2 NormalTokenizer.Number Conversion

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

#### 2.3 NormalTokenizer.Comment Conversion

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

### Phase 3: InterpolationTokenizer Conversion

Convert `lib/toxic/interpolation_tokenizer.ex`:

#### 3.1 Buffer Handling

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

#### 3.2 Grapheme Handling

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

### Phase 4: Driver and Position Tracking

#### 4.1 Driver State Changes

```elixir
# Current
@type input :: charlist()

# New
@type input :: binary()
```

Update `Toxic.Driver`:
- Change pattern matching in `next_token/2` and related functions
- Update context tracking to use binary rest

#### 4.2 Position Module

Convert `lib/toxic/driver/position.ex`:

```elixir
# Before (charlist with :unicode_util.gc)
def column_offset_from_rest(rest, scope) do
  case :unicode_util.gc(rest) do
    [char | _] when is_list(char) -> 1
    [_ | _] -> 1
    [] -> 0
  end
end

# After (binary with String.next_grapheme)
def column_offset_from_rest(rest, scope) do
  case String.next_grapheme(rest) do
    {_, _} -> 1
    nil -> 0
  end
end
```

### Phase 5: Utility Functions and Cleanup

#### 5.1 Update Toxic.Util

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

#### 5.2 Character Classifier Guards

Guards in `Toxic.CharacterClassifier` work with codepoints (integers), so they remain unchanged. They work correctly with both:
- `[head | _]` where head is codepoint
- `<<head, _::binary>>` where head is byte (for ASCII)
- `<<head::utf8, _::binary>>` where head is codepoint

#### 5.3 Strip Functions

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

### Phase 6: Entry Point Updates

#### 6.1 Remove Charlist Conversion

```elixir
# Before
def new(source, line \\ 1, column \\ 1, opts \\ []) do
  {driver_source, source_binary, effective_source} =
    cond do
      is_binary(source) ->
        charlist = String.to_charlist(source)  # REMOVE THIS
        {charlist, source, charlist}
      ...

# After
def new(source, line \\ 1, column \\ 1, opts \\ []) do
  source_binary =
    if is_binary(source) do
      source
    else
      IO.iodata_to_binary(source)  # Convert charlist input to binary
    end

  %__MODULE__{
    driver: driver,
    source: source_binary,
    ...
  }
end
```

## Avoiding Expensive Unicode Operations

### `:unicode.characters_to_list/1` Elimination

**Location**: `Toxic.Util.characters_to_list/1`

**Solution**: Work directly with binaries, only convert to charlist when absolutely necessary (e.g., for Elixir's `:unicode` NFC normalization which requires charlist input).

### `:unicode_util.gc/1` Replacement

**Locations**:
- `lib/toxic/driver/position.ex` - Column counting
- `lib/toxic/interpolation_tokenizer.ex` - Character extraction

**Solution**: Use `String.next_grapheme/1` which:
- Takes binary input directly
- Returns `{grapheme_binary, rest_binary}`
- Handles all Unicode grapheme cluster rules

**Performance Note**: `String.next_grapheme/1` is implemented in Erlang as `string:next_grapheme/1` which is highly optimized for common cases.

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

Run against Elixir tokenizer reference output:
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
  "charlist-based" => fn -> Toxic.V1.tokenize(large_source) end,
  "binary-based" => fn -> Toxic.V2.tokenize(large_source) end
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

**Breaking Changes:**
- Token metadata `extra` field: charlist values become binaries
- `Toxic.current_terminators/1` returns charlists in terminator entries - will become binaries
- `Toxic.slice/6` operates on charlist source - will need binary variant

**Non-Breaking:**
- Token type atoms unchanged
- Token structure unchanged
- Error handling unchanged

## Estimated Effort

| Phase | Estimated Lines Changed | Complexity |
|-------|------------------------|------------|
| Phase 1 | ~100 | Low |
| Phase 2 | ~500 | Medium-High |
| Phase 3 | ~200 | High |
| Phase 4 | ~150 | Medium |
| Phase 5 | ~100 | Low |
| Phase 6 | ~50 | Low |
| Testing | ~300 | Medium |

**Total**: ~1400 lines of changes

## Conclusion

Migrating to binary-based lexing will:
1. **Eliminate** the `String.to_charlist/1` overhead at input
2. **Reduce** Unicode operations by using `String.next_grapheme/1` instead of `:unicode_util.gc/1`
3. **Improve** memory efficiency (binaries are more compact than charlists for ASCII)
4. **Maintain** full compatibility with Elixir lexer behavior

The migration should be done incrementally, with each phase validated against the existing test suite and Elixir tokenizer reference output.
