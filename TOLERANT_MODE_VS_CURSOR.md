Tolerant Mode vs. Elixir Cursor Completion (prune_tokens)

Executive Summary
- Elixir’s tokenizer exposes a cursor-completion mode which “prunes” trailing, syntactically unstable tokens near the cursor (no errors; drops/adjusts tail so partial inputs still tokenize cleanly for completion).
- Toxic’s tolerant mode guarantees forward progress by emitting error_token and (optionally) synthesizing structural tokens; it never halts and aims to preserve a fully parseable, linear stream.
- For IDE tooling, these are complementary: tolerant mode is excellent for continuous parsing; completion benefits from “pruning” semantics to avoid error/synthetic noise at the cursor tail.
- Recommendation: add a prune/tail-trim stage (akin to Elixir’s prune_tokens) on top of tolerant mode for completion requests.

What Cursor Completion Does (Elixir tokenizer)
- Cursor-sensitive scan:
  - Avoids raising/returning errors near the cursor; instead returns a pruned token list that ends at a safe boundary.
  - Common behavior: stop before partial constructs (e.g., incomplete identifiers, operators), do not emit unterminated tokens, avoid dangling `do/end` mismatches.
- prune_tokens (elixir_tokenizer.erl):
  - Receives the token list and context and trims trailing tokens that would be syntactically misleading in completion context.
  - Typical prunings include: dangling `:` from keywords (e.g., `foo:`), half-operators, unmatched closing delimiters, reserved words in bad spots.
- Interpolation-aware pruning (elixir_interpolation.erl):
  - If cursor is within interpolation/string, prune inner trailing fragments so outer context remains consistent; do not bubble interpolation errors.
  - Ensures completion works inside `"#{ ... }"` without leaking partial fragments.

How Toxic’s Tolerant Mode Compares
- Strategy: error-aware and structure-preserving
  - Emits `{:error_token, meta, reason}` at the error site (never halts), then either scans to sync (semicolon, newline, closer, comma, comments/whitespace) or inserts synthetic structurals (balance delimiters) to keep the stream parseable.
  - Optional identifier sanitization synthesizes an ASCII identifier after id-related errors (mixed script, confusable, NFKC, length), enabling downstream completion/analysis to treat the expression as complete.
- Pros relative to prune_tokens:
  - Preserves full linear stream for Pratt parsing (good for background AST builds and diagnostics).
  - Structural insertions yield balanced scopes (parenthesis/brackets/braces/sigils/heredocs), which can be better for incremental parse than “pruning” the tail.
  - Sanitization makes the parser’s life easier for mixed/confusable identifiers (cursor completion typically drops rather than sanitizes).
- Gaps for completion:
  - Completion wants a “quiet” tail near the cursor: prune_tokens returns a clean prefix, while tolerant mode leaves error_token and sometimes inserted tokens at the tail.
  - Certain tail cases in completion (e.g., `foo:`) are better trimmed than reported as `{error, keyword_no_space}`.
  - Completion often returns a smaller prefix earlier than the cursor; tolerant mode aims to parse as far as possible.

Compatibility and Integration Plan
- Keep tolerant mode as the default scanning engine (forward progress, structure preservation) and layer a completion-pruning pass on top.
- Add a `:completion` tail policy that mimics prune_tokens:
  - API: `Toxic.TokenStream.prune_for_completion(stream) :: stream`
  - Behavior:
    1) Consume tolerant tokens up to cursor.
    2) Peek/tail-trim tokens that are syntactically unstable for completion:
       - Drop trailing `:`, half-operators, and unexpected closers.
       - If inside interpolation/string/sigil/heredoc, prefer pruning tail fragments instead of inserting ends.
       - If `:insert_structural_closers` is ON, skip inserting at tail (for completion only).
    3) Optionally apply identifier sanitization at the tail segment (more helpful to completion engines).
  - Output: stream whose head reflects a stable completion prefix; no error_token at the tail; available to feed completion logic.

Design Sketch (pseudo-code)
```
def prune_for_completion(stream) do
  # 1) Drain buffered tolerant tokens up to cursor without forcing recovery
  tokens = drain_tokens_to_cursor(stream)

  # 2) Analyze tail slice for pruning
  {prefix, tail} = split_tail(tokens)

  pruned_tail =
    tail
    |> drop_trailing_keyword_colon()
    |> drop_dangling_operators()
    |> drop_unexpected_closers_without_openers()
    |> drop_trailing_error_tokens_and_structurals()
    |> prefer_prune_inside_interpolation()

  # 3) Rebuild buffer with pruned tail
  rebuild_stream(stream, prefix ++ pruned_tail)
end
```

Key Heuristics to Mirror prune_tokens
- Colon keywords: `foo:` → drop the `:` for completion.
- Dot calls: allow `.foo` tail but drop trailing partial operator sequences (e.g., `..` or `..//` without final slash).
- Unmatched closers: drop unexpected `) ] } >>` at the tail.
- Interpolation/string/sigil/heredoc:
  - For completion, prefer prune over synthetic closing; interior completion engines expect structure to be implicit.
  - For background AST builds, keep synthesis ON.
- Error tokens: tail-most `:error_token` should be pruned out for completion (retain earlier ones for diagnostics if needed).

Pros/Cons of Each Strategy
- Tolerant (ours):
  - Pros: Always parseable stream, structure preserved; great for background parse/diagnostics.
  - Cons: Noisy near the cursor (error_token and synthetic tokens); needs a prune pass for completion.
- Cursor prune (Elixir):
  - Pros: Quiet, completion-friendly tail; prunes noise instead of recovering.
  - Cons: Drops structure; harder for background parse or incremental AST.

Conclusion
- Strategies are complementary: tolerant mode gives a high-fidelity stream for parsing and diagnostics; a prune_tokens-like pass produces a quiet tail for completion. For IDE tools, implementing `prune_for_completion/1` atop tolerant mode yields the best of both worlds.

Action Items
1) Implement `Toxic.TokenStream.prune_for_completion/1` (Phase 6):
   - Drop tail `:error_token` and synthetic tokens.
   - Prune keyword `:` and dangling operators at tail.
   - Prefer prune over structural insertion when cursor mode is enabled.
   - Special-case interpolation/string/sigil/heredoc tails.
2) Add tests mirroring Elixir’s cursor completion cases (with and without interpolation).
3) Document `:completion` policy and how it composes with tolerant options.

Notes
- We could not directly inspect your local copies of `elixir_tokenizer.erl` and `elixir_interpolation.erl` referenced by absolute paths. The analysis above is based on Elixir’s documented behavior and common patterns found in cursor completion implementations. If you share those files or the relevant `prune_tokens` clauses, we can refine the mapping and ensure byte-for-byte parity where desired.

