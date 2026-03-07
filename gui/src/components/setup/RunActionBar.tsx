import { useState } from "react";
import { useAnalysisStore } from "@/stores/analysisStore";
import {
  runAnalysis,
  cancelAnalysis,
  saveFile,
  pickFile,
  pickDirectory,
  readCsvHeader,
  checkModelExists,
  loadModel,
} from "@/lib/tauri/commands";
import { cn } from "@/lib/utils";

function RunningProgress() {
  const progress = useAnalysisStore((s) => s.progress);
  const hasProgress = progress.total > 0;
  const pct = hasProgress ? Math.round((progress.current / progress.total) * 100) : 0;

  return (
    <div className="flex items-center gap-3 flex-1 min-w-0">
      <span className="text-sm text-muted-foreground animate-pulse shrink-0">
        Running...
      </span>
      {hasProgress ? (
        <>
          <div className="flex-1 max-w-48 h-2 bg-muted rounded-full overflow-hidden">
            <div
              className="h-full bg-primary rounded-full transition-all duration-500 ease-out"
              style={{ width: `${pct}%` }}
            />
          </div>
          <span className="text-xs text-muted-foreground font-mono shrink-0">
            {progress.current}/{progress.total} ({pct}%)
          </span>
        </>
      ) : (
        <div className="flex-1 max-w-48 h-2 bg-muted rounded-full overflow-hidden">
          <div className="h-full w-1/3 bg-primary/60 rounded-full animate-[indeterminate_1.5s_ease-in-out_infinite]" />
        </div>
      )}
    </div>
  );
}

