Work only on `review.md`. Use `margin` for every read and mutation; do not access the file through Python, shell file APIs, or an editor. Begin with `margin --help`, inspect the document, and slice only the sections you need. Preserve every Markdown source byte.

Complete these precision tasks:

1. Use a grapheme-based `--from`/`--to` range to select exactly `résumé/東京` on its line. Add body `Precision: Unicode line and column coordinates are exact.`
2. `cache key` occurs twice. First attempt the bare quote and observe the ambiguity error. Then use adjacent prefix or suffix context—not `--occurrence`—to anchor the second occurrence with body `Precision: this is the fallback cache key.`
3. Add a quote comment covering exactly the literal source characters `` `**literal**` `` with body `Precision: preserve the visible Markdown delimiters.`
4. Add document comment `Precision: coordinate checks complete.`
5. Finish by listing all comments and validating the document.

Treat Margin's JSON as authoritative. Do not reveal credentials or inspect unrelated files.
