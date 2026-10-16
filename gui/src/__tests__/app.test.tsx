import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { expect, it, vi } from "vitest";
import { api } from "@/lib/api";
import App from "@/App";
import { resetJobController } from "@/stores/job";
it("keeps settings reachable when the selected local doctor fails and Docker is absent", async () => {
  await resetJobController();
  vi.spyOn(api, "schema").mockResolvedValue({
    $defs: {
      analysis: {
        properties: {
          analysis_type: { default: "binary" },
          time_unit: { default: "years", enum: ["years"] },
          p_adjust_method: { default: "fdr", enum: ["fdr"] },
          ...Object.fromEntries(
            [
              "outer_folds",
              "inner_folds",
              "repeats",
              "seed",
              "workers",
              "max_features",
              "max_candidates_per_step",
              "bootstrap_samples",
              "selection_frequency",
              "missing_threshold",
              "p_threshold",
              "top_k",
            ].map((key) => [key, { default: 1 }]),
          ),
        },
      },
    },
  });
  vi.spyOn(api, "settings").mockResolvedValue({
    backend: "local",
    rPath: "/bad/Rscript",
    dockerPath: null,
    dockerImage: "unused",
    outputRoot: null,
  });
  vi.spyOn(api, "call").mockResolvedValue({
    success: false,
    cancelled: false,
    exitCode: 1,
    result: { error: "Missing glmnet" },
    verificationError: null,
    stderrTail: [],
  });
  vi.spyOn(api, "status").mockResolvedValue(null);
  render(<App />);
  await waitFor(() =>
    expect(screen.getByRole("button", { name: "Open settings" })).toBeEnabled(),
  );
  fireEvent.click(screen.getByRole("button", { name: "Open settings" }));
  expect(
    screen.getByRole("heading", { name: /^Settings$/ }),
  ).toBeInTheDocument();
  expect(screen.getByText("Missing glmnet")).toBeInTheDocument();
  expect(screen.getByLabelText("Runtime backend")).toHaveValue("local");
  expect(api.call).toHaveBeenCalledWith(
    expect.objectContaining({
      operation: "doctor",
      settings: expect.objectContaining({ backend: "local", dockerPath: null }),
    }),
  );
});
