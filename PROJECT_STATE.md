# Toxic Tokenizer Project State

## Overview
Toxic is a streaming tokenizer for Elixir designed to support Pratt parsers with error recovery, incremental lexing, and precise position tracking. The project has reached functional parity with the original Elixir tokenizer for valid code, with all tests passing.

## Current Architecture

### Two-Layer Design
1. **Driver Layer** (`Toxic.Driver`)
   - Single-token streaming engine
   - Manages lexical contexts and state transitions
   - Handles deferrals for delayed token emission
   - Tracks terminators for error recovery

2. **Stream Layer** (`Toxic.TokenStream`)
   - High-level Elixir API
   - Buffering and lookahead support
   - Pushback capability
   - Position tracking

### Key Components

#### Token Stream (`lib/toxic/token_stream.ex`)
- **Core APIs**: `next/1`, `peek/1`, `peek_n/2`, `pushback/2`
- **Checkpointing**: Support for backtracking via process dictionary
- **Buffer Management**: Queue-based buffering with automatic refill
- **Source Support**: Binary, iodata, and producer functions
- **Position Tracking**: Line/column position management

#### Driver (`lib/toxic/driver.ex`)
- **State Machine**: Context stack for normal/interpolation modes
- **Deferral System**: Priority queue for delayed emissions
- **Terminator Tracking**: Live stack of expected closers
- **Token Processing**: Handles space-sensitive rewrites and transformations

### Token Format
- **Metadata**: `{{start_line, start_column}, {end_line, end_column}, extra}`
- **Linearized Output**: Flat token stream with explicit start/end markers
- **Container Tokens**: 
  - String: `{bin_string_start, ...}` → fragments → `{bin_string_end, ...}`
  - Interpolation: `{begin_interpolation, ...}` → tokens → `{end_interpolation, ...}`
  - Sigil: `{sigil_start, ...}` → fragments → `{sigil_end, ...}` + modifiers

## Implementation Status

### ✅ Completed
- **Streaming Driver**: Core single-token driver with state management
- **Elixir Integration**: TokenStream wrapper with buffering
- **Position Tracking**: Accurate line/column tracking
- **Terminator Stack**: Live exposure for error recovery
- **Test Parity**: (100% compatibility on valid code)
- **Source Types**: Binary, iolist, and producer function support (iolist, and producer function missing coverage)
- **EOF Handling**: Complex EOF management with buffers and deferrals

### 🚧 In Progress
- **Error Handling**: Not implemented - no error token emission or recovery mechanisms

### ❌ Not Implemented
- **Error Recovery**: No sync point recovery or error token emission
- **Incremental Lexing**: `slice/6` and `relex_range/4` are stubs
- **EOL Embed Policy**: Tokens are not mutated after emission, but EOL handling could be improved

## Unresolved Issues

### 1. Error Handling Architecture
- **Current**: No error handling implemented - tokenizer assumes valid input
- **Needed**: Proper error token emission with recovery
- **Challenge**: Maintaining position accuracy during recovery
- **Note**: Terminator stack is available via `current_terminators/1` and `peek_missing_terminator/1`

### 2. Terminator stack peek
- **Current**: Returns state after batch
- **Needed**: Proper state on current token in stream
- **Challenge**: How to store the stacks while refilling buffer

### 3. Performance Optimization
- **Current**: Single-pass streaming with deferral system
- **Achieved**: Minimal buffering through driver design
- **Trade-off**: Optimized for incremental use cases over batch throughput

## Next Steps

### Phase 1: Error Recovery (Priority)
1. Implement error token emission
2. Add sync point recovery (semicolon, newline, closer)
3. Support both strict and tolerant modes
4. Test with malformed Elixir code

### Phase 2: Incremental Lexing
1. Implement offset-to-position mapping
2. Add range-based re-lexing
3. Support splice operations for editor integration

## Design Decisions

### Metadata Format
- Exclusive end positions for precise span tracking
- Extra field for additional information (indentation, etc.)
- Consistent format across all tokens

### Buffering Strategy
- Queue-based buffer with configurable batch size (default 256)
- Automatic refill at 25% capacity
- Separate push buffer for pushback operations

### Context Management
- Stack-based contexts for lexical environments
- Separate tracking for interpolation and normal modes
- Parent terminator preservation through interpolation

### Error Philosophy
- Tolerant mode by default for IDE/tooling scenarios
- Strict mode available for compilation
- Minimal insertion strategy for error recovery

## Technical Debt
1. **Process Dictionary Checkpoints**: Consider alternative storage for checkpoint state
2. **Stub Implementations**: Complete slice and relex functions for incremental lexing
3. **Comment TODOs**: Various TODOs in codebase need addressing
4. **Test Coverage**: Add tests for error cases and edge conditions

## Performance Characteristics
- **Memory**: Higher due to buffering and state tracking
- **Latency**: Lower first-token latency in streaming mode
- **Throughput**: Currently slower than batch due to overhead
- **Trade-off**: Optimized for incremental/interactive use cases
