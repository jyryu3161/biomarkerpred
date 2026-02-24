import { describe, it, expect, beforeEach } from "vitest";
import { useAnalysisStore } from "@/stores/analysisStore";

describe("buildConfig", () => {
  beforeEach(() => {
    useAnalysisStore.getState().resetAll();
  });

  it("builds a binary config with correct type", () => {
    const store = useAnalysisStore.getState();
    store.setAnalysisType("binary");
    store.setDataFile("/data/test.csv");
    store.setColumnMapping("sampleId", "sample_id");
    store.setColumnMapping("outcome", "status");
    store.setParam("outputDir", "/output");
    store.setParam("splitProp", 0.7);
    store.setParam("numSeed", 100);

    const config = useAnalysisStore.getState().buildConfig();
    expect(config.type).toBe("binary");
    expect(config.dataFile).toBe("/data/test.csv");
    expect(config.sampleId).toBe("sample_id");
    expect(config.splitProp).toBe(0.7);
    expect(config.numSeed).toBe(100);
    expect(config.outputDir).toBe("/output");
    expect((config as { outcome?: string }).outcome).toBe("status");
  });

  it("builds a survival config with event and horizon", () => {
    const store = useAnalysisStore.getState();
    store.setAnalysisType("survival");
    store.setDataFile("/data/surv.csv");
    store.setColumnMapping("sampleId", "patient_id");
    store.setColumnMapping("event", "death");
    store.setParam("horizon", 5);
    store.setParam("outputDir", "/output");

    const config = useAnalysisStore.getState().buildConfig();
    expect(config.type).toBe("survival");
    expect((config as { event?: string }).event).toBe("death");
    expect((config as { horizon?: number }).horizon).toBe(5);
    expect(config).not.toHaveProperty("outcome");
  });

  it("includes evidence config when enabled", () => {
    const store = useAnalysisStore.getState();
    store.setAnalysisType("binary");
    store.setParam("enableEvidence", true);
    store.setParam("evidenceGeneFile", "/genes.csv");
    store.setParam("evidenceScoreThreshold", 0.5);
    store.setColumnMapping("outcome", "status");

    const config = useAnalysisStore.getState().buildConfig();
    expect(config.evidence).toBeTruthy();
    expect(config.evidence?.geneFile).toBe("/genes.csv");
    expect(config.evidence?.scoreThreshold).toBe(0.5);
  });

  it("excludes evidence config when disabled", () => {
    const store = useAnalysisStore.getState();
    store.setAnalysisType("binary");
    store.setParam("enableEvidence", false);
    store.setColumnMapping("outcome", "status");

    const config = useAnalysisStore.getState().buildConfig();
    expect(config.evidence).toBeNull();
  });

  it("includes feature lists", () => {
    const store = useAnalysisStore.getState();
    store.setAnalysisType("binary");
    store.setParam("includeFeatures", ["BRCA1", "TP53"]);
    store.setParam("excludeFeatures", ["GENE_X"]);
    store.setColumnMapping("outcome", "status");

    const config = useAnalysisStore.getState().buildConfig();
    expect(config.include).toEqual(["BRCA1", "TP53"]);
    expect(config.exclude).toEqual(["GENE_X"]);
  });

  it("handles p-value filter with topK", () => {
    const store = useAnalysisStore.getState();
    store.setAnalysisType("binary");
    store.setParam("enablePValueFilter", true);
    store.setParam("topK", 50);
    store.setColumnMapping("outcome", "status");

    const config = useAnalysisStore.getState().buildConfig();
    expect(config.topK).toBe(50);
  });

  it("excludes topK when p-value filter disabled", () => {
    const store = useAnalysisStore.getState();
    store.setAnalysisType("binary");
    store.setParam("enablePValueFilter", false);
    store.setParam("topK", 50);
    store.setColumnMapping("outcome", "status");

    const config = useAnalysisStore.getState().buildConfig();
    expect(config.topK).toBeNull();
  });

  it("resetAll returns to initial state", () => {
    const store = useAnalysisStore.getState();
    store.setDataFile("/test.csv");
    store.setParam("splitProp", 0.8);
    store.setParam("numSeed", 50);

    store.resetAll();
    const state = useAnalysisStore.getState();
    expect(state.dataFile).toBe("");
    expect(state.splitProp).toBe(0.7);
    expect(state.numSeed).toBe(10);
    expect(state.status).toBe("idle");
  });
});
