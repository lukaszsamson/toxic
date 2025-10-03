# Tolerant Mode Design for Toxic Tokenizer

## Executive Summary

This document specifies a comprehensive error-tolerant mode for the Toxic tokenizer that enables continuous token production in the presence of lexical errors. The design categorizes all 50+ error cases from the test suite and codebase into recovery strategies, ensuring the tokenizer can always make forward progress while maintaining position accuracy and producing useful error diagnostics.

## Current State

**Strict Mode (Implemented)**: On first error, returns `{:error, reason, rest, state}` and halts. TokenStream surfaces the error on subsequent `next/peek` calls without mutation.

**Tolerant Mode (Not Implemented)**: Should emit error tokens and continue tokenizing by syncing to safe recovery points.

## Design Goals

1. **Forward Progress**: Never halt; always consume input or emit tokens
2. **Position Accuracy**: Maintain correct line/column tracking through recovery
3. **Terminator Consistency**: Keep terminator stack coherent during recovery
4. **Error Quality**: Preserve rich error messages with context
5. **Minimal Loss**: Recover with least information loss
6. **Pratt-Ready**: Emit tokens that Pratt parsers can skip/handle

## Error Token Format

```elixir
{:error_token, meta, reason}
```

Where:
- `meta`: `{{start_line, start_col}, {end_line, end_col}, nil}` - span of error
- `reason`: Original error tuple `{location, message, token}` from strict mode

This format:
- Integrates into linearized token stream
- Preserves all diagnostic information
- Allows parsers to skip or handle specially
- Maintains position tracking

## Error Classification & Recovery Strategies

### Category 1: Invalid Characters & Control Sequences (15 errors)

**Pattern**: Unexpected character that cannot start any valid token.

**Examples**:
- Null byte, control chars (`\0`, `\a`, `\b`, `\d`, `\e`, `\f`, `\r`, `\v`)
- Invalid bidi/line break in comments (`\u202E`, `\u2028`)
- Invalid characters in strings/interpolation
- Unexpected token after colon (`:`, `:@`)
- Version control markers (`<<<<<<<`)

**Recovery Strategy**: **Skip to next whitespace, newline, or known delimiter**

**Implementation**:
```elixir
1. Emit error_token at current position
2. Scan forward consuming characters until hitting:
   - Whitespace (space, tab)
   - Newline (\n, \r\n)
   - Known delimiter: ( ) [ ] { } << >> ; , : " ' # ~ % . @
3. Do NOT consume the delimiter/whitespace (leave for next tokenization)
4. Update position to consumed characters
5. Continue tokenization from delimiter
```

**Rationale**: Invalid characters are usually single-character typos or corruption. Skipping to next structural element minimizes cascading errors.

**Test Cases**:
- `"foo\0bar"` → `error_token(\0)`, then try tokenizing `"bar"`
- `#\u202E` → `error_token`, skip to newline
- `<<<<<<< foo` → `error_token` at column 1, skip entire line

---

### Category 2: Malformed Numbers (3 errors)

**Pattern**: Number starts correctly but has invalid continuation or value.

**Examples**:
- `123abc` - invalid character after number
- `1.2a` - invalid character after float
- `1.0e309` - float overflow

**Recovery Strategy**: **Emit what was parsed, skip to next non-identifier char**

**Implementation**:
```elixir
1. Emit error_token spanning the invalid portion
2. Scan forward skipping alphanumeric and underscore chars
3. Stop at whitespace, operator, delimiter, or newline
4. Continue tokenization from there
```

**Rationale**: The valid number prefix has already been identified. Skip the invalid suffix to avoid treating "123abc" as multiple separate tokens.

**Test Cases**:
- `123abc` → `error_token` covers "123abc", continue after
- `1.0e309` → `error_token`, continue after number
- `1.2a + 3` → `error_token`, then tokenize `+` and `3`

---

### Category 3: Invalid Escape Sequences (4 errors)

**Pattern**: Backslash at end of file or in invalid context.

