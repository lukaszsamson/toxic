# Migration Plan: Structured Warnings System

## Overview
Migrate from unstructured warning messages stored in `Toxic.Scope` to a structured warning system similar to `Toxic.Error`, enabling better tooling integration, consistent handling, and testable warning emissions.

## Current State Analysis

### Warning Storage (lib/toxic/scope.ex)
- Warnings stored as list of `{line, column, message_iolist}` tuples in scope record
- `prepend_warning/4` function adds warnings to front of list
- No structured metadata, domains, or error codes
- Messages are ad-hoc iolists, not standardized

### Warning Emission Sites (from grep prepend_warning)
Located in:
- `lib/toxic/tokenizer.ex` (multiple locations)
- `lib/toxic/alias.ex`
- `lib/toxic/string.ex`
- `lib/toxic/sigil.ex`

### Warning Categories (from WARNINGS.md)
1. **Deprecated Syntax**
   - Single-quoted atoms (`:deprecated_single_quote_atom`)
   - Charlists in general (`:deprecated_charlist`)

2. **Ambiguous Syntax**
   - Bang/question before equals (`:ambiguous_bang_before_equals`, `:ambiguous_question_before_equals`)
   - Confusable operators (`:confusable_repeated_operator`)
   - Triple-colon atom (`:ambiguous_triple_colon_atom`)

3. **Invalid Escape Sequences**
   - Unknown char escapes (`:invalid_char_escape`)
   - Unnecessary char escapes (`:unnecessary_char_escape`)

## Implementation Plan

### Phase 1: Warning Structure Definition

**File: lib/toxic/warning.ex** (NEW)
```elixir
defmodule Toxic.Warning do
  @moduledoc """
  Structured warning representation for Toxic tokenizer.
  """
  
  @type domain ::
          :deprecated
          | :ambiguous
          | :escape
          | :unicode
          | :identifier
          | :atom
  
  @type code ::
          # Deprecated
          :deprecated_single_quote_atom
          | :deprecated_charlist
          # Ambiguous
          | :ambiguous_bang_before_equals
          | :ambiguous_question_before_equals
          | :confusable_repeated_operator
          | :ambiguous_triple_colon_atom
          # Escape
          | :invalid_char_escape
          | :unnecessary_char_escape
          # Unicode
          | :non_latin_atom
          | :confusable_identifier_char
  
  @type t :: %__MODULE__{
          code: code(),
          domain: domain(),
          token_display: iolist(),
          details: map()
        }
  
  defstruct [:code, :domain, :token_display, :details]
  
  @doc """
  Create a new warning with structured metadata.
  """
  def new(code, domain, token_display, details) do
    %__MODULE__{
      code: code,
      domain: domain,
      token_display: token_display,
      details: details
    }
  end
end
```

### Phase 2: Scope Module Updates

**File: lib/toxic/scope.ex**
```elixir
# Change warning storage from:
warnings: [{line, column, message_iolist}]

# To:
warnings: [Toxic.Warning.t()]

# Update prepend_warning/4 signature:
# From:
def prepend_warning(line, column, message, scope) do
  scope(scope, warnings: [{line, column, message} | scope(scope, :warnings)])
end

# To:
def prepend_warning(warning = %Toxic.Warning{}, scope) do
  scope(scope, warnings: [warning | scope(scope, :warnings)])
end

# Add helper for backward compatibility during migration:
def prepend_warning_legacy(line, column, message, scope) do
  # Temporary - will be removed after migration
  warning = %Toxic.Warning{
    code: :legacy_unstructured,
    domain: :general,
    token_display: message,
    details: %{line: line, column: column}
  }
  prepend_warning(warning, scope)
end
```

### Phase 3: Warning Construction Helpers

