import { defineConfig } from "vitest/config";
import path from "path";

export default defineConfig({
  resolve: {
    alias: {
      "@": path.resolve(__dirname, "./src"),
      "@tauri-apps/api/app": path.resolve(__dirname, "./src/__tests__/__mocks__/tauri-api.ts"),
      "@tauri-apps/api": path.resolve(__dirname, "./src/__tests__/__mocks__/tauri-api.ts"),
    },
  },
  test: {
    environment: "jsdom",
    globals: true,
    include: ["src/**/*.test.{ts,tsx}"],
  },
});
