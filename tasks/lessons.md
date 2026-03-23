# Lessons Learned

## 2026-03-09

- When a user reports UI/animation behavior, confirm all execution modes affected (REPL, single-prompt, web) before proposing root cause.
- Treat model inference and tool execution as separate states in UX; never label tool runtime as "thinking".
- For any interactive tool, explicitly handle non-interactive contexts (web/server mode) with fast, clear failures to avoid hangs.
- **Orphaned spinner via disown in subshell**: never restart a spinner inside a function called via `$(...)`. The new PID lives in the subshell, gets `disown`ed, and becomes an orphan when the subshell exits. The parent's `spinner_stop` kills the original PID only. Fix: let the caller own the full spinner lifecycle; the callee only stops it.
- **`kill` + `set -e`**: `2>/dev/null` suppresses the error message but NOT the exit code. `kill $PID 2>/dev/null` will still trigger `set -e` if the process is already dead. Always use `kill $PID 2>/dev/null || true`.
- **Subshell variable isolation**: assignments to variables inside `$(...)` (including modifications by called functions) never propagate to the parent shell. A function that sets `SPINNER_PID=""` inside a command substitution subshell leaves the parent's `SPINNER_PID` unchanged, pointing at a now-dead process.
- **`set -e` inside functions + ERR trap**: the ERR trap does not fire inside functions unless `set -E` (errtrace) is also active. When a bug causes silent exit from a function, add `set -E` and the ERR trap together to get file:line attribution.
- **Debug strategy for "process exits silently"**: add `debug_log` checkpoints bracketing every line between the last known-good log and the missing next log to binary-search the exact failing line.
- **Command substitution + temp env vars**: `VAR=value output=$(func)` does not reliably make `VAR` available inside the command substitution subshell. If a function inside `$(...)` needs the variable, `export VAR=value` before running the command and `unset` it after.
- **Parameter expansion with JSON defaults**: never write `${var:-{}}` for JSON fallbacks. The closing `}` in `{}` collides with parameter expansion parsing and can append an extra brace when `var` is set. Assign the variable first, then explicitly fallback with `[[ -z "$var" ]] && var='{}'`.
