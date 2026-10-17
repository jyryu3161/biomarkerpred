export type JsonObject = Record<string, unknown>;
export type AnalysisConfig = JsonObject & { analysis_type?: string };
export type Operation =
  | "doctor"
  | "validate"
  | "analyze"
  | "predict"
  | "evaluate"
  | "runs"
  | "compare"
  | "resume"
  | "report"
  | "ora";
export interface RuntimeSettings {
  backend: "local" | "docker";
  rPath: string | null;
  dockerPath: string | null;
  dockerImage: string;
  outputRoot: string | null;
}
export interface DockerStatus {
  state:
    | "cli_missing"
    | "engine_unreachable"
    | "wrong_container_mode"
    | "image_missing"
    | "image_check_failed"
    | "ready";
  executable: string;
  image: string;
  imageId: string | null;
  serverOs: string | null;
  message: string;
  diagnostics: {
    phase: string;
    exitCode: number | null;
    stdout: string;
    stderr: string[];
    timedOut: boolean;
    error: string | null;
  }[];
}
export interface EngineRequest {
  operation: Operation;
  options?: Record<string, string | number | string[]>;
  config?: AnalysisConfig;
  settings?: RuntimeSettings;
}
export interface EngineResponse {
  success: boolean;
  cancelled: boolean;
  exitCode: number | null;
  result: JsonObject;
  verificationError: string | null;
  stderrTail: string[];
}
export interface EngineEvent {
  jobId: string;
  operation: Operation;
  type: string;
  payload: unknown;
}
export interface JobSnapshot {
  jobId: string;
  operation: Operation;
  phase: string;
  lastEvent: { type: string; payload: unknown } | null;
  response: EngineResponse | null;
}
export interface CsvTable {
  headers: string[];
  rows: Record<string, string>[];
  count: number;
}
export interface DataInfo {
  path: string;
  rowCount: number;
  columns: string[];
  preview: Record<string, string[]>;
}
export interface RunRecord {
  run_dir: string;
  manifest: JsonObject;
  artifacts: Record<string, unknown>;
  paths: Record<string, string>;
  verification_error: string | null;
  artifact_errors: Record<string, string>;
}
export interface LoadedModel {
  path: string;
  sha256: string;
  model: JsonObject;
  metrics: null;
  metrics_reason: string;
}
export interface Disease {
  efo_id: string;
  name: string;
  description: string;
}
export interface EvidenceSnapshot {
  cache_key: string;
  file_path: string;
  gene_count: number;
  provenance: JsonObject;
  efo_id?: string;
  disease_name?: string;
  fetched_at?: string;
}
export interface SchemaProperty extends JsonObject {
  default?: unknown;
  "x-survival-default"?: unknown;
  enum?: string[];
  minimum?: number;
  maximum?: number;
  exclusiveMinimum?: number;
  type?: string | string[];
}
export type Page = "setup" | "results" | "prediction" | "pathway" | "settings";
