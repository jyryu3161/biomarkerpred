import schemaText from "../../../config/schema.json?raw";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { api } from "@/lib/api";
import { properties, schemaDefaults } from "@/lib/value";
import type { EngineResponse, JsonObject, RuntimeSettings } from "@/lib/types";
import {
  changeAnalysisType,
  saveSettings,
  updateConfig,
  useWorkspace,
  validateConfiguration,
} from "@/stores/workspace";
const schema = JSON.parse(schemaText) as JsonObject;
const settings: RuntimeSettings = {
  backend: "local",
  rPath: "/locked/Rscript",
  dockerPath: null,
  dockerImage: "unused-local",
  outputRoot: "/history",
};
const success = (result: JsonObject): EngineResponse => ({
  success: true,
  cancelled: false,
  exitCode: 0,
  result,
  verificationError: null,
  stderrTail: [],
});
beforeEach(() => {
  useWorkspace.setState({
    schema,
    settings,
    config: schemaDefaults(schema, "binary"),
    revision: 0,
    validation: null,
    validatedConfig: null,
    validationError: null,
    validating: false,
    dataInfo: null,
    doctor: success({ ok: true }),
  });
  vi.spyOn(api, "header").mockResolvedValue({
    path: "/data.csv",
    rowCount: 80,
    columns: ["sample", "gene,quoted", "gene\nnew"],
    preview: {},
  });
});
describe("shared schema, exact fields and authoritative QC", () => {
  it("reads installed defaults including survival nulls and makes independent array copies", () => {
    const binary = schemaDefaults(schema, "binary"),
      survival = schemaDefaults(schema, "survival");
    expect(binary.outer_folds).toBe(properties(schema).outer_folds.default);
    expect(survival.outcome).toBeNull();
    expect(survival.horizon).toBe(5);
    expect(survival.event).toBe("OS");
    (binary.panel_sizes as number[]).push(99);
    expect(properties(schema).panel_sizes.default).not.toContain(99);
  });
  it("retains exact quoted and newline identifiers in schema fields without delimiter splitting", async () => {
    updateConfig({
      data_file: "/data.csv",
      sample_id: "sample",
      group_column: "patient",
      clinical_columns: ["age", "clinical,quoted"],
      include: ["gene,quoted", "gene\nnew"],
      positive_class: "01",
      positive_label: "반응",
      workers: 2,
      outer_folds: 3,
      panel_sizes: [1, 2],
    });
    const current = structuredClone(useWorkspace.getState().config);
    vi.spyOn(api, "call").mockResolvedValue(
      success({ config: current, qc: { status: "passed" } }),
    );
    await validateConfiguration();
    expect(api.call).toHaveBeenCalledWith({
      operation: "validate",
      config: current,
      settings,
    });
    expect(useWorkspace.getState().validatedConfig?.include).toEqual([
      "gene,quoted",
      "gene\nnew",
    ]);
    expect(useWorkspace.getState().validatedConfig?.positive_class).toBe("01");
  });
  it("invalidates QC on any edit and ignores a delayed validation of previous fields", async () => {
    let finish!: (response: EngineResponse) => void;
    vi.spyOn(api, "call").mockReturnValue(
      new Promise((resolve) => {
        finish = resolve;
      }),
    );
    const check = validateConfiguration();
    updateConfig({ seed: 90 });
    finish(success({ config: { seed: 1 }, qc: { status: "passed" } }));
    await check;
    expect(useWorkspace.getState().config.seed).toBe(90);
    expect(useWorkspace.getState().validatedConfig).toBeNull();
    vi.mocked(api.call).mockResolvedValue(
      success({ config: { seed: 90 }, qc: { status: "passed" } }),
    );
    await validateConfiguration();
    expect(useWorkspace.getState().validatedConfig?.seed).toBe(90);
    updateConfig({ evidence: { gene_file: "/snapshot.csv" } });
    expect(useWorkspace.getState().validatedConfig).toBeNull();
  });
  it("imports through the original config path and uses only normalized R settings", async () => {
    const normalized = {
      ...schemaDefaults(schema, "survival"),
      data_file: "/resolved/data.csv",
      outcome: null,
    };
    vi.spyOn(api, "call").mockResolvedValue(
      success({ config: normalized, qc: { status: "passed" } }),
    );
    await validateConfiguration("/original/config, name.yaml");
    expect(api.call).toHaveBeenCalledWith({
      operation: "validate",
      options: { config: "/original/config, name.yaml" },
      settings,
    });
    expect(useWorkspace.getState().config).toEqual(normalized);
  });
  it("preserves structured invalid QC and clearly states when an invalid import was not applied", async () => {
    vi.spyOn(api, "call").mockResolvedValue({
      ...success({
        error: "duplicate sample IDs",
        qc: { status: "failed", errors: ["00001 repeated"] },
      }),
      success: false,
      exitCode: 1,
    });
    await validateConfiguration("/bad.yaml");
    expect(useWorkspace.getState().validation?.result.qc).toEqual({
      status: "failed",
      errors: ["00001 repeated"],
    });
    expect(useWorkspace.getState().validationError).toContain(
      "was not applied",
    );
    expect(useWorkspace.getState().validatedConfig).toBeNull();
  });
  it("checks saved local settings without depending on Docker and updates the untouched default output root", async () => {
    vi.spyOn(api, "saveSettings").mockImplementation(async (value) => value);
    vi.spyOn(api, "call").mockResolvedValue(
      success({ ok: true, operation: "doctor" }),
    );
    await saveSettings({ ...settings, outputRoot: "/new-history" });
    expect(api.call).toHaveBeenCalledWith({
      operation: "doctor",
      settings: { ...settings, outputRoot: "/new-history" },
    });
    expect(useWorkspace.getState().doctor?.success).toBe(true);
    expect(useWorkspace.getState().config.output_dir).toBe("/new-history");
  });
  it("switches endpoint defaults while retaining selected assay/group fields", () => {
    updateConfig({ group_column: "patient", include: ["gene,quoted"] });
    changeAnalysisType("survival");
    expect(useWorkspace.getState().config).toMatchObject({
      analysis_type: "survival",
      horizon: 5,
      outcome: null,
      group_column: "patient",
      include: ["gene,quoted"],
      output_dir: "results/survival",
    });
  });
});