**Examples**:
- `\` (EOF)
- `\\n` (EOF)
- `\\r\n` (EOF)
- `"#{foo\}"` - backslash inside interpolation

**Recovery Strategy**: **Emit error_token, treat as no character**

**Implementation**:
```elixir
1. Emit error_token for the backslash and any following chars up to newline/EOF
2. If at EOF, mark EOF and return
3. If mid-stream, consume the backslash sequence and continue
4. If in string context, attempt to resume string parsing
```

**Rationale**: Incomplete escapes are terminal at file boundaries. Mid-stream, treat as spurious character and continue.

**Test Cases**:
- `"foo\` → `error_token`, close string implicitly at EOF
- `"foo\\n"` at EOF → `error_token`
- `"#{x\}"` → `error_token` for `\`, continue interpolation

---

### Category 4: String/Heredoc Errors (9 errors)

**Pattern**: String/heredoc opened but not closed, or invalid delimiters.

**Examples**:
- `"` - missing terminator
- `"""` - missing heredoc terminator
- `"""foo"""` - invalid char after heredoc open
- `:'` - missing quoted atom terminator
- `K."` - missing quoted identifier terminator
- `~s"` - missing sigil terminator
- `"#{foo"` - missing interpolation terminator
- `"#{foo(}"` - missing terminator inside interpolation

**Recovery Strategy**: **Insert synthetic closing token at error point or EOL/EOF**

**Implementation**:
```elixir
# At EOF:
1. Emit error_token for "missing terminator"
2. Emit synthetic closing token: :bin_string_end, :list_string_end, :bin_heredoc_end, etc.
3. Pop interpolation context if inside one
4. Restore parent terminator stack
5. Mark EOF

# At newline (for single-line strings only):
1. Emit error_token
2. Emit synthetic closing token
3. Pop context
4. Continue after newline

# At closer that doesn't match (e.g., `"#{foo}` with `)` but expected `"`):
1. Emit error_token for mismatch
2. Emit synthetic closing token for string
3. Continue with the actual closer
```

**Rationale**: Strings are common sites of incomplete edits. Synthesizing closers allows parser to understand structure even if syntax incomplete.

**Special Cases**:
- Heredocs: Must look for closing delimiter at BOL with matching indent
- Interpolation: Track nesting depth, insert `}` for interpolation before string closer
- Sigils: Must emit sigil_end with original delimiter

**Test Cases**:
- `"foo` → `error_token`, synthetic `:bin_string_end` at EOF
- `"""` → `error_token`, synthetic `:bin_heredoc_end`
- `"foo\n` → `error_token` at newline, synthetic close, continue
- `"#{foo"` → insert `}` `:end_interpolation`, then synthetic `:bin_string_end`
- `"#{foo(}"` → insert `)`, emit `}`, then close string

---

### Category 5: Terminator Mismatches (8 errors)

**Pattern**: Wrong closing delimiter or unexpected closing without opening.

**Examples**:
- `)`, `]`, `}`, `>>` - unexpected closing
- `([)` - mismatched closer
- `([end` - mismatched `end` keyword
- `end` - unexpected reserved word
- `Foo(` - unexpected token after alias

**Recovery Strategy**: **Pop/adjust terminator stack, emit synthetic or continue**

**Implementation**:

**Case A: Unexpected closing delimiter (no matching opener)**
```elixir
1. Emit error_token at closing position
2. Do NOT consume the closer (leave in stream)
3. Emit synthetic opener before it: e.g., `(` before `)`
4. Then emit the closer as valid token
5. Continue tokenization
```

**Case B: Mismatched delimiter (`([)`)**
```elixir
1. Pop terminator stack to find matching opener
2. Emit error_token for the mismatch
3. Emit synthetic expected closer for the opener (e.g., `]` for `[`)
4. Leave actual closer (`)`) in stream for next iteration
5. Continue; it will trigger Case A and emit synthetic `(` then `)`
```

**Case C: Unexpected `end`**
```elixir
1. Emit error_token for unexpected end
2. Check mismatch hints from indentation analysis
3. If hint suggests missing `do`, emit synthetic `:do` earlier in stream
4. Emit the `:end` token
5. Continue
```

**Case D: Missing terminator at EOF**
```elixir
1. For each unclosed terminator on stack (innermost first):
   a. Emit error_token "missing terminator: X"
   b. Emit synthetic closing token
2. Mark EOF
```

