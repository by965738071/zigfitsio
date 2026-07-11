import { defineConfig } from "vitest/config";

// One fork for the whole suite. The default forks pool spawns a fresh child
// process per test file; on Windows the exit-of-one/spawn-of-next handoff
// with the native DLL loaded dies with a tinypool "Channel closed"
// (ERR_IPC_CHANNEL_CLOSED) — deterministically with a Debug build, whose
// slower calls shift the race window (CI run 28728918857, both attempts).
// A single fork removes every mid-run handoff while keeping the process
// boundary; the suite is sub-second, so serial file execution costs nothing.
// The Bun lane already exercises the same all-files-one-process model.
export default defineConfig({
  test: {
    pool: "forks",
    poolOptions: {
      forks: {
        singleFork: true,
      },
    },
  },
});
