import { beforeEach, afterEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { checkEnv, readTextFile } from "@/lib/tauri/commands";
import { formatAuc, parseAucCsv } from "@/lib/auc";
import { refreshEnvironment } from "@/lib/environment";
import { useConfigStore } from "@/stores/configStore";
import { usePredictionStore } from "@/stores/predictionStore";
import { EnvironmentSetup } from "@/components/environment/EnvironmentSetup";
import { AucTable } from "@/components/results/AucTable";
import { SettingsPage } from "@/pages/SettingsPage";
import { PredictionPage } from "@/pages/PredictionPage";
import type { DockerStatus, EnvStatus } from "@/types/analysis";

vi.mock("@/lib/tauri/commands", () => ({
  checkEnv: vi.fn(), readTextFile: vi.fn(), pullDockerImage: vi.fn(), cancelSetup: vi.fn(),
  pickFile: vi.fn(), readCsvHeader: vi.fn(), loadModel: vi.fn(), runPrediction: vi.fn(),
  cancelPrediction: vi.fn(), saveFile: vi.fn(),
}));

function environment(dockerStatus: DockerStatus, dockerError: string | null = null): EnvStatus {
  return {
    dockerStatus, dockerError,
    dockerAvailable: ["ready", "image_missing", "image_inspect_failed"].includes(dockerStatus),
    dockerImagePresent: dockerStatus === "ready",
    pixiInstalled: false, rAvailable: false, packagesOk: false,
    rPath: null, pixiPath: null, rVersion: null,
  };
}

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: string) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

beforeEach(() => {
  vi.clearAllMocks();
  useConfigStore.setState({ envStatus: null, envChecking: false, envCheckError: null, setupStatus: "idle", setupLogs: [], setupError: "" });
  usePredictionStore.getState().resetAll();
  Element.prototype.scrollIntoView = vi.fn();
});

afterEach(cleanup);

describe("AUC metadata and CSV diagnostics", () => {
  it("preserves missing values and quoted reasons without changing genuine zero", () => {
    const rows = parseAucCsv('"seed","trainAUC","testAUC","trainAUC_reason","testAUC_reason","genes"\r\n1,NA,0,"No cases, before horizon","","A,B"\r\n2,NaN,,"cdROC: ""invalid""\nmarker",NA,"C;D"');
    expect(rows).toEqual([
      { iteration: 1, trainAuc: null, testAuc: 0, trainReason: "No cases, before horizon", testReason: null, genes: "A,B" },
      { iteration: 2, trainAuc: null, testAuc: null, trainReason: 'cdROC: "invalid"\nmarker', testReason: "AUC unavailable; no reason recorded", genes: "C, D" },
    ]);
    expect(formatAuc(null, 3)).toBe("NA");
    expect(formatAuc(Number.NaN, 3)).toBe("NA");
    expect(formatAuc(0, 3)).toBe("0.000");
    expect(parseAucCsv("seed,genes\n1,A")[0].trainAuc).toBeNull();
  });

  it("renders NA and its full CSV reason in the existing AUC component", async () => {
    vi.mocked(readTextFile).mockResolvedValue('seed,train_auc,test_auc,test_auc_reason\n1,0.85,NA,"No cases, before horizon"');
    render(<AucTable outputDir="/synthetic" />);
    await screen.findByText("NA");
    expect(screen.getByText("0.8500")).toBeDefined();
    expect(screen.getByText("No cases, before horizon")).toBeDefined();
    expect(screen.queryByText("NaN")).toBeNull();
  });

  it("shows saved missing AUC reasons and fixed survival threshold in model details", () => {
    usePredictionStore.getState().setModelInfo({
      version: "0.4.3", created_at: "", analysis_type: "survival", variable_count: 1,
      variables: ["GENE"], formula: "GENE", train_auc: 0.85, test_auc: null,
      train_auc_reason: null, test_auc_reason: "No cases before horizon",
      optimal_threshold: null, risk_threshold: 2.75,
      risk_threshold_scale: "exp_uncentered_linear_predictor",
      training_data_file: "synthetic.csv", training_sample_count: 30, config: null,
    });
    render(<PredictionPage />);
    expect(screen.getByText("0.850 / NA")).toBeDefined();
    expect(screen.getByText("Test AUC: No cases before horizon")).toBeDefined();
    expect(screen.getByText("2.7500")).toBeDefined();
    expect(screen.getByText("Scale: exp(uncentered linear predictor)")).toBeDefined();
  });
});