**Rationale**: Bracket matching is critical for parser structure. Synthesizing missing elements preserves nesting even when source is broken.

**Test Cases**:
- `)` → synthetic `(`, then `)`
- `([)` → error for `[`, synthetic `]`, leave `)`, then synthetic `(`, then `)`
- `end` → error, emit `:end` anyway (parser handles context)
- `foo(` at EOF → error, synthetic `)`
- `do\n:ok` at EOF → error, synthetic `:end`

---

### Category 6: Identifier & Atom Errors (12 errors)

**Pattern**: Identifier or atom has invalid characters, wrong script, or exceeds limits.

**Examples**:
- Identifier > 255 chars
- Mixed script (`fooαbar`)
- Confusable chars (`foO𝕓`)
- Invalid control chars (`foo\u0080`)
- Identifier with `@` (`foo@bar`)
- Empty identifier after colon (`:`)
- Invalid character in alias (`Foo.Bär`)
- Atom does not exist (`:nonexistent` with `existing_atoms_only`)

**Recovery Strategy**: **Emit error, emit synthetic atom/identifier or skip**

**Implementation**:

**Case A: Long identifier**
```elixir
1. Emit error_token for entire identifier
2. Emit synthetic identifier token with truncated name (first 255 chars)
3. Continue after identifier
```

**Case B: Invalid character in identifier/alias**
```elixir
1. Scan forward to find end of identifier-like sequence
2. Emit error_token for entire sequence
3. Emit synthetic identifier with sanitized name (remove invalid chars)
4. Continue after
```

**Case C: Empty atom (`:` alone)**
```elixir
1. Emit error_token at `:`
2. Emit synthetic atom `:""` (empty atom)
3. Continue after `:`
```

**Case D: Non-existent atom**
```elixir
1. Emit error_token
2. Emit synthetic atom token with `nil` value or special marker
3. Continue
```

**Case E: Mixed script / confusable**
```elixir
1. Emit error_token with suggestion message
2. Emit identifier token with original (invalid) name for completion
3. Continue
```

**Rationale**: Identifier errors are often typos or encoding issues. Emitting synthetic tokens with corrected or original names allows parser to continue with reasonable assumptions.

**Test Cases**:
- `String.duplicate("a", 256)` → error, synthetic with truncated name
- `fooαbar` → error, synthetic `:fooαbar` atom/identifier
- `:` → error, synthetic `:""` atom
- `foo@bar` → error, synthetic `:foo_bar` identifier (remove `@`)
- `Foo.Bär` → error, synthetic alias `Foo.B_r`

---

### Category 7: Keyword & Reserved Word Errors (4 errors)

**Pattern**: Keywords in wrong context or followed by invalid tokens.

**Examples**:
- `foo:bar` - keyword not followed by space
- `if true, do\n` - unexpected reserved word `do` after comma
- `fn do` - `fn` followed by `do`
- `;;` - consecutive semicolons

**Recovery Strategy**: **Emit error, treat as identifier or skip**

**Implementation**:

**Case A: `foo:bar`**
```elixir
1. Emit error_token
2. Emit `:foo` as atom (not keyword)
3. Leave `bar` for next tokenization (treat `:bar` as separate)
```

**Case B: Unexpected `do` after comma**
```elixir
1. Emit error_token
2. Emit `:do` as regular identifier (not keyword)
3. Continue
```

**Case C: `fn do`**
```elixir
1. Emit error_token
2. Emit `:fn` token
3. Leave `do` to be tokenized separately
```

**Case D: `;;`**
```elixir
1. Emit error_token for double semicolon
2. Emit single `;` token
3. Skip second `;`
4. Continue
```

**Rationale**: Keyword context errors often indicate confusion about syntax rules. Degrading to identifier or skipping allows parser to proceed.

**Test Cases**:
- `foo:bar` → error, `:foo` atom, then `bar` identifier
- `if true, do` → error, treat `do` as identifier
- `;;` → error, single `;` token, skip extra

---

### Category 8: Sigil Errors (4 errors)

**Pattern**: Sigil name or delimiter invalid.

**Examples**:
- `~zz(hello)` - invalid multi-char lowercase sigil
- `~Ab/foo/` - invalid mixed-case sigil
- `~S"""foo"""` - invalid char after heredoc open
- `~s!foo!` - invalid delimiter

