/** Analysis type */
export type AnalysisType = "binary" | "survival";

/** P-value adjustment method */
export type PAdjustMethod = "fdr" | "bonferroni" | "none";

/** Analysis execution status */
export type AnalysisStatus =
  | "idle"
  | "running"
  | "completed"
  | "failed"
  | "cancelled";

/** Evidence-based filtering config */
export interface EvidenceConfig {
  geneFile: string;
  scoreThreshold: number;
  source: string;
  diseaseName: string;
  efoId: string;
}

/** Base analysis config (shared between binary/survival) */
export interface BaseConfig {
  dataFile: string;
  sampleId: string;
  timeVariable: string | null;
  splitProp: number;
  numSeed: number;
  outputDir: string;
  freq: number;
  exclude: string[];
  include: string[];
  maxCandidatesPerStep: number | null;
  prescreenSeeds: number | null;
  topK: number | null;
  pAdjustMethod: PAdjustMethod;
  pThreshold: number;
  evidence: EvidenceConfig | null;
}

/** Binary classification config */
export interface BinaryConfig extends BaseConfig {
  type: "binary";
  outcome: string;
}

/** Survival analysis config */
export interface SurvivalConfig extends BaseConfig {
  type: "survival";
  event: string;
  horizon: number;
}

/** Union analysis config */
export type AnalysisConfig = BinaryConfig | SurvivalConfig;

/** Data file metadata */
export interface DataFileInfo {
  path: string;
  rowCount: number;
  columns: string[];
  preview: Record<string, string[]>;
}

/** TCGA preset */
export interface TcgaPreset {
  id: string;
  label: string;
  configPath: string;
  hasEvidence: boolean;
}

/** Runtime info */
export interface RuntimeInfo {
  rPath: string | null;
  pixiPath: string | null;
  rVersion: string | null;
}

/** Environment status (comprehensive check) */
export interface EnvStatus {
  pixiInstalled: boolean;
  rAvailable: boolean;
  packagesOk: boolean;
  dockerAvailable: boolean;
  dockerImagePresent: boolean;
  pixiPath: string | null;
  rPath: string | null;
  rVersion: string | null;
}

/** Execution backend */
export type ExecutionBackend = "local" | "docker";

/** Open Targets disease entry */
export interface OTDisease {
  efo_id: string;
  name: string;
  description: string;
}

/** Result from fetching Open Targets genes */
export interface FetchGenesResult {
  file_path: string;
  gene_count: number;
}

/** Filtered gene count result */
export interface FilteredCount {
  total: number;
  passed: number;
}

/** Cached evidence file entry */
export interface CachedEvidence {
  efo_id: string;
  disease_name: string;
  gene_count: number;
  fetched_at: string;
  file_path: string;
}
