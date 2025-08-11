# Toxic.TokenStream v2 Implementation TODO

Based on API_ELIXIR_v2.md evaluation, this document outlines the step-by-step implementation plan to redesign the tokenizer from batch-based to driver-based streaming.

## Phase 1: Erlang Driver API Implementation

### 1.1 Create Driver State Record
- [ ] Define `#toxic_driver{}` record in `src/toxic_tokenizer.hrl` with fields:
  - `source`: binary or rope structure 
  - `offset`: byte index into source
  - `line`, `column`: current absolute position (exclusive end policy)
  - `scope`: `#toxic_tokenizer{}` with `produce_ranges=true, linearize=true`
  - `mode`: `normal | {interp, Kind, Quote, Delim, Acc}` (stack for nested interpolations)
  - `error_mode`: `strict | tolerant`
  - `error_sync`: list of sync points `[semicolon | newline | closer]`
  - `lookahead_cache`: small buffer for multi-char ops and space-sensitive rewrites
  - `eof`: boolean flag

### 1.2 Implement Driver Initialization
- [ ] Add `toxic_tokenizer:init_driver(String, Line, Column, Opts) -> {ok, Driver}`
  - Force `{produce_ranges, true}` and `{linearize, true}` in opts
  - Initialize driver record with source, position, and scope
  - Support `unescape` option
  - Set default `error_mode` and `error_sync` options

### 1.3 Implement Single Token Pull
- [ ] Add `toxic_tokenizer:next(Driver) -> {ok, Token, Driver1} | {eof, Driver1} | {error_token, Meta, Reason, Driver1}`
  - Replace recursive token-list accumulation with tail-recursive single-token loop
  - Scan exactly one token from current cursor and scope
  - Update `line/column/offset`, `scope.terminators`, and `mode` 
  - Return token immediately (always linearized with ranged metas)
  - Handle EOF when source is exhausted

### 1.4 Implement Terminator Introspection
- [ ] Add `toxic_tokenizer:current_terminators(Driver) -> [{Start, Meta, Indent}]`
  - Extract current terminator stack from driver scope
  - Return list of open terminators with their metadata
- [ ] Add `toxic_tokenizer:peek_missing_terminator(Driver) -> End | nil`  
  - Return the expected closer atom for top terminator on stack
  - Map terminator types to closer symbols: `paren -> ')'`, `bracket -> ']'`, etc.

### 1.5 Optional Callback Mode
- [ ] Add `toxic_tokenizer:scan(String, Line, Column, Opts, EmitFun) -> {ok, FinalState}`
  - Alternative API where `EmitFun(Token, State) -> continue | halt`
  - Useful for streaming without building driver state chain

## Phase 2: Scanner Mechanics Refactor

### 2.1 Convert Recursive Tokenizer to Driver Loop
- [ ] Refactor main `tokenize/5` function into driver-compatible single-token scanner
  - Extract core scanning logic into `scan_token(Driver) -> {Token, Driver1} | {eof, Driver1} | {error, Meta, Reason, Driver1}`
  - Remove token list accumulation and recursion
  - Update position tracking to work with driver state
  - Preserve all existing token type recognition

### 2.2 Implement Streaming Interpolation/String/Heredoc/Sigil
- [ ] Modify string/interpolation handling to emit linearized tokens incrementally:
  - On opening delimiter: emit `*_start` token, push `mode=interp(...)` onto mode stack
  - While in `interp` mode: emit `{string_fragment, FragMeta, Bin}` for raw chunks  
  - On `#{`: emit `{begin_interpolation, Meta, Kind}`, push normal mode, push terminator
  - On `}`: emit `{end_interpolation, Meta, Kind}`, pop mode stack, pop terminator
  - On closing delimiter: emit `*_end` (and `sigil_modifiers` if any), return to `normal`
  - Handle unescape errors in tolerant mode with `{error_token, ...}` and sync

