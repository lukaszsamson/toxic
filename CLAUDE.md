# Toxic Tokenizer - Claude Development Guide

## Project Context
Toxic is a streaming tokenizer for Elixir that replaces batch tokenization with a single-token streaming approach. The project aims to support advanced features like error recovery, incremental lexing, and precise position tracking for IDE/tooling scenarios.

## Current Status
- ✅ **Core streaming tokenizer working** (472/472 tests passing)
- ✅ **Streaming interpolation implemented** - Returns fragment/interpolation events
- ✅ **Driver loop complete** - Single-token streaming with deferrals
- ❌ **Error handling not implemented** - No error recovery or error tokens

## Key Files to Understand

### Core Implementation
- `lib/toxic/token_stream.ex` - High-level Elixir streaming API
- `lib/toxic/driver.ex` - Low-level single-token driver
- `lib/toxic/tokenizer.ex` - Main tokenization logic
- `lib/toxic/interpolation.ex` - String interpolation handling

### Design Documents (Evaluation)
- `PLAN.md`, `TODO.md` - Outdated, need updating

## Development Priorities

### 1. Error Handling (High Priority)
**Goal**: Implement proper error recovery without batch fallback

**Tasks**:
- Add error token emission in driver
- Implement sync point recovery (semicolon, newline, closer)
- Support strict vs tolerant modes
- Test with malformed code examples

**Key Challenges**:
- Maintaining position accuracy during recovery
- Determining optimal sync points
- Balancing error detail with streaming constraints

### 2. Test Coverage (Medium Priority)
**Goal**: Add comprehensive test coverage for edge cases

**Areas needing tests**:
- Error recovery scenarios
- Malformed input handling
- Edge cases in interpolation
- Producer function source type
- Checkpoint/rewind functionality

### 3. Incremental Lexing (Low Priority)
**Goal**: Support range-based re-lexing for editors

**Tasks**:
- Implement `slice/6` properly (currently stub)
- Add `relex_range/4` functionality
- Create offset↔position mapping
- Support token splicing for incremental updates

### 4. Incremental Lexing (Low Priority)
**Goal**: Support range-based re-lexing for editors

**Not Started**:
- Implement `slice/6` properly
- Add `relex_range/4` functionality
- Create offset↔position mapping
- Support token splicing

## Testing Strategy

### Running Tests
```bash
# Run all tests
mix test

# Run specific test file
mix test test/toxic_test.exs

# Run with coverage
mix test --cover
```

### Test Coverage
- All valid Elixir code scenarios covered
- Error cases need additional tests
- Streaming-specific behaviors need validation

### Adding Tests
When implementing error handling:
1. Create separate test files for error cases (e.g., `test/toxic_error_test.exs`)
2. Test both strict and tolerant modes
3. Verify position accuracy
4. Check error recovery points

## Common Patterns

### Driver State Updates
```elixir
# Pattern for updating driver state
%{state | 
  line: new_line,
  column: new_column,
  scope: new_scope,
  deferrals: updated_deferrals
}
```

### Token Emission
```elixir
# Return token with state update
return_token(token, rest, updated_state)

# Defer token for later
%{state | deferrals: [token | deferrals]}
```

### Context Management
```elixir
# Push interpolation context
contexts: [{:interp, kind, allowed?, delim, parent_terms} | contexts]

# Pop back to normal
contexts: [:normal | rest_contexts]
```

## Debugging Tips

### State Inspection
Add IO.inspect calls to track:
- Current contexts stack
- Deferral queue contents
- Terminator stack state
- Buffer contents in TokenStream

### Token Flow
1. `TokenStream.next/1` → checks buffer
2. Buffer empty → `fetch_tokens_from_driver/3`
3. `Driver.next/2` → processes single token
4. `Tokenizer.tokenize_single/5` → lexical analysis
5. Token returned through chain

### Common Issues
- **Infinite loops**: Check deferral handling
- **Position drift**: Verify column advancement
- **Missing tokens**: Check filtering in `process_token/2`
- **Wrong token type**: Review space-sensitive rewrites

## Architecture Decisions

### Why Deferrals?
Some tokens need delayed emission:
- EOL coalescing
- Space-sensitive identifier rewrites
- Operator lookahead requirements

### Why Separate Contexts?
- Normal mode: Regular tokenization
- Interpolation mode: String content with escapes
- Each mode has different rules

### Why Buffer in TokenStream?
- Amortize driver calls
- Support efficient lookahead
- Enable pushback operations

## Code Style Guidelines

### Naming Conventions
- `tokenize_*` - Functions that consume input
- `handle_*` - Event/result processors
- `*_token` - Token manipulation
- `*_with_*` - Composite operations

### Pattern Matching
```elixir
# Prefer specific matches
def next([?} | rest], %{contexts: [:normal, {:interp, ...}]} = state)

# Over generic guards
def next([c | rest], state) when c == ?}
```

### Error Handling
```elixir
# Return error tuples
{:error, reason, rest, state}

# Not exceptions (except for bugs)
raise ArgumentError, "Invalid state"
```

## Next Session Recommendations

When continuing development:

1. **Start with error handling** - Most critical missing piece
2. **Create error test suite** - Before implementing
3. **Implement simple error cases first** - Unclosed strings, invalid chars
4. **Then tackle recovery** - Sync points and continuation
5. **Add comprehensive test coverage** - Edge cases and error scenarios

## Summary of Actual Implementation

After reviewing the source code (not the outdated design docs):

### ✅ What's Actually Working
- **Streaming tokenizer**: Full single-token streaming via `Driver.next/2`
- **Interpolation streaming**: `Toxic.Interpolation.tokenize_single/7` returns events
- **Token stability**: Deferrals handle all space-sensitive rewrites before emission
- **Terminator tracking**: Available via `current_terminators/1` and `peek_missing_terminator/1`
- **Test parity**: 472/472 tests passing for valid Elixir code

### ❌ What's Actually Missing
- **Error handling**: No error tokens, no recovery, assumes valid input
- **Incremental lexing**: Stubs only for `slice/6` and `relex_range/4`
- **Test coverage**: Missing tests for errors, edge cases, producer functions

## Resources

### Elixir Tokenizer Reference
- Source: `elixir/lib/elixir/src/elixir_tokenizer.erl`
- Compare error handling approaches
- Study sync point strategies

### Similar Projects
- Erlang scanner for comparison
- Other streaming tokenizers (Roslyn, Tree-sitter)
- Language server protocol requirements