**Recovery Strategy**: **Emit error, skip sigil or treat as identifier**

**Implementation**:

**Case A: Invalid sigil name**
```elixir
1. Emit error_token covering `~name`
2. Try to parse as identifier starting from `name` part
3. Continue after sigil-like construct
```

**Case B: Invalid delimiter**
```elixir
1. Emit error_token
2. Skip to next whitespace/newline
3. Continue
```

**Case C: Invalid heredoc open**
```elixir
1. Emit error_token
2. Treat as non-heredoc sigil with same delimiter
3. Or skip to next newline and continue
```

**Rationale**: Sigils are specialized syntax. Errors here likely indicate user confusion; best to skip and let parser recover.

**Test Cases**:
- `~zz(hello)` → error, try parse as `~z` or skip entire construct
- `~Ab/foo/` → error, treat as identifier `Ab`
- `~s!foo!` → error, skip to next line

---

### Category 9: Map Syntax Errors (3 errors)

**Pattern**: Invalid map syntax with `%`.

**Examples**:
- `% {}` - space between `%` and `{`
- `%(` - invalid opener after `%`
- `%[` - invalid opener after `%`

**Recovery Strategy**: **Emit error, emit `%` token, continue with next token**

**Implementation**:
```elixir
1. Emit error_token
2. Emit `:%` token as-is
3. Continue tokenizing from `{`, `(`, `[` etc
```

**Rationale**: User likely intended `%{}` but added space or wrong bracket. Emitting `%` separately allows parser to decide on recovery.

**Test Cases**:
- `% {}` → error, `:%`, then `:{`, `:`}`
- `%(` → error, `:%`, then `:`(`

---

### Category 10: Ternary/Range Operator Errors (1 error)

**Pattern**: Invalid ternary operator syntax.

**Examples**:
- `..//foo` - no space before final `/`

**Recovery Strategy**: **Emit error, emit best-guess operator or skip**

**Implementation**:
```elixir
1. Emit error_token
2. Emit `.//` operator or skip entire sequence
3. Continue after operator
```

**Test Cases**:
- `..//foo` → error, emit `.//` or skip to `foo`

---

## Recovery Point Selection

When consuming characters to skip over errors, stop at:

1. **Semicolon** (`;`) - statement separator
2. **Newline** (`\n`, `\r\n`) - often statement boundary
3. **Closing terminators** (`)`, `]`, `}`, `>>`, `end`) - when we expect one
4. **Comma** (`,`) - argument separator
5. **Whitespace** - natural token boundary
6. **Comment** - natural boundary

**Never skip**:
- Opening terminators without closing them
- Keywords that might start new constructs
- Operators that might be unary

**Terminator stack management**:
- If skipping to a closer, check if it matches expected terminator
- If mismatch, apply mismatched delimiter recovery (Category 5)
- Always update stack to reflect synthetic tokens emitted

---

## Implementation Architecture

### 1. Driver-Level Changes (`Toxic.Driver`)

**Add to state**:
```elixir
defstruct [
  ...,
  error_mode: :strict | :tolerant,
  error_sync: [:semicolon, :newline, :closer],
  errors_emitted: []  # Track errors in current session
]
```

**New recovery function**:
```elixir
@spec recover_from_error(
  reason :: term(),
  rest :: charlist(),
  state :: t()
) :: {token :: token() | [token()], rest :: charlist(), state :: t()}
```

**Modify `next/2`**:
```elixir
def next(string, state) do
  # ... existing logic ...

  case result do
    {:error, reason, rest, state} when state.error_mode == :tolerant ->
      recover_from_error(reason, rest, state)

    {:error, reason, rest, state} ->
      {:error, reason, rest, state}
  end
end
```

### 2. Tokenizer-Level Changes

Each error-returning function needs classification:
```elixir
# Current:
{:error, {location, message, token}}

# Enhanced (tolerant mode):
{:error, {location, message, token}, category}

# Where category in:
# :invalid_char, :malformed_number, :invalid_escape,
# :missing_terminator, :mismatched_delimiter, :invalid_identifier,
# :keyword_context, :invalid_sigil, :invalid_map_syntax, :invalid_operator
```

Add error category to all error returns to guide recovery strategy.

### 3. TokenStream Integration

**Existing error handling**:
```elixir
# In next/1:
stream.error ->
  if error_mode == :strict do
    {:error, stream.error, stream}
  else
    # TODO: tolerant mode
  end
```

**New tolerant handling**:
```elixir
stream.error ->
  if error_mode == :strict do
    {:error, stream.error, stream}
  else
    # Clear error, return error_token, continue
    error_token = format_error_token(stream.error, stream.driver)
    stream = %{stream | error: nil, buffer: enqueue_token(stream.buffer, error_token)}
    next(stream)
  end
```

### 4. Recovery Helpers

```elixir
defmodule Toxic.Recovery do
  # Scan forward to recovery point
  @spec skip_to_sync_point(
    input :: charlist(),
    line :: pos_integer(),
    column :: pos_integer(),
    sync_points :: [:semicolon | :newline | :closer]
  ) :: {rest :: charlist(), line :: pos_integer(), column :: pos_integer()}

  # Synthesize closing token
  @spec synthesize_closer(
    opener :: atom(),
    meta :: term()
  ) :: token()

  # Adjust terminator stack after recovery
  @spec adjust_terminators(
    terminators :: list(),
    action :: :pop | :push | {:insert, term()}
  ) :: list()

  # Categorize error
  @spec categorize_error(reason :: term()) :: atom()
end
```

---

## Testing Strategy

1. **Existing Error Tests**: All tests in `toxic_erros_test.exs` should pass in strict mode
2. **New Tolerant Tests**: For each error case, add test that:
   - Enables tolerant mode
   - Verifies error_token emitted
   - Verifies tokenization continues
   - Verifies position accuracy maintained
   - Verifies terminator stack consistency

**Example tolerant test**:
```elixir
test "tolerant: missing string terminator" do
  tokens = tokenize_tolerant("\"foo")

  assert [
    {:bin_string_start, _, _},
    {:string_fragment, _, "foo"},
    {:error_token, meta, reason},
    {:bin_string_end, _, _}
  ] = tokens

  assert {{1, 1}, {1, 5}, nil} = meta  # Error spans entire string
  assert {:missing_terminator, _, _} = reason
end

test "tolerant: unexpected closing paren" do
  tokens = tokenize_tolerant(")")

  assert [
    {:error_token, _, _},
    {:"(", _, _},  # Synthetic opener
    {:")", _, _}   # Actual closer
  ] = tokens
end

test "tolerant: invalid char after number" do
  tokens = tokenize_tolerant("123abc + 456")

  assert [
    {:error_token, meta, _},
    {:dual_op, _, :+},
    {:int, _, 456}
  ] = tokens

  assert {{1, 1}, {1, 7}, nil} = meta  # Error covers "123abc"
end
```

3. **Cascade Tests**: Verify that errors don't cause cascading failures:
```elixir
test "tolerant: multiple errors in sequence" do
  # Should recover from each error independently
  tokens = tokenize_tolerant("foo\0bar \"missing 123abc")
  # Verify error_tokens at correct positions, valid tokens between
end
```

4. **Position Accuracy Tests**: After recovery, verify subsequent tokens have correct positions

5. **Terminator Stack Tests**: After recovery, verify `current_terminators/1` is consistent

---

## Migration Path

### Phase 1: Infrastructure
- Add error category to all error returns
- Implement `Toxic.Recovery` module
- Add `error_mode` to Driver state
- Update TokenStream to handle error tokens

### Phase 2: Categories 1-3 (Simpler recoveries)
- Invalid characters (skip to delimiter)
- Malformed numbers (skip to non-ident)
- Invalid escapes (treat as missing)
- Test each category

### Phase 3: Categories 4-5 (Terminator handling)
- Missing terminators (synthesize closers)
- Mismatched delimiters (adjust stack)
- Test extensively with nested structures

### Phase 4: Categories 6-10 (Context-specific)
- Identifier errors
- Keyword errors
- Sigil errors
- Map syntax errors
- Operator errors
- Test edge cases

### Phase 5: Integration & Polish
- Comprehensive cascade tests
- Performance benchmarks (ensure tolerant mode doesn't slow happy path)
- Documentation updates
- Examples for common error scenarios

---

## Performance Considerations

1. **Happy Path**: No overhead when no errors occur (mode check happens after error)
2. **Error Path**: Recovery scanning is linear in error span (typically small)
3. **Error Token Storage**: Error tokens are same size as regular tokens
4. **Terminator Stack**: Adjust operations are O(1) for most cases, O(n) for deep mismatches

**Benchmark targets**:
- Tolerant mode with no errors: < 5% slower than strict mode
- Tolerant mode with errors: Linear in error recovery distance
- Memory: No additional allocations on happy path

---

## Alternative Strategies Considered

### 1. Panic Mode (Discard tokens until sync point)
**Rejected**: Loses too much information; synthesizing tokens gives parser more context.

### 2. Error Production Rules (Explicit error grammar)
**Rejected**: Too complex to maintain; category-based recovery is more flexible.

### 3. Backtracking (Try alternative parses)
**Rejected**: Lexer should be single-pass; backtracking belongs in parser.

### 4. Minimal Error Recovery (Only at expression boundaries)
**Rejected**: Too coarse; want finer-grained recovery for better IDE experience.

---

## Open Questions & Future Work

1. **IDE Integration**: How should error tokens be presented in IDE hovers/diagnostics?
   - Likely: Collect errors separately, surface as diagnostics list

2. **Incremental Reparsing**: How do error tokens affect incremental lexing?
   - Likely: Treat error token boundaries as parse points; re-lex surrounding region

3. **Parser Expectations**: Should parser have special handling for error tokens?
   - Likely: Yes, Pratt parser should skip error tokens in error production rules

4. **Error Limits**: Should we limit number of errors emitted?
   - Likely: Add `max_errors` option to prevent pathological cases

5. **Recovery Hints**: Should we emit suggestions in error tokens?
   - Likely: Yes, preserve original error messages which often include hints

6. **Unicode Edge Cases**: How to handle invalid UTF-8 in tolerant mode?
   - Current: Rely on Erlang's Unicode handling; emit error for invalid sequences

---

## Summary of Recovery Strategies by Category

| Category | Count | Strategy | Sync Points |
|----------|-------|----------|-------------|
| Invalid Characters | 15 | Skip to delimiter | Whitespace, newline, delimiter |
| Malformed Numbers | 3 | Skip to non-identifier | Whitespace, operator, delimiter |
| Invalid Escapes | 4 | Treat as missing char | Continue in context |
| String/Heredoc Errors | 9 | Synthesize closer | EOL, EOF, or mismatch |
| Terminator Mismatches | 8 | Adjust stack + synthesize | Immediate |
| Identifier/Atom Errors | 12 | Sanitize + emit synthetic | After identifier |
| Keyword Errors | 4 | Degrade to identifier | Immediate |
| Sigil Errors | 4 | Skip construct | Newline |
| Map Syntax Errors | 3 | Emit % + continue | Next token |
| Operator Errors | 1 | Skip or emit partial | Next token |

**Total**: 63 error cases covered (all error cases from test suite + source code)

---

## Glossary

- **Error Token**: Special token type carrying error information in linearized stream
- **Sync Point**: Position in input where tokenizer can safely resume after error
- **Synthetic Token**: Token inserted by recovery logic to maintain structure
- **Terminator Stack**: Stack of unclosed opening delimiters (`(`, `[`, `{`, `<<`, `do`, `fn`)
- **Cascade Error**: Secondary error caused by recovery from previous error (should minimize)
- **Forward Progress**: Guarantee that tokenizer always advances through input, never infinite loops

---

## References

1. **PLAN.md** - Original gap analysis identifying need for tolerant mode
2. **test/toxic_erros_test.exs** - Comprehensive error test suite (63 cases)
3. **Elixir tokenizer** (`elixir_tokenizer.erl`) - Reference implementation (strict mode only)
4. **Roslyn Error Recovery** - Microsoft's C# compiler error recovery strategies
5. **Tree-sitter Error Recovery** - Incremental parsing with error nodes
6. **Rust's `proc-macro2`** - Token stream design with error tokens

---

*Document Version: 1.0*
*Date: 2025-10-03*
*Author: Claude (based on Toxic codebase analysis)*