### 2.3 Implement EOL Embed Policy
- [ ] Modify EOL handling for embed mode (recommended for streaming):
  - Never emit standalone `eol` tokens
  - Fold EOL count into emitted token's extra metadata 
  - Avoid retroactive mutation of trailing `eol` tokens
  - Support `:emit` mode for compatibility by surfacing `{eol, Meta}` tokens

### 2.4 Implement Pre-emit Space-sensitive Rewrites
- [ ] Add space-sensitive rewrites and merges before token emission:
  - `identifier` -> `op_identifier` rewrite based on immediate lookahead
  - `not` + `in` merge into single `in_op` with composed meta
  - `do` rebinding of preceding identifier into `do_identifier`
  - Use lookahead cache to make decisions without consuming input

### 2.5 Implement Error-tolerant Mode
- [ ] Add error handling in driver:
  - On lexical error: return `{error_token, Meta, Reason, Driver1}` where `Driver1` has consumed offending runes
  - Implement synchronization by scanning forward to configured sync points:
    - `;` (semicolon)
    - `\n` (newline) 
    - Next matching closer by consulting `terminators` stack
  - In `strict` mode: stop on first error
  - In `tolerant` mode: emit error token and continue after sync

## Phase 3: Interpolation Module Streaming Refactor

### 3.1 Create Streaming Interpolation API
- [ ] Add streaming variant to `toxic_interpolation` module:
  - `extract_stream(Line, Column, Scope, Interpol, Input, Terminator) -> {Event, NewState}`
  - Define event types:
    - `{:fragment, Meta, Bin}` - raw string content
    - `{:begin_interpolation, Meta, Kind}` - start of `#{...}`
    - `{:end_interpolation, Meta, Kind}` - end of interpolation
    - `{:done, Meta, Terminator}` - string/sigil/heredoc complete
    - `{:error, Meta, Reason}` - parse error in interpolation

### 3.2 Integrate Streaming Interpolation with Driver
- [ ] Modify driver to consume interpolation events:
  - Replace buffered parts lists with event-driven token emission
  - Convert interpolation events directly to linearized tokens
  - Handle nested interpolations via mode stack
  - Maintain precise position tracking across fragments and interpolations

## Phase 4: Elixir TokenStream Refactor

### 4.1 Update TokenStream Data Structure  
- [ ] Modify `%Toxic.TokenStream{}` struct:
  - Replace `source`, `line`, `column`, `state` fields with `driver` field
  - Keep `buffer`, `push`, `opts`, `eof`, `error` fields
  - Update type specs accordingly

### 4.2 Refactor Initialization
- [ ] Update `new/4` function:
  - Call `:toxic_tokenizer.init_driver/4` instead of storing source directly
  - Store returned driver in struct
  - Remove manual source normalization (let driver handle it)

### 4.3 Refactor Buffer Refill
- [ ] Update `refill_buffer/1` function:
  - Call `:toxic_tokenizer.next/1` up to `max_batch` times
  - Enqueue `Token` on `{ok, Token, Driver1}` success
  - Handle `{error_token, Meta, Reason, Driver1}` in tolerant mode
  - Set `eof: true` on `{eof, Driver1}`
  - Always update internal `driver` field with new driver state
  - Remove `fetch_tokens/4` function entirely

### 4.4 Update Terminator Introspection
- [ ] Update `current_terminators/1`:
  - Delegate to `:toxic_tokenizer.current_terminators/1` on stored driver
  - Remove stub implementation that returns empty list
- [ ] Update `peek_missing_terminator/1`:
  - Delegate to `:toxic_tokenizer.peek_missing_terminator/1` on stored driver  
  - Remove hardcoded terminator type mapping

### 4.5 Keep Core API Unchanged
- [ ] Verify API compatibility:
  - `next/1`, `peek/1`, `peek_n/2`, `pushback/2` should work unchanged
  - `checkpoint/1`, `rewind_to/2` should work unchanged  
  - `position/1` should delegate to driver position
  - `to_stream/1` should work unchanged

