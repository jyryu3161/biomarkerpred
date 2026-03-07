/** Loaded model metadata (from Rust model_load) */
export interface ModelInfo {
  version: string;
  created_at: string;
  analysis_type: "binary" | "survival";
  variable_count: number;
  variables: string[];
  formula: string;
  train_auc: number;
  test_auc: number;
  optimal_threshold: number | null;
  training_data_file: string;
  training_sample_count: number;
  /** Embedded analysis config for restoring setup state */
  config: Record<string, unknown> | null;
}

/** Column validation result */
export interface ColumnValidation {
  required: string[];
  present: string[];
  missing: string[];
  isValid: boolean;
}

/** Prediction execution status */
export type PredictionStatus =
  | "idle"
  | "loading_model"
  | "ready"
  | "running"
  | "completed"
  | "failed";

/** Prediction results data from CSV */
export interface PredictionResults {
  headers: string[];
  rows: Record<string, unknown>[];
  count: number;
}
