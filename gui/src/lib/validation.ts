import type { AnalysisType } from "@/types/analysis";

/** Result returned by validateConfig */
export interface ValidationResult {
  valid: boolean;
  errors: Record<string, string>;
}

/** Fields required to run an analysis */
export interface ConfigFields {
  analysisType: AnalysisType;
  dataFile: string;
  sampleId: string;
  outcome: string;   // binary analysis
  event: string;     // survival analysis
  splitProp: number;
  numSeed: number;
  freq: number;
  horizon: number;   // survival analysis
  outputDir: string;
}

/**
 * Validate analysis configuration fields on the frontend.
 *
 * Rules follow design Section 6.3.  Returns a record of field-level error
 * messages (empty when valid) so the UI can highlight individual fields.
 *
 * NOTE: File-system checks (file existence, write permission) are performed
 * by the Rust backend via `config_validate`.  This function validates only
 * the values that can be checked without disk access.
 */
export function validateConfig(fields: ConfigFields): ValidationResult {
  const errors: Record<string, string> = {};

  // dataFile: required, must look like a .csv path
  if (!fields.dataFile) {
    errors.dataFile = "Please select a CSV data file.";
  } else if (!fields.dataFile.toLowerCase().endsWith(".csv")) {
    errors.dataFile = "Please select a valid CSV file (.csv extension).";
  }

  // sampleId: required
  if (!fields.sampleId) {
    errors.sampleId = "Please select a Sample ID column.";
  }

  // outcome / event: required depending on analysis type
  if (fields.analysisType === "binary") {
    if (!fields.outcome) {
      errors.outcome = "Please select an Outcome column.";
    }
  } else {
    if (!fields.event) {
      errors.event = "Please select an Event column.";
    }
  }

  // splitProp: 0.5 <= x <= 0.9
  if (fields.splitProp < 0.5 || fields.splitProp > 0.9) {
    errors.splitProp = "Train/test split ratio must be between 0.5 and 0.9.";
  }

  // numSeed: integer, 10 <= x <= 1000
  if (!Number.isInteger(fields.numSeed) || fields.numSeed < 10 || fields.numSeed > 1000) {
    errors.numSeed = "Number of iterations must be an integer between 10 and 1000.";
  }

  // freq: integer, 1 <= x <= 100
  if (!Number.isInteger(fields.freq) || fields.freq < 1 || fields.freq > 100) {
    errors.freq = "Frequency threshold must be an integer between 1 and 100.";
  }

  // horizon: 1 <= x <= 20 (survival only)
  if (fields.analysisType === "survival") {
    if (fields.horizon < 1 || fields.horizon > 20) {
      errors.horizon = "Evaluation horizon must be between 1 and 20 years.";
    }
  }

  // outputDir: required
  if (!fields.outputDir) {
    errors.outputDir = "Please select an output directory.";
  }

  return {
    valid: Object.keys(errors).length === 0,
    errors,
  };
}