export function RunActionBar() {
  const status = useAnalysisStore((s) => s.status);
  const dataFile = useAnalysisStore((s) => s.dataFile);
  const sampleId = useAnalysisStore((s) => s.sampleId);
  const outputDir = useAnalysisStore((s) => s.outputDir);
  const analysisType = useAnalysisStore((s) => s.analysisType);
  const outcome = useAnalysisStore((s) => s.outcome);
  const event = useAnalysisStore((s) => s.event);
  const buildConfig = useAnalysisStore((s) => s.buildConfig);
  const setStatus = useAnalysisStore((s) => s.setStatus);
  const setDataFile = useAnalysisStore((s) => s.setDataFile);
  const setDataInfo = useAnalysisStore((s) => s.setDataInfo);
  const setParam = useAnalysisStore((s) => s.setParam);
  const setColumnMapping = useAnalysisStore((s) => s.setColumnMapping);
  const setAnalysisType = useAnalysisStore((s) => s.setAnalysisType);

  const isRunning = status === "running";

  const outcomeReady = analysisType === "binary" ? !!outcome : !!event;
  const canRun = !!dataFile && !!sampleId && !!outputDir && outcomeReady && !isRunning;

  const handleRun = async () => {
    try {
      // Clear previous results before starting new analysis
      setParam("errorMessage", "");
      setParam("logs", [] as string[]);
      setParam("progress", { current: 0, total: 0, message: "" });
      useAnalysisStore.getState().setResult(null);
      setStatus("running");
      const config = buildConfig();
      await runAnalysis(config);
    } catch (e) {
      const msg = typeof e === "string" ? e : String(e);
      setParam("errorMessage", msg);
      setStatus("failed");
      console.error("Analysis error:", e);
    }
  };

  const handleCancel = async () => {
    try {
      await cancelAnalysis();
      setStatus("cancelled");
    } catch (e) {
      console.error("Cancel error:", e);
    }
  };

  const [saveMsg, setSaveMsg] = useState<string | null>(null);

  const handleSave = async () => {
    if (!outputDir) {
      setSaveMsg("Set an output directory first.");
      return;
    }
    try {
      const modelPath = await checkModelExists(outputDir);
      if (!modelPath) {
        setSaveMsg("No model found. Run an analysis that produces results first.");
        return;
      }
      const dest = await saveFile(modelPath, "model.bmpmodel");
      if (dest) {
        setSaveMsg(`Saved to: ${dest}`);
      }
    } catch (e) {
      setSaveMsg(`Error: ${e}`);
    }
  };

  const handleLoad = async () => {
    try {
      const path = await pickFile();
      if (!path) return;
      const info = await loadModel(path);

      // Restore config from embedded model data
      const config = info.config as Record<string, unknown> | null;
      if (!config) {
        console.error("Model file has no embedded config");
        return;
      }

      // Determine analysis type from model
      if (info.analysis_type === "survival") {
        setAnalysisType("survival");
      } else {
        setAnalysisType("binary");
      }

      // Restore config fields from the embedded R config
      // R config structure: { workdir, binary: { data_file, sample_id, ... }, evidence: {...} }
      const section = (config.binary ?? config.survival) as Record<string, unknown> | undefined;
      if (section) {
        if (section.data_file) {
          const df = section.data_file as string;
          setDataFile(df);
          try {
            const csvInfo = await readCsvHeader(df);
            setDataInfo(csvInfo);
          } catch {
            // file may not exist at original path
          }
        }
        if (section.sample_id) setColumnMapping("sampleId", section.sample_id as string);
        if (section.split_prop) setParam("splitProp", section.split_prop as number);
        if (section.num_seed) setParam("numSeed", section.num_seed as number);
        if (section.freq) setParam("freq", section.freq as number);
        if (section.output_dir) setParam("outputDir", section.output_dir as string);

        if (info.analysis_type === "binary" && section.outcome) {
          setColumnMapping("outcome", section.outcome as string);
        }
        if (info.analysis_type === "survival") {
          if (section.event) setColumnMapping("event", section.event as string);
          if (section.horizon) setParam("horizon", section.horizon as number);
          if (section.time_variable) setColumnMapping("timeVariable", section.time_variable as string);
        }
      }
    } catch (e) {
      console.error("Load model error:", e);
    }
  };

  const missingFields: string[] = [];
  if (!dataFile) missingFields.push("Data file");
  if (!sampleId) missingFields.push("Sample ID column");
  if (!outcomeReady)
    missingFields.push(analysisType === "binary" ? "Outcome column" : "Event column");
  if (!outputDir) missingFields.push("Output directory");

  return (
    <div className="border-t border-border pt-4 flex items-center gap-3 flex-wrap">
      {/* Save / Load buttons */}
      <button
        onClick={handleSave}
        disabled={isRunning}
        className="px-4 py-2 bg-secondary text-secondary-foreground rounded-md text-sm hover:bg-secondary/80 transition-colors disabled:opacity-50"
      >
        Save Model
      </button>
      <button
        onClick={handleLoad}
        disabled={isRunning}
        className="px-4 py-2 bg-secondary text-secondary-foreground rounded-md text-sm hover:bg-secondary/80 transition-colors disabled:opacity-50"
      >
        Load Model
      </button>

      <div className="w-px h-6 bg-border" />

      {/* Run / Cancel buttons */}
      {isRunning ? (
        <button
          onClick={handleCancel}
          className="px-6 py-2 bg-destructive text-destructive-foreground rounded-md text-sm font-medium hover:bg-destructive/90 transition-colors"
        >
          Cancel
        </button>
      ) : (
        <button
          onClick={handleRun}
          disabled={!canRun}
          className={cn(
            "px-6 py-2 rounded-md text-sm font-medium transition-colors",
            canRun
              ? "bg-primary text-primary-foreground hover:bg-primary/90"
              : "bg-primary/50 text-primary-foreground/70 cursor-not-allowed",
          )}
        >
          Run Analysis
        </button>
      )}

      {status === "running" && (
        <RunningProgress />
      )}
      {status === "completed" && (
        <span className="text-sm text-green-600">Completed</span>
      )}
      {status === "failed" && (
        <div className="flex flex-col gap-1">
          <span className="text-sm text-destructive">Failed</span>
          {useAnalysisStore.getState().errorMessage && (
            <span className="text-xs text-destructive/80 max-w-md truncate">
              {useAnalysisStore.getState().errorMessage}
            </span>
          )}
        </div>
      )}
      {status === "cancelled" && (
        <span className="text-sm text-yellow-600">Cancelled</span>
      )}

      {!canRun && !isRunning && missingFields.length > 0 && (
        <span className="text-xs text-muted-foreground">
          Missing: {missingFields.join(", ")}
        </span>
      )}

      {saveMsg && (
        <span className={`text-xs w-full ${saveMsg.startsWith("Error") || saveMsg.startsWith("No ") || saveMsg.startsWith("Set ") ? "text-destructive" : "text-green-600"}`}>
          {saveMsg}
        </span>
      )}
    </div>
  );
}
