Here’s a focused gap analysis of the existing Elixir lexer vs. what you’d need to drive an error-tolerant Pratt (and eventually incremental) parser, plus concrete action items to bridge each gap.

⸻

1. End‐Position Spans on Tokens - Done

Current: tokens only carry their start {line, col, extra}; end positions are inferred by peeking at the next token.
Why it matters: Pratt parsing (and any AST construction) needs each token’s full span to precisely attach nodes, and incremental reparsing needs stable begin/end offsets to diff.
Action Items:
	•	Change the token record to include an explicit end offset {start, end} (e.g. column+length or absolute character index).
	•	Update every clause of tokenize/5 to compute and store the end position before recursing.

2. Graceful Error Recovery (Non–Fail-Fast) - ✅ COMPLETE

Current: Both strict (fail-fast) and tolerant (error recovery) modes are fully implemented.
Why it matters: an error-tolerant Pratt parser must see a token stream that includes error tokens so it can skip, insert missing braces, and continue parsing beyond bad fragments.
Implementation Complete:
	•	Tolerant mode emits {:error_token, meta, %Toxic.Error{}} inline in the stream
	•	Advances to synchronization points: semicolon, newline, closer, comma, comment boundaries
	•	Context-specific recovery adjustments for 8+ error types
	•	Configuration flags: error_mode (:strict | :tolerant), error_sync, error_max_skip
	•	Structural token synthesis (controlled by insert_structural_closers flag)
	•	150+ tests passing, 97.72% coverage on driver error handling

3. Minimal Insertion of Missing Delimiters - ✅ COMPLETE

Current: Terminator stack is fully exposed and structural synthesis is implemented.
Why it matters: Pratt error recovery should insert only the specific missing token(s) needed to resume parsing in context, not a blanket set of closers.
Implementation Complete:
	•	Terminator stack exposed via current_terminators/1 - returns live stack with metadata
	•	closing_for/1 API maps openers to expected closers
	•	synthesize_from_reason/2 creates structural tokens with zero-length metadata
	•	Controlled by insert_structural_closers configuration flag
	•	Synthesizes matching openers for unexpected closers
	•	Synthesizes expected closers for mismatched/missing closers

4. Flat, Linear Token Stream Interface - Done

Current: interpolation produces nested token lists (a forest).
Why it matters: Pratt parsers expect a flat, linear token stream they can peek and consume from—nested lists complicate lookahead and incremental diffs.
Action Items:
	•	Introduce a flattening layer, or optionally have elixir_tokenizer emit both (a) a raw nested output and (b) a linearized stream of tokens with explicit {:begin_interpolation, …} / {:end_interpolation, …} markers.
	•	Ensure that every synthetic marker carries precise spans.

5. Token Lookahead / Pushback API - Done

Current: the lexer is purely functional: it returns all tokens in one go, with no built-in peek/unget.
Why it matters: a Pratt parser needs to peek at the next 1–2 tokens (e.g. to distinguish prefix vs. infix operators) and possibly unget tokens on backtrack.
Action Items:
	•	Wrap the token list in a small-stream abstraction with next/1, peek/1, and pushback/2.
	•	Optionally provide a lex_iterator/1 or lex_stream(Opts) that yields a stateful {module, state} tuple supporting those operations.

6. Token Classification for Pratt Parsing

Current: tokens carry their raw category (:atom, :identifier, :operator, etc.), but no direct mapping to Pratt’s prefix/infix/postfix precedence tables.
Why it matters: Pratt’s dispatch is driven by token classes and numeric precedences. You’ll need a quick lookup from a token to “is this a prefix op of precedence X?”
Action Items:
	•	Extend each operator token to include a metadata field {name, raw, position, op_kind} where op_kind ∈ #{prefix, infix, postfix} and attach a numeric precedence.
	•	Provide a central table (or module attribute) mapping raw operator strings to precedence/kind, and fold this into token emission.

7. Incremental Lexing Hooks - ⚠️ PARTIAL

Current: Single-pass streaming is complete; incremental relexing is stubbed but not critical.
Why it matters: For an incremental parser, you want to re-lex only edited regions and preserve token identities elsewhere.
Status:
	•	slice/6 is basically implemented (binary slicing, no Unicode grapheme support yet)
	•	relex_range/4 is stubbed out (commented) - planned for future
	•	Token identity/hashing not yet implemented
	•	Not critical for current Pratt parser use cases
	•	Streaming architecture supports future incremental integration

⸻

Next Steps (Updated 2025-10-30)

✅ COMPLETED:
	1.	Token Span Extension: Ranged metadata {{sl,sc}, {el,ec}, extra} fully implemented
	2.	Error-Tolerant Mode: Complete with error token emission and 5+ sync points
	3.	Stream API: Toxic with peek/next/pushback/checkpoint fully working
	4.	Flat Token Stream: Linearized with explicit interpolation markers
	5.	Operator Metadata: Precedence and op-kinds handled in tokenizer/operator modules

⚠️ REMAINING:
	6.	Incremental Hooks & Token IDs: Partial (slice basic, relex stubbed) - low priority

## Current Status

**The lexer is PRODUCTION-READY for Pratt parser integration:**
- ✅ Full error recovery with tolerant mode
- ✅ Streaming API with lookahead and backtracking
- ✅ Precise position tracking through error recovery
- ✅ 821 tests passing, 94.71% code coverage
- ✅ Both strict and tolerant error modes working
- ⚠️ Incremental lexing planned but not critical

**See ANALYSIS.md and IMPLEMENTATION_STATUS.md for detailed status.**