**File: lib/toxic/warning.ex** (additions)
```elixir
# Deprecated syntax warnings
def deprecated_single_quote_atom(line, column) do
  new(
    :deprecated_single_quote_atom,
    :deprecated,
    ~c":'atom'",
    %{line: line, column: column, suggestion: ~c"Use double quotes: :\"atom\""}
  )
end

def deprecated_charlist(line, column, token_display) do
  new(
    :deprecated_charlist,
    :deprecated,
    token_display,
    %{line: line, column: column, suggestion: ~c"Use ~c sigil or binary string"}
  )
end

# Ambiguous syntax warnings
def ambiguous_bang_before_equals(line, column, identifier, kind) do
  msg = :io_lib.format(
    ~c"found ~ts \"~ts\", ending with \"!\", followed by =. " <>
    ~c"It is unclear if you mean \"~ts !=\" or \"~ts =\". Please add " <>
    ~c"a space before or after ! to remove the ambiguity",
    [kind_name(kind), identifier, :lists.droplast(identifier), identifier]
  )
  
  new(
    :ambiguous_bang_before_equals,
    :ambiguous,
    identifier,
    %{line: line, column: column, kind: kind, message: msg}
  )
end

def ambiguous_question_before_equals(line, column, identifier, kind) do
  # Similar to bang variant
end

def confusable_repeated_operator(line, column, operator, next_char) do
  token_str = List.to_string(operator)
  char_str = List.to_string([next_char])
  
  msg = :io_lib.format(
    ~c"found \"~ts\" followed by \"~ts\", please use a space between \"~ts\" and the next \"~ts\"",
    [token_str, char_str, token_str, char_str]
  )
  
  new(
    :confusable_repeated_operator,
    :ambiguous,
    operator ++ [next_char],
    %{line: line, column: column, operator: operator, next_char: next_char, message: msg}
  )
end

def ambiguous_triple_colon_atom(line, column) do
  new(
    :ambiguous_triple_colon_atom,
    :ambiguous,
    ~c":::",
    %{
      line: line,
      column: column,
      message: ~c"atom ::: must be written between quotes, as in :\"::\", to avoid ambiguity"
    }
  )
end

# Escape sequence warnings
def invalid_char_escape(line, column, char) do
  msg = :io_lib.format(~c"unknown escape sequence ?\\~tc, use ?~tc instead", [char, char])
  
  new(
    :invalid_char_escape,
    :escape,
    [??, ?\\, char],
    %{line: line, column: column, char: char, message: msg}
  )
end

def unnecessary_char_escape(line, column, char, escape_seq, name) do
  msg = :io_lib.format(
    ~c"found ?\\ followed by code point 0x~.16B (~ts), please use ?~ts instead",
    [char, name, escape_seq]
  )
  
  new(
    :unnecessary_char_escape,
    :escape,
    [??, ?\\, char],
    %{line: line, column: column, char: char, escape: escape_seq, name: name, message: msg}
  )
end

# Unicode warnings
def non_latin_atom(line, column, atom) do
  new(
    :non_latin_atom,
    :unicode,
    Atom.to_charlist(atom),
    %{line: line, column: column, atom: atom}
  )
end

def confusable_identifier_char(line, column, identifier, confusable_char) do
  new(
    :confusable_identifier_char,
    :unicode,
    identifier,
    %{line: line, column: column, confusable: confusable_char}
  )
end

# Helper
defp kind_name(:atom), do: ~c"atom"
defp kind_name(:identifier), do: ~c"identifier"
```

### Phase 4: Migration of Warning Call Sites

#### 4.1: lib/toxic/tokenizer.ex

**Line 94-95: deprecated_single_quote_atom**
```elixir
# From:
scope =
  if h == ?' do
    Toxic.Scope.prepend_warning(
      line,
      column,
      ~c"single quotes around atoms are deprecated. Use double quotes instead",
      base_scope
    )
  else
    base_scope
  end

# To:
scope =
  if h == ?' do
    warning = Toxic.Warning.deprecated_single_quote_atom(line, column)
    Toxic.Scope.prepend_warning(warning, base_scope)
  else
    base_scope
  end
```

**Line ~115: handle_char warnings (unnecessary_char_escape)**
```elixir
# From:
new_scope =
  if h == char and h != ?\\ do
    case handle_char(char) do
      {escape, name} ->
        msg = :io_lib.format(
          ~c"found ?\\ followed by code point 0x~.16B (~ts), please use ?~ts instead",
          [char, name, escape]
        )
        Toxic.Scope.prepend_warning(line, column, msg, scope)
      # ...
    end
  end

# To:
new_scope =
  if h == char and h != ?\\ do
    case handle_char(char) do
      {escape, name} ->
        warning = Toxic.Warning.unnecessary_char_escape(line, column, char, escape, name)
        Toxic.Scope.prepend_warning(warning, scope)
      # ...
    end
  end
```

