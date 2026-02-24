import type {
  AnalysisType,
  AnalysisConfig,
  AnalysisStatus,
  DataFileInfo,
  PAdjustMethod,
  TcgaPreset,
  RuntimeInfo,
  EnvStatus,
  ExecutionBackend,
} from "@/types/analysis";
import type { AnalysisResult } from "@/types/results";

/** State and actions for the analysis Zustand store.
 *
 * This mirrors the actual AnalysisState defined in stores/analysisStore.ts.
 * Keep both in sync when adding new fields.
 */
export interface AnalysisStore {
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
  setParam: <K extends keyof AnalysisStore>(key: K, value: AnalysisStore[K]) => void;
  setStatus: (status: AnalysisStatus) => void;
  setResult: (result: AnalysisResult | null) => void;
  appendLog: (line: string) => void;
  setProgress: (current: number, total: number, message: string) => void;
  resetAll: () => void;
  buildConfig: () => Partial<AnalysisConfig>;
}

/** State and actions for the config/settings Zustand store.
 *
 * This mirrors the actual state in stores/configStore.ts.
 */
export interface ConfigStore {
  // Runtime / environment
  runtime: RuntimeInfo | null;
  rPathOverride: string;
  pixiPathOverride: string;
  envStatus: EnvStatus | null;
  envChecking: boolean;
  backend: ExecutionBackend;

  // Presets
  presets: TcgaPreset[];

  // Setup process state
  setupStatus: "idle" | "running" | "completed" | "failed";
  setupLogs: string[];
  setupStep: string;
  setupError: string;

  // Actions
  setRuntimeInfo: (info: RuntimeInfo) => void;
  setEnvStatus: (status: EnvStatus) => void;
  setEnvChecking: (checking: boolean) => void;
  setBackend: (backend: ExecutionBackend) => void;
  setPresets: (presets: TcgaPreset[]) => void;
  setSetupStatus: (status: ConfigStore["setupStatus"]) => void;
  appendSetupLog: (line: string) => void;
  setSetupStep: (step: string) => void;
  setSetupError: (error: string) => void;
  resetSetup: () => void;
}
