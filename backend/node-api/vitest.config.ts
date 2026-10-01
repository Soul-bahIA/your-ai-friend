import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // V3 LOT 1 : configuration centrale hermétique (test/helpers/hermeticSettings.ts).
    setupFiles: ["./test/helpers/hermeticSettings.ts"],
  },
});