**Line ~130: invalid_char_escape for downcase/upcase**
```elixir
# From:
false when is_downcase(h) or is_upcase(h) ->
  msg = :io_lib.format(~c"unknown escape sequence ?\\~tc, use ?~tc instead", [h, h])
  Toxic.Scope.prepend_warning(line, column, msg, scope)

# To:
false when is_downcase(h) or is_upcase(h) ->
  warning = Toxic.Warning.invalid_char_escape(line, column, h)
  Toxic.Scope.prepend_warning(warning, scope)
```

**Line ~150: handle_char warnings for regular chars**
```elixir
# Similar pattern - replace with Toxic.Warning.unnecessary_char_escape/5
```

**Line ~230: ambiguous_triple_colon_atom**
```elixir
# From:
def tokenize_single([?:, ?:, ?: | rest], line, column, scope, _tokens) do
  message = ~c"atom ::: must be written between quotes, as in :\"::\", to avoid ambiguity"
  new_scope = Toxic.Scope.prepend_warning(line, column, message, scope)
  # ...
end

# To:
def tokenize_single([?:, ?:, ?: | rest], line, column, scope, _tokens) do
  warning = Toxic.Warning.ambiguous_triple_colon_atom(line, column)
  new_scope = Toxic.Scope.prepend_warning(warning, scope)
  # ...
end
```

**Line ~308: confusable_repeated_operator**
```elixir
# From:
def tokenize_single([t1, t2, t3 | rest], line, column, scope, tokens)
    when unquote(token)(t1, t2, t3) do
  new_scope = maybe_warn_too_many_of_same_char([t1, t2, t3], rest, line, column, scope)
  # ...
end

def maybe_warn_too_many_of_same_char([t | _] = token, [t | _], line, column, scope) do
  # ... format message ...
  Toxic.Scope.prepend_warning(line, column, message, scope)
end

# To:
def maybe_warn_too_many_of_same_char([t | _] = token, [t | _], line, column, scope) do
  warning = Toxic.Warning.confusable_repeated_operator(line, column, token, t)
  Toxic.Scope.prepend_warning(warning, scope)
end
```

**Line ~715: ambiguous_bang/question_before_equals**
```elixir
# From:
def maybe_warn_for_ambiguous_bang_before_equals(kind, unencoded, [?= | _], line, column, scope) do
  # ... build message ...
  Toxic.Scope.prepend_warning(line, column, msg, scope)
end

# To:
def maybe_warn_for_ambiguous_bang_before_equals(kind, unencoded, [?= | _], line, column, scope) do
  {what, identifier} = # ... existing logic ...
  
  case List.last(identifier) do
    ?! ->
      warning = Toxic.Warning.ambiguous_bang_before_equals(line, column, identifier, kind)
      Toxic.Scope.prepend_warning(warning, scope)
    
    ?? ->
      warning = Toxic.Warning.ambiguous_question_before_equals(line, column, identifier, kind)
      Toxic.Scope.prepend_warning(warning, scope)
    
    _ ->
      scope
  end
end
```

#### 4.2: lib/toxic/alias.ex

**Check for non_latin_atom or confusable warnings**
```elixir
# Locate prepend_warning calls and convert to structured warnings
# Pattern similar to tokenizer.ex conversions
```

#### 4.3: lib/toxic/string.ex

**Charlist deprecation warnings**
```elixir
# From:
Toxic.Scope.prepend_warning(line, column, ~c"charlists are deprecated...", scope)

# To:
warning = Toxic.Warning.deprecated_charlist(line, column, token_display)
Toxic.Scope.prepend_warning(warning, scope)
```

#### 4.4: lib/toxic/sigil.ex

**Any sigil-specific warnings**
```elixir
# Convert following same pattern
```

### Phase 5: Test Updates

**File: test/toxic_warnings_test.exs**

Update all test assertions from:
```elixir
assert scope(result, :warnings) == [{1, 1, expected_message}]
```

To:
```elixir
[warning] = scope(result, :warnings)
assert warning.code == :deprecated_single_quote_atom
assert warning.domain == :deprecated
assert warning.details.line == 1
assert warning.details.column == 1
# Optionally check token_display or message if needed
```

