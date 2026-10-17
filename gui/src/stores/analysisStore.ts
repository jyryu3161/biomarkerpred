import { create } from "zustand";
import type {
  AnalysisType,
  AnalysisConfig,
  AnalysisStatus,
  DataFileInfo,
  PAdjustMethod,
} from "@/types/analysis";
import { useConfigStore } from "@/stores/configStore";
import type { AnalysisResult } from "@/types/results";

interface AnalysisState {
  // Core state
  analysisType: AnalysisType;
  dataFile: string;
  dataInfo: DataFileInfo | null;
  status: AnalysisStatus;
  result: AnalysisResult | null;

  // Column mapping
  sampleId: string;
  outcome: string;
  event: string;
  timeVariable: string;

  // Parameters
  splitProp: number;
  numSeed: number;
  freq: number;
  horizon: number;
  outputDir: string;

  // Advanced
  enablePValueFilter: boolean;
  pAdjustMethod: PAdjustMethod;
  pThreshold: number;
  topK: number | null;
  maxCandidatesPerStep: number | null;
  prescreenSeeds: number | null;

  // Feature selection
  includeFeatures: string[];
  excludeFeatures: string[];

  // Evidence
  enableEvidence: boolean;
  evidenceGeneFile: string;
  evidenceScoreThreshold: number;
  selectedDiseaseId: string;
  selectedDiseaseName: string;
  fetchedGeneCount: number | null;
  isFetchingGenes: boolean;

  // Progress
  progress: { current: number; total: number; message: string };
  logs: string[];
  errorMessage: string;

  // Actions
  setAnalysisType: (type: AnalysisType) => void;
  setDataFile: (path: string) => void;
  setDataInfo: (info: DataFileInfo | null) => void;
  setColumnMapping: (field: string, value: string) => void;
  setParam: <K extends keyof AnalysisState>(key: K, value: AnalysisState[K]) => void;
  setStatus: (status: AnalysisStatus) => void;
  setResult: (result: AnalysisResult | null) => void;
  appendLog: (line: string) => void;
  setProgress: (current: number, total: number, message: string) => void;
  resetAll: () => void;
  buildConfig: () => Partial<AnalysisConfig>;
}

const initialState = {
  analysisType: "binary" as AnalysisType,
  dataFile: "",
  dataInfo: null as DataFileInfo | null,
  status: "idle" as AnalysisStatus,
  result: null as AnalysisResult | null,
  sampleId: "",
  outcome: "",
  event: "",
  timeVariable: "",
  splitProp: 0.7,
  numSeed: 10,
  freq: 5,
  horizon: 5,
  outputDir: "",
  enablePValueFilter: true,
  pAdjustMethod: "none" as PAdjustMethod,
  pThreshold: 0.05,
  topK: 100 as number | null,
  maxCandidatesPerStep: null as number | null,
  prescreenSeeds: null as number | null,
  includeFeatures: [] as string[],
  excludeFeatures: [] as string[],
  enableEvidence: false,
  evidenceGeneFile: "",
  evidenceScoreThreshold: 0.5,
  selectedDiseaseId: "",
  selectedDiseaseName: "",
  fetchedGeneCount: null as number | null,
  isFetchingGenes: false,
  progress: { current: 0, total: 0, message: "" },
  logs: [] as string[],
  errorMessage: "",
};

export const useAnalysisStore = create<AnalysisState>()((set, get) => ({
  ...initialState,

  setAnalysisType: (type) => set({ analysisType: type }),
  setDataFile: (path) => set({ dataFile: path }),
  setDataInfo: (info) => set({ dataInfo: info }),
  setColumnMapping: (field, value) => set({ [field]: value }),
  setParam: (key, value) => set({ [key]: value } as Partial<AnalysisState>),
  setStatus: (status) => set({ status }),
  setResult: (result) => set({ result }),
  appendLog: (line) => set((s) => ({ logs: [...s.logs, line] })),
  setProgress: (current, total, message) =>
    set({ progress: { current, total, message } }),

  resetAll: () => set(initialState),

  buildConfig: () => {
    const s = get();
    const base = {
      dataFile: s.dataFile,
      sampleId: s.sampleId,
      timeVariable: s.timeVariable || null,
      splitProp: s.splitProp,
      numSeed: s.numSeed,
      outputDir: s.outputDir,
      freq: s.freq,
      exclude: s.excludeFeatures,
      include: s.includeFeatures,
      maxCandidatesPerStep: s.maxCandidatesPerStep,
      prescreenSeeds: s.prescreenSeeds,
      topK: s.enablePValueFilter ? s.topK : null,
      pAdjustMethod: s.enablePValueFilter ? s.pAdjustMethod : "none",
      pThreshold: s.enablePValueFilter ? s.pThreshold : 1.0,
      evidence: s.enableEvidence
        ? {
            geneFile: s.evidenceGeneFile,
            scoreThreshold: s.evidenceScoreThreshold,
            source: "Open Targets Platform",
            diseaseName: s.selectedDiseaseName,
            efoId: s.selectedDiseaseId,
          }
        : null,
    };

    const backend = useConfigStore.getState().backend;

    if (s.analysisType === "binary") {
      return { ...base, type: "binary" as const, outcome: s.outcome, backend };
    }
    return {
      ...base,
      type: "survival" as const,
      event: s.event,
      horizon: s.horizon,
      backend,
    };
  },
}));
