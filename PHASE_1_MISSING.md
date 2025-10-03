  What remains out of scope for Phase 1

  - Structural insertions (synthesized closers/openers/end tokens) remain disabled (insert_structural_closers: false).
  - Terminator mismatch handling (synthesis) will be done in Phase 2.
  - TokenStream tolerant fallback path is not needed for Phase 1 since Driver now handles simple categories and EOF draining.