Add helper functions:
```elixir
defp assert_warning(warnings, code, domain, line, column) do
  assert Enum.any?(warnings, fn w ->
    w.code == code and w.domain == domain and
    w.details.line == line and w.details.column == column
  end), "Expected warning #{code} at #{line}:#{column} not found"
end

defp assert_warnings_count(warnings, expected_count) do
  assert length(warnings) == expected_count,
    "Expected #{expected_count} warnings, got #{length(warnings)}"
end
```

Update each test category:
- Deprecated syntax tests → check `:deprecated_single_quote_atom`, `:deprecated_charlist`
- Ambiguous syntax tests → check `:ambiguous_*` codes
- Escape sequence tests → check `:invalid_char_escape`, `:unnecessary_char_escape`
- Unicode tests → check `:non_latin_atom`, `:confusable_identifier_char`

### Phase 6: Documentation

**Update WARNINGS.md**
- Add structured warning format documentation
- Include domain/code taxonomy
- Show example warning structures
- Document migration from legacy format

**Add lib/toxic/warning.ex module docs**
- Document all warning codes
- Provide usage examples
- Explain details map conventions

### Phase 7: Cleanup

1. Remove `prepend_warning_legacy/4` helper from scope.ex
2. Remove any temporary conversion code
3. Verify all `prepend_warning` calls use structured warnings
4. Run full test suite
5. Update AGENTS.md to reference structured warnings

## Migration Checklist

- [x] Phase 1: Create `lib/toxic/warning.ex` with base structure ✅
- [x] Phase 2: Update `lib/toxic/scope.ex` warning storage ✅
- [x] Phase 3: Add all warning construction helpers ✅
- [x] Phase 4.1: Migrate `lib/toxic/tokenizer.ex` (10+ sites) ✅
- [x] Phase 4.2: Migrate `lib/toxic/alias.ex` ✅ (none found)
- [x] Phase 4.3: Migrate `lib/toxic/string.ex` ✅ (none found)
- [x] Phase 4.4: Migrate `lib/toxic/sigil.ex` ✅ (handled via interpolation.ex)
- [x] Phase 4.5: Migrate `lib/toxic/operator.ex` ✅
- [x] Phase 4.6: Migrate `lib/toxic/driver.ex` ✅
- [x] Phase 4.7: Migrate `lib/toxic/dot.ex` ✅
- [x] Phase 4.8: Migrate `lib/toxic/interpolation.ex` ✅
- [x] Phase 5: Update `test/toxic_warnings_test.exs` ✅
- [ ] Phase 6: Update documentation
- [ ] Phase 7: Cleanup and final verification
- [ ] Run `mix test` → all tests pass
- [ ] Run `mix test --cover` → verify coverage maintained
- [ ] Update TODO.md and PROJECT_STATE.md
- [ ] Phase 6: Update documentation
- [ ] Phase 7: Cleanup and final verification
- [ ] Run `mix test` → all tests pass
- [ ] Run `mix test --cover` → verify coverage maintained
- [ ] Update TODO.md and PROJECT_STATE.md

## Benefits

1. **Tooling Integration**: LSP/IDE can consume structured warning codes
2. **Testability**: Easy to assert specific warning types
3. **Consistency**: All warnings follow same structure as errors
4. **Extensibility**: Easy to add warning details without changing tests
5. **Filtering**: Users can filter/suppress by code or domain
6. **Documentation**: Self-documenting warning taxonomy

## Risks & Mitigation

**Risk**: Breaking existing warning consumers
- **Mitigation**: Provide `prepend_warning_legacy/4` during migration phase

**Risk**: Test churn from format changes
- **Mitigation**: Add helper assertion functions to minimize test changes

**Risk**: Incomplete migration leaves mixed formats
- **Mitigation**: Grep for all `prepend_warning` calls, verify each converted

**Risk**: Warning details map inconsistencies
- **Mitigation**: Document required fields per warning code in warning.ex

## Estimated Effort

- Phase 1-3: 2-3 hours (foundation)
- Phase 4: 4-6 hours (migration of ~15-20 call sites)
- Phase 5: 2-3 hours (test updates)
- Phase 6-7: 1-2 hours (docs and cleanup)

**Total: 9-14 hours**

## Notes

- Follow AGENTS.md patterns for error handling
- Maintain position accuracy in warning details
- Keep token_display minimal but informative
- Consider adding warning severity levels (info/warning/error) in future
- Warning accumulation order (prepend) should be preserved for compatibility
