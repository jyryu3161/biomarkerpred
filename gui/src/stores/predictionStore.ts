import { create } from "zustand";
import type {
  ModelInfo,
  PredictionStatus,
  ColumnValidation,
  PredictionResults,
} from "@/types/prediction";
import type { DataFileInfo } from "@/types/analysis";

interface PredictionState {
  // Model
  modelPath: string;
  modelInfo: ModelInfo | null;

  // New data
  dataFile: string;
  dataInfo: DataFileInfo | null;
  columnValidation: ColumnValidation | null;

  // Execution
  status: PredictionStatus;
  outputDir: string;

  // Results
  results: PredictionResults | null;

  // Logs
  logs: string[];
  errorMessage: string;

  // Actions
  setModelPath: (path: string) => void;
  setModelInfo: (info: ModelInfo | null) => void;
  setDataFile: (path: string) => void;
  setDataInfo: (info: DataFileInfo | null) => void;
  setColumnValidation: (v: ColumnValidation | null) => void;
  setStatus: (status: PredictionStatus) => void;
  setOutputDir: (dir: string) => void;
  setResults: (results: PredictionResults | null) => void;
  appendLog: (line: string) => void;
  setErrorMessage: (msg: string) => void;
  resetAll: () => void;
}

const initialState = {
  modelPath: "",
  modelInfo: null as ModelInfo | null,
  dataFile: "",
  dataInfo: null as DataFileInfo | null,
  columnValidation: null as ColumnValidation | null,
  status: "idle" as PredictionStatus,
  outputDir: "",
  results: null as PredictionResults | null,
  logs: [] as string[],
  errorMessage: "",
};

export const usePredictionStore = create<PredictionState>()((set) => ({
  ...initialState,

  setModelPath: (path) => set({ modelPath: path }),
  setModelInfo: (info) =>
    set({ modelInfo: info, status: info ? "ready" : "idle" }),
  setDataFile: (path) => set({ dataFile: path }),
  setDataInfo: (info) => set({ dataInfo: info }),
  setColumnValidation: (v) => set({ columnValidation: v }),
  setStatus: (status) => set({ status }),
  setOutputDir: (dir) => set({ outputDir: dir }),
  setResults: (results) => set({ results }),
  appendLog: (line) => set((s) => ({ logs: [...s.logs, line] })),
  setErrorMessage: (msg) => set({ errorMessage: msg }),
  resetAll: () => set(initialState),
}));