## Phase 5: Enhanced Features

### 5.1 Implement Incremental Lexing
- [ ] Update `slice/6`:
  - Create new driver for slice with rebased metas to `(line_base, column_base)`
  - Use driver's source abstraction for efficient slicing
- [ ] Update `relex_range/4`:
  - Replace driver's input slice and clear buffered tokens overlapping range
  - Continue driver from earliest affected position
  - Handle offset-to-line/column mapping efficiently

### 5.2 Add Minimal Insertion Helper
- [ ] Expose terminator utility functions:
  - Keep existing `terminator/1` mapping in tokenizer
  - Allow Elixir stream to request synthetic closer insertion
  - Return closer token with `Extra` including `{synthetic, true}` metadata

### 5.3 Handle Source Abstractions
- [ ] Support different source types in driver:
  - Binary sources (current)
  - Function-based producers `(line, column) -> {:more, binary()} | :eof`
  - Consider rope or line-indexed structures for efficient offset mapping
  - Handle token boundaries and unmatched terminators properly

## Phase 6: Testing and Validation

### 6.1 Create Driver API Tests
- [ ] Add comprehensive tests for new Erlang driver API:
  - `init_driver/4` with various options
  - `next/1` token-by-token iteration
  - `current_terminators/1` and `peek_missing_terminator/1`
  - Error handling in both strict and tolerant modes
  - Complex interpolation scenarios

### 6.2 Update TokenStream Tests  
- [ ] Fix failing tests in `test/toxic/token_stream_test.exs`:
  - Update tests to work with driver-based implementation
  - Add tests for new terminator introspection functionality
  - Add tests for error-tolerant mode and sync points
  - Add tests for space-sensitive rewrites

### 6.3 Validation Against Current Implementation
- [ ] Create validation suite:
  - Enumerate driver until EOF for test corpus
  - Compare against current `tokenize_with_ranges/4` + `collapse_linear_ranges/1`
  - Ensure token-by-token compatibility
  - Verify position tracking accuracy
  - Test performance characteristics

### 6.4 Integration Tests
- [ ] Add end-to-end tests:
  - Complex nested interpolation scenarios
  - Error recovery and synchronization
  - Incremental lexing and re-lexing
  - Large file streaming performance
  - Memory usage under streaming workloads

## Phase 7: Documentation and Polish

### 7.1 Update Documentation
- [ ] Update module documentation for `Toxic.TokenStream`
- [ ] Add documentation for new Erlang driver API functions
- [ ] Create usage examples for streaming scenarios
- [ ] Document error handling and recovery strategies

### 7.2 Performance Optimization
- [ ] Profile token-by-token overhead vs batch processing
- [ ] Optimize hot paths in driver scanning loop
- [ ] Consider NIFs for heavy unescape operations if needed
- [ ] Benchmark against current implementation

### 7.3 Handle Edge Cases  
- [ ] Address heredoc indentation trimming in streaming mode
  - May require per-line buffering for correct fragment computation
- [ ] Fine-tune error synchronization heuristics
  - Balance forward progress vs excessive skipping
- [ ] Handle malformed input gracefully in both error modes

## Migration Strategy

1. **Maintain Compatibility**: Keep existing batch APIs for backward compatibility during transition
2. **Gradual Rollout**: Implement driver API alongside existing implementation  
3. **Thorough Testing**: Validate driver output against current tokenizer on large corpus
4. **Performance Validation**: Ensure streaming doesn't significantly impact performance
5. **Documentation**: Update all documentation to reflect new streaming capabilities

## Success Criteria

- [ ] All existing tests pass with driver-based implementation
- [ ] New streaming features work correctly (terminator introspection, error tolerance)
- [ ] Performance is comparable or better than current batch implementation  
- [ ] Memory usage remains bounded under streaming workloads
- [ ] Complex interpolation scenarios handle correctly with incremental emission
- [ ] Error recovery works reliably in tolerant mode
- [ ] Incremental lexing enables efficient editor integration