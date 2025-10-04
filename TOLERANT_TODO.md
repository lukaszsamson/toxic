Decide whether tolerant mode should synthesize missing string/heredoc closers, then restore the stronger expectations
     once driver support exists.


All good — they’re tolerant-mode tests, not strict.

  What’s happening

  - Our tolerant defaults now synthesize structure and also re-emit the actual closer after an “unexpected closer” error.
  - In token_stream_test, those two tests assume “minimal” tolerant mode (no synthesis, no closer re‑emit), so they assert
    EOF right after the error. With synthesis on, you see extra tokens (synthetic opener and/or the actual closer), so
    assertions fail.

  Two clean ways to resolve:

  - Update tests to opt out of Phase 2 behavior:
      - test/toxic/token_stream_test.exs:1056 and 1137
      - Create the stream with insert_structural_closers: false, e.g.:
          - TokenStream.new("}", 1, 1, error_mode: :tolerant, insert_structural_closers: false)
          - TokenStream.new("1 }", 1, 1, error_mode: :tolerant, insert_structural_closers: false)
      - If you also want to drop the literal closer entirely, we’d need to adjust the test expectation or gate “re-emit
        actual closer” (see next option).
  - Gate “re-emit actual closer” behind a flag (and keep default on):
      - Add an option (or tie it to insert_structural_closers) so re-emission is disabled when tests want minimal tolerant
        mode.
      - This keeps tolerant_mode tests that expect the actual closer with “no synthesis” intact, but would require aligning
        that test to the gate as well.

  Given the current suite, the least invasive is to set insert_structural_closers: false in those two token_stream tests.
  Want me to update them accordingly, or would you prefer I add a dedicated flag to gate closer re-emission?
