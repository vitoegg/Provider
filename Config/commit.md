## Commit Message

Generate a Git commit message from the diff. **Output ONLY the message text.**

### Constraints

1. **Language**: English strictly (NEVER use Chinese, even if the diff is in Chinese).
2. **Title Format**: `<type>: <summary>`
   - *Types*: `feat`, `chore`, `update`, `fix`, `docs`, `ci`, `revert`, etc.
   - *Summary Rules*: Max 60 chars, imperative mood, no trailing period.
3. **Body**: Omit by default. Include extremely short `-` bullets **ONLY** if the Title is absolutely insufficient.
