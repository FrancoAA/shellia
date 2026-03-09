# Lessons Learned

## 2026-03-09

- When a user reports UI/animation behavior, confirm all execution modes affected (REPL, single-prompt, web) before proposing root cause.
- Treat model inference and tool execution as separate states in UX; never label tool runtime as "thinking".
- For any interactive tool, explicitly handle non-interactive contexts (web/server mode) with fast, clear failures to avoid hangs.