describe("shared environment request ordering", () => {
  it("ignores stale success and finally while a newer request is pending", async () => {
    const old = deferred<EnvStatus>();
    const current = deferred<EnvStatus>();
    vi.mocked(checkEnv).mockReturnValueOnce(old.promise).mockReturnValueOnce(current.promise);
    const first = refreshEnvironment();
    const second = refreshEnvironment();
    old.resolve(environment("ready"));
    await first;
    expect(useConfigStore.getState().envStatus).toBeNull();
    expect(useConfigStore.getState().envChecking).toBe(true);
    current.resolve(environment("windows_containers"));
    await second;
    expect(useConfigStore.getState().envStatus?.dockerStatus).toBe("windows_containers");
    expect(useConfigStore.getState().envChecking).toBe(false);
  });

  it("ignores a stale error after a newer success", async () => {
    const old = deferred<EnvStatus>();
    vi.mocked(checkEnv).mockReturnValueOnce(old.promise).mockResolvedValueOnce(environment("ready"));
    const first = refreshEnvironment();
    await refreshEnvironment();
    old.reject("old pipe error");
    await first;
    expect(useConfigStore.getState().envStatus?.dockerStatus).toBe("ready");
    expect(useConfigStore.getState().envCheckError).toBeNull();
    expect(useConfigStore.getState().envChecking).toBe(false);
  });

  it("ignores stale success after the latest failure", async () => {
    const old = deferred<EnvStatus>();
    vi.mocked(checkEnv).mockReturnValueOnce(old.promise).mockRejectedValueOnce("latest IPC error");
    const first = refreshEnvironment();
    await refreshEnvironment();
    old.resolve(environment("ready"));
    await first;
    expect(useConfigStore.getState().envStatus).toBeNull();
    expect(useConfigStore.getState().envCheckError).toBe("latest IPC error");
    expect(useConfigStore.getState().envChecking).toBe(false);
  });

  it("shares ordering between setup and a settings refresh", async () => {
    const old = deferred<EnvStatus>();
    const current = deferred<EnvStatus>();
    vi.mocked(checkEnv).mockReturnValueOnce(old.promise).mockReturnValueOnce(current.promise);
    render(<SettingsPage />);
    fireEvent.click(screen.getByRole("button", { name: "Refresh Status" }));
    render(<EnvironmentSetup />);
    expect(checkEnv).toHaveBeenCalledTimes(2);
    await act(async () => { old.reject("old settings error"); });
    expect(useConfigStore.getState().envChecking).toBe(true);
    expect(useConfigStore.getState().envCheckError).toBeNull();
    await act(async () => { current.resolve(environment("image_missing")); });
    await waitFor(() => expect(useConfigStore.getState().envChecking).toBe(false));
    expect(useConfigStore.getState().envStatus?.dockerStatus).toBe("image_missing");
  });
});

describe.each(["setup", "settings"] as const)("%s Docker diagnostics", (page) => {
  it.each([
    ["cli_missing", "Docker executable not found"],
    ["engine_unreachable", "Engine connection failed"],
    ["windows_containers", "Windows containers mode"],
    ["engine_check_failed", "Container mode could not be verified"],
    ["image_inspect_failed", "Image check failed"],
  ] as const)("does not report a missing image for %s", async (status, message) => {
    const error = "original Docker diagnostic";
    const result = environment(status, error);
    useConfigStore.setState({ envStatus: result });
    vi.mocked(checkEnv).mockResolvedValue(result);
    render(page === "setup" ? <EnvironmentSetup /> : <SettingsPage />);
    await waitFor(() => expect(useConfigStore.getState().envChecking).toBe(false));
    expect(screen.getByText(message, { exact: page === "settings" })).toBeDefined();
    expect(screen.getByText(error)).toBeDefined();
    expect(screen.queryByText(/Not downloaded/)).toBeNull();
    expect(screen.queryByRole("button", { name: "Download Analysis Image" })).toBeNull();
  });

  it("offers download only for a confirmed missing image", async () => {
    const result = environment("image_missing");
    useConfigStore.setState({ envStatus: result });
    vi.mocked(checkEnv).mockResolvedValue(result);
    render(page === "setup" ? <EnvironmentSetup /> : <SettingsPage />);
    await screen.findByRole("button", { name: "Download Analysis Image" });
    expect(screen.getByText(/Not downloaded/)).toBeDefined();
  });
});
