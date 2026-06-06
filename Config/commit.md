## Commit message

Generate a Git commit message from the diff. Output ONLY the message text.

Constraints:
- Language: English strictly (NEVER use Chinese, even if the diff is in Chinese)
- Title: <type>: <summary> (feat, chore, update, fix, docs, ci, revert, etc. Max 60 chars, imperative, no period)
- Body: Omit by default. Include extremely short "-" bullets ONLY if the Title is absolutely insufficient.
