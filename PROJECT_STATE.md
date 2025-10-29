# Toxic Tokenizer Project State

## Overview
Toxic is a production-ready streaming tokenizer for Elixir designed to support Pratt parsers with error recovery, incremental lexing, and precise position tracking. The project has reached functional parity with the original Elixir tokenizer for valid code, with comprehensive error recovery capabilities fully implemented and all 821 tests passing.

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

### ✅ Fully Complete (Production-Ready)
- **Streaming Driver**: Core single-token driver with state management (97.72% coverage)
- **Elixir Integration**: TokenStream wrapper with buffering (100% coverage)
- **Position Tracking**: Accurate line/column tracking through error recovery
- **Terminator Stack**: Live exposure via `current_terminators/1` and `closing_for/1`
- **Test Coverage**: 821 tests passing, 0 failures, 94.71% overall coverage
- **Test Parity**: 100% compatibility on valid code, high parity on error messages in strict mode
- **Source Types**: Binary, iolist, and producer function support
- **EOF Handling**: Complex EOF management with buffers and deferrals
- **Strict Error Handling**: Halt lexing on error in strict mode
- **Tolerant Error Handling**: ✅ FULLY IMPLEMENTED
  - Error token emission: `{:error_token, meta, %Toxic.Error{}}`
  - Sync point recovery: semicolon, newline, closer, comma, comment boundaries
  - Structural insertion: Synthesizes matching delimiters (controlled by flags)
  - Context-specific recovery: 8+ specialized error handling cases
  - 150+ tolerant mode tests, 97.72% driver coverage
- **Warning System**: Deprecated constructs, Unicode issues, syntax ambiguities (96.97% coverage)
- **Error Codes**: 30+ structured error types with detailed information

### ⚠️ Partially Implemented
- **Incremental Lexing**: `slice/6` basic (no Unicode), `relex_range/4` stubbed (low priority)

### ❌ Not Critical / Out of Scope
- **Token identity/hashing**: Planned for future incremental use cases
- **Offset-to-position mapping**: Not needed (using line/column directly)

## Resolved Issues

### 1. Error Handling Architecture - ✅ RESOLVED
- **Status**: Fully implemented error token emission with comprehensive recovery
- **Achievement**: Position accuracy maintained during recovery with accurate error spans
- **Implementation**:
  - Tolerant mode: `emit_error_and_advance/2`, `scan_to_sync/2`, `synthesize_from_reason/2`
  - Strict mode: Halt with structured error tuples
  - Terminator stack: `current_terminators/1`, `closing_for/1`
  - Location: `lib/toxic/driver.ex` lines 1053-1502
  - Coverage: 97.72%, 150+ tests

### 2. Performance Profile
- **Current**: Single-pass streaming with deferral system
- **Achieved**: Minimal buffering through driver design
- **Trade-off**: Optimized for incremental use cases over batch throughput
- **Characteristics**: Lower first-token latency, higher memory due to state tracking

## Next Steps

### ✅ Completed Phases
1. **Error Recovery (COMPLETE)**
   - ✅ Error token emission implemented
   - ✅ Sync point recovery (5+ sync types)
   - ✅ Both strict and tolerant modes working
   - ✅ Extensive testing with malformed Elixir code (150+ tests)

### Phase 2: Incremental Lexing (Low Priority)
1. ⚠️ Enhance `slice/6` for Unicode grapheme support
2. ⚠️ Implement `relex_range/4` for range-based re-lexing
3. ❌ Token identity/hashing (planned)
4. ❌ Splice operations for editor integration (future)

### Future Enhancements (Optional)
1. Performance optimization benchmarks
2. Additional edge case tests
3. Enhanced documentation with more examples
4. NIFs for heavy unescape operations (if needed)

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
- **Tolerant mode by default** for IDE/tooling scenarios
  - Emits error tokens inline: `{:error_token, meta, %Toxic.Error{}}`
  - Recovers at sync points: semicolon, newline, closer, comma
  - Optionally synthesizes structural tokens (matching delimiters)
  - Maintains accurate position tracking through recovery
- **Strict mode** available for compilation
  - Returns `{:error, reason, rest, state}` and halts
  - Compatible with Elixir tokenizer error format
- **Minimal insertion strategy** for error recovery
  - Only inserts what's needed to resume parsing
  - Controlled by configuration flags

## Technical Debt
1. **Process Dictionary Checkpoints**: Works well for current use case, but could use alternative storage for better scalability (low priority)
2. **Incremental Lexing**: Complete `slice/6` Unicode support and implement `relex_range/4` (low priority)
3. **EEx Support Comments**: Decide whether to complete or remove EEx-related TODOs
4. **Edge Case Coverage**: Some uncovered paths in `scan_to_sync/4` recovery (very low priority)
5. **Operator Module Coverage**: Currently 40% (specialized, not critical path)

## Performance Characteristics
- **Memory**: Higher due to buffering and state tracking
- **Latency**: Lower first-token latency in streaming mode
- **Throughput**: Optimized for streaming, not batch processing
- **Trade-off**: Designed for incremental/interactive use cases (IDE, REPL)
- **Test Performance**: 821 tests in 8.1 seconds
- **Coverage**: 94.71% overall

## Production Readiness

**Status: PRODUCTION-READY ✅**

**Suitable for:**
- ✅ IDE integration (error recovery, terminator tracking, warnings)
- ✅ Pratt parser integration (streaming, lookahead, backtracking)
- ✅ Production tokenization (both strict and tolerant modes)
- ✅ Error recovery workflows
- ✅ Warning generation and diagnostics

**Not yet suitable for:**
- ⚠️ Incremental editing workflows (slice/relex not complete)

**Quality Metrics:**
- 821 tests, 0 failures
- 94.71% code coverage
- 10,962 lines of test code
- 97.72% coverage on driver (core error handling)
- 100% coverage on TokenStream API layer
- 30+ error codes with detailed information

**See ANALYSIS.md and IMPLEMENTATION_STATUS.md for comprehensive details.**
