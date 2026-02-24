import type { AnalysisStatus } from "./analysis";

/** Plot file info */
export interface PlotFile {
  name: string;
  tiffPath: string;
  svgPath: string;
  category:
    | "roc"
    | "importance"
    | "kaplan_meier"
    | "time_auc"
    | "dca"
    | "other";
}

/** AUC iteration result */
export interface AucIteration {
  iteration: number;
  selectedGenes: string[];
  trainAuc: number;
  testAuc: number;
}

/** Full analysis result */
export interface AnalysisResult {
  status: AnalysisStatus;
  outputDir: string;
  plots: PlotFile[];
  aucData: AucIteration[];
  duration: number;
  error: string | null;
}

/** Real-time progress event from Rust backend */
export interface ProgressEvent {
  type:
    | "start"
    | "iteration"
    | "stepwise_start"
    | "stepwise_log"
    | "stepwise_done"
    | "complete"
    | "error";
  current: number;
  total: number;
  message: string;
}
