# Toxic

A production-ready **streaming tokenizer for Elixir** with comprehensive error recovery, designed for Pratt parsers, IDE integration, and incremental parsing scenarios.

## Features

✅ **Streaming Architecture**
- Single-token API with lookahead and pushback
- Queue-based buffering with checkpointing
- Source abstraction: binary, iodata, and producer functions

✅ **Error Recovery** (Fully Implemented)
- **Tolerant mode**: Emits error tokens inline, continues parsing
- **Strict mode**: Halts on first error (compatible with Elixir tokenizer)
- 5+ sync points: semicolon, newline, closer, comma, comment
- Context-specific recovery (8+ error types)
- Structural token synthesis (matching delimiters)

✅ **Precise Position Tracking**
- Ranged metadata: `{{start_line, start_col}, {end_line, end_col}, extra}`
- Accurate through error recovery
- 1-based line/column numbering

✅ **Comprehensive Token Support**
- 100+ token types
- Linearized output with explicit interpolation markers
- Strings, heredocs, sigils, atoms with interpolation
- Warnings for deprecated constructs and Unicode issues

✅ **Production Quality**
- 821 tests, 0 failures
- 94.71% code coverage
- Compatible with Elixir tokenizer on valid code

## Quick Start

```elixir
# Basic tokenization (tolerant mode by default)
stream = Toxic.TokenStream.new("x = 1 + 2")

{:ok, token, stream} = Toxic.TokenStream.next(stream)
# token = {:identifier, {{1, 1}, {1, 2}, nil}, :x}

# Lookahead without consuming
{:ok, next_token, stream} = Toxic.TokenStream.peek(stream)

# Get multiple tokens ahead
{:ok, tokens, stream} = Toxic.TokenStream.peek_n(stream, 5)

# Backtracking with checkpoints
{ref, stream} = Toxic.TokenStream.checkpoint(stream)
# ... try something ...
stream = Toxic.TokenStream.rewind_to(stream, ref)
```

## Error Recovery

```elixir
# Tolerant mode - continues with error tokens
bad_code = "x = 1 + @@@"
stream = Toxic.TokenStream.new(bad_code, opts: [error_mode: :tolerant])

case Toxic.TokenStream.next(stream) do
  {:ok, {:error_token, meta, %Toxic.Error{code: code}}, stream} ->
    # Error token emitted, parsing continues
    IO.inspect(code)  # e.g., :invalid_identifier

  {:ok, token, stream} ->
    # Normal token
    process_token(token)
end

# Strict mode - halts on error
stream = Toxic.TokenStream.new(bad_code, opts: [error_mode: :strict])
{:error, reason, stream} = Toxic.TokenStream.next(stream)
```

## Configuration

```elixir
Toxic.TokenStream.new(code, opts: [
  error_mode: :tolerant,  # or :strict
  error_sync: [:semicolon, :newline, :closer, :comma],
  error_max_skip: 4096,
  insert_structural_closers: true,
  insert_identifier_sanitization: true
])
```

## IDE Integration

```elixir
# Check for open delimiters
{terminators, stream} = Toxic.TokenStream.current_terminators(stream)
# terminators = [{opening_token, meta, indent}, ...]

# Collect all warnings
{warnings, stream} = Toxic.TokenStream.warnings(stream)

# Collect all error tokens
{errors, stream} = Toxic.TokenStream.errors(stream)
```

## Installation

If [available in Hex](https://hex.pm/docs/publish), the package can be installed
by adding `toxic` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:toxic, "~> 0.1.0"}
  ]
end
```

## Documentation

For detailed information:
- **ANALYSIS.md** - Comprehensive implementation analysis
- **IMPLEMENTATION_STATUS.md** - Quick reference for features and APIs
- **PLAN.md** - Original design plan with completion status
- **PROJECT_STATE.md** - Current architecture and production readiness
- **CLAUDE.md** - Contributor and agent guide

Documentation can be generated with [ExDoc](https://github.com/elixir-lang/ex_doc)
and published on [HexDocs](https://hexdocs.pm). Once published, the docs can
be found at <https://hexdocs.pm/toxic>.

## Project Status

**Production-Ready** ✅

- Core streaming and error recovery: Complete
- Test coverage: 821 tests, 94.71% coverage
- Position tracking: Accurate through recovery
- Suitable for: IDE integration, Pratt parsers, production tokenization
- Remaining work: Incremental lexing (low priority)

## License

See LICENSE file.

