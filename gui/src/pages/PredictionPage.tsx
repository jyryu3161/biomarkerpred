import { useState, useEffect, useRef } from "react";
import { usePredictionStore } from "@/stores/predictionStore";
import { useConfigStore } from "@/stores/configStore";
import {
  pickFile,
  pickDirectory,
  readCsvHeader,
  loadModel,
  runPrediction,
  cancelPrediction,
  saveFile,
} from "@/lib/tauri/commands";
import type { ColumnValidation } from "@/types/prediction";

function ModelSection() {
  const modelPath = usePredictionStore((s) => s.modelPath);
  const modelInfo = usePredictionStore((s) => s.modelInfo);
  const setModelPath = usePredictionStore((s) => s.setModelPath);
  const setModelInfo = usePredictionStore((s) => s.setModelInfo);
  const setErrorMessage = usePredictionStore((s) => s.setErrorMessage);
  const [loading, setLoading] = useState(false);

  const handlePickModel = async () => {
    const path = await pickFile();
    if (!path) return;

    setLoading(true);
    setErrorMessage("");
    try {
      const info = await loadModel(path);
      setModelPath(path);
      setModelInfo(info);
    } catch (e) {
      setErrorMessage(`Failed to load model: ${e}`);
      setModelInfo(null);
    } finally {
      setLoading(false);
    }
  };

  return (
    <div className="border border-border rounded-lg p-4">
      <h3 className="text-sm font-medium mb-3">Step 1: Load Model</h3>
      <button
        onClick={handlePickModel}
        disabled={loading}
        className="px-4 py-2 text-sm rounded-md border border-border hover:bg-accent transition-colors"
      >
        {loading ? "Loading..." : "Select Model File (.bmpmodel)"}
      </button>

      {modelPath && (
        <p className="text-xs text-muted-foreground mt-2 truncate" title={modelPath}>
          {modelPath}
        </p>
      )}

      {modelInfo && (
        <div className="mt-3 p-3 bg-muted/30 rounded-md space-y-1 text-sm">
          <div className="flex justify-between">
            <span className="text-muted-foreground">Type</span>
            <span className="font-medium capitalize">
              {modelInfo.analysis_type === "binary"
                ? "Binary Classification"
                : "Survival Analysis"}
            </span>
          </div>
          <div className="flex justify-between">
            <span className="text-muted-foreground">Variables</span>
            <span className="font-medium">{modelInfo.variable_count}</span>
          </div>
          <div className="flex justify-between">
            <span className="text-muted-foreground">Train AUC / Test AUC</span>
            <span className="font-medium">
              {modelInfo.train_auc.toFixed(3)} / {modelInfo.test_auc.toFixed(3)}
            </span>
          </div>
          {modelInfo.optimal_threshold != null && (
            <div className="flex justify-between">
              <span className="text-muted-foreground">Threshold</span>
              <span className="font-medium">
                {modelInfo.optimal_threshold.toFixed(4)}
              </span>
            </div>
          )}
          <div className="flex justify-between">
            <span className="text-muted-foreground">Training Data</span>
            <span className="font-medium">
              {modelInfo.training_data_file} ({modelInfo.training_sample_count} samples)
            </span>
          </div>
          <div className="flex justify-between">
            <span className="text-muted-foreground">Created</span>
            <span className="font-medium">
              {modelInfo.created_at
                ? new Date(modelInfo.created_at).toLocaleDateString()
                : "Unknown"}
            </span>
          </div>
          <div className="pt-2">
            <p className="text-xs text-muted-foreground">
              Variables: {modelInfo.variables.join(", ")}
            </p>
          </div>
        </div>
      )}
    </div>
  );
}

function DataSection() {
  const modelInfo = usePredictionStore((s) => s.modelInfo);
  const dataFile = usePredictionStore((s) => s.dataFile);
  const dataInfo = usePredictionStore((s) => s.dataInfo);
  const columnValidation = usePredictionStore((s) => s.columnValidation);
  const setDataFile = usePredictionStore((s) => s.setDataFile);
  const setDataInfo = usePredictionStore((s) => s.setDataInfo);
  const setColumnValidation = usePredictionStore((s) => s.setColumnValidation);

  const handlePickData = async () => {
    const path = await pickFile();
    if (!path) return;

    try {
      const info = await readCsvHeader(path);
      setDataFile(path);
      setDataInfo(info);

      // Validate columns against model
      if (modelInfo) {
        const required = modelInfo.variables;
        const present = required.filter((v) => info.columns.includes(v));
        const missing = required.filter((v) => !info.columns.includes(v));
        const validation: ColumnValidation = {
          required,
          present,
          missing,
          isValid: missing.length === 0,
        };
        setColumnValidation(validation);
      }
    } catch (e) {
      console.error("Failed to read CSV:", e);
    }
  };

  if (!modelInfo) {
    return (
      <div className="border border-border rounded-lg p-4 opacity-50">
        <h3 className="text-sm font-medium mb-2">Step 2: New Patient Data</h3>
        <p className="text-xs text-muted-foreground">Load a model first</p>
      </div>
    );
  }

  return (
    <div className="border border-border rounded-lg p-4">
      <h3 className="text-sm font-medium mb-3">Step 2: New Patient Data</h3>
      <button
        onClick={handlePickData}
        className="px-4 py-2 text-sm rounded-md border border-border hover:bg-accent transition-colors"
      >
        Select CSV File
      </button>

      {dataFile && (
        <p className="text-xs text-muted-foreground mt-2 truncate" title={dataFile}>
          {dataFile}
        </p>
      )}

      {dataInfo && (
        <p className="text-xs text-muted-foreground mt-1">
          {dataInfo.rowCount} rows, {dataInfo.columns.length} columns
        </p>
      )}

      {columnValidation && (
        <div className="mt-3 flex flex-wrap gap-1.5">
          {columnValidation.required.map((v) => (
            <span
              key={v}
              className={`inline-flex items-center gap-1 px-2 py-0.5 rounded text-xs ${
                columnValidation.present.includes(v)
                  ? "bg-green-500/10 text-green-700 dark:text-green-400"
                  : "bg-red-500/10 text-red-700 dark:text-red-400"
              }`}
            >
              {columnValidation.present.includes(v) ? "\u2713" : "\u2717"} {v}
            </span>
          ))}
        </div>
      )}

      {columnValidation && !columnValidation.isValid && (
        <p className="text-xs text-destructive mt-2">
          Missing {columnValidation.missing.length} required variable(s). Prediction cannot proceed.
        </p>
      )}
    </div>
  );
}

function RunSection() {
  const modelPath = usePredictionStore((s) => s.modelPath);
  const modelInfo = usePredictionStore((s) => s.modelInfo);
  const dataFile = usePredictionStore((s) => s.dataFile);
  const columnValidation = usePredictionStore((s) => s.columnValidation);
  const status = usePredictionStore((s) => s.status);
  const setStatus = usePredictionStore((s) => s.setStatus);
  const setOutputDir = usePredictionStore((s) => s.setOutputDir);
  const setResults = usePredictionStore((s) => s.setResults);
  const setErrorMessage = usePredictionStore((s) => s.setErrorMessage);
  const backend = useConfigStore((s) => s.backend);

  const canRun =
    modelInfo &&
    dataFile &&
    columnValidation?.isValid &&
    status !== "running";

  const handleRun = async () => {
    if (!canRun) return;

    // Use a temp output dir next to the data file
    const dataDir = dataFile.replace(/[/\\][^/\\]+$/, "");
    const outputDir = `${dataDir}/prediction_output`;

    setOutputDir(outputDir);
    setResults(null);
    setErrorMessage("");
    setStatus("running");
    usePredictionStore.setState({ logs: [] });

    try {
      await runPrediction(modelPath, dataFile, outputDir, backend);
    } catch (e) {
      setErrorMessage(`Failed to start prediction: ${e}`);
      setStatus("failed");
    }
  };

  const handleCancel = async () => {
    try {
      await cancelPrediction();
      setStatus("idle");
    } catch (e) {
      console.error("Cancel failed:", e);
    }
  };

  return (
    <div className="flex items-center gap-3">
      <button
        onClick={handleRun}
        disabled={!canRun}
        className="px-6 py-2 text-sm rounded-md bg-primary text-primary-foreground hover:bg-primary/90 disabled:opacity-50 disabled:cursor-not-allowed transition-colors"
      >
        {status === "running" ? "Running..." : "Run Prediction"}
      </button>
      {status === "running" && (
        <button
          onClick={handleCancel}
          className="px-4 py-2 text-sm rounded-md border border-destructive text-destructive hover:bg-destructive/10 transition-colors"
        >
          Cancel
        </button>
      )}
    </div>
  );
}

function ResultsSection() {
  const results = usePredictionStore((s) => s.results);
  const status = usePredictionStore((s) => s.status);
  const outputDir = usePredictionStore((s) => s.outputDir);
  const modelInfo = usePredictionStore((s) => s.modelInfo);
  const [saving, setSaving] = useState(false);

  if (status !== "completed" || !results || results.rows.length === 0) {
    return null;
  }

  const isBinary = modelInfo?.analysis_type === "binary";
  const highCount = results.rows.filter(
    (r) => r.risk_group === "High",
  ).length;
  const lowCount = results.rows.filter((r) => r.risk_group === "Low").length;

  const handleExport = async () => {
    const sourcePath = `${outputDir}/prediction_results.csv`;
    setSaving(true);
    try {
      await saveFile(sourcePath, "prediction_results.csv");
    } catch (e) {
      console.error("Export failed:", e);
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="border border-border rounded-lg p-4">
      <div className="flex items-center justify-between mb-3">
        <h3 className="text-sm font-medium">
          Results ({results.count} patients)
        </h3>
        <div className="flex items-center gap-3">
          <span className="text-xs text-muted-foreground">
            {highCount} High / {lowCount} Low
          </span>
          <button
            onClick={handleExport}
            disabled={saving}
            className="px-3 py-1.5 text-xs rounded-md border border-border hover:bg-accent transition-colors"
          >
            {saving ? "Saving..." : "Export CSV"}
          </button>
        </div>
      </div>

      <div className="overflow-auto max-h-[400px] border border-border rounded">
        <table className="w-full text-xs">
          <thead className="bg-muted sticky top-0 z-10">
            <tr>
              {results.headers.map((h) => (
                <th
                  key={h}
                  className="px-3 py-2 text-left font-medium text-muted-foreground whitespace-nowrap border-b border-border"
                >
                  {h}
                </th>
              ))}
            </tr>
          </thead>
          <tbody className="divide-y divide-border">
            {results.rows.map((row, i) => (
              <tr key={i} className="hover:bg-muted/30">
                {results.headers.map((h) => (
                  <td key={h} className="px-3 py-1.5 whitespace-nowrap">
                    {h === "risk_group" ? (
                      <span
                        className={`inline-block px-1.5 py-0.5 rounded text-xs font-medium ${
                          row[h] === "High"
                            ? "bg-red-500/10 text-red-700 dark:text-red-400"
                            : "bg-green-500/10 text-green-700 dark:text-green-400"
                        }`}
                      >
                        {String(row[h])}
                      </span>
                    ) : typeof row[h] === "number" ? (
                      (row[h] as number) % 1 === 0
                        ? String(row[h])
                        : (row[h] as number).toFixed(4)
                    ) : (
                      String(row[h] ?? "")
                    )}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      {isBinary && (
        <p className="text-xs text-muted-foreground mt-2">
          Threshold: {modelInfo?.optimal_threshold?.toFixed(4) ?? "0.5"} |
          Probability &ge; threshold = High (predicted class 1)
        </p>
      )}
    </div>
  );
}

function LogSection() {
  const logs = usePredictionStore((s) => s.logs);
  const status = usePredictionStore((s) => s.status);
  const errorMessage = usePredictionStore((s) => s.errorMessage);
  const logEndRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    logEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [logs.length]);

  if (status === "idle" && logs.length === 0 && !errorMessage) {
    return null;
  }

  return (
    <div className="border border-border rounded-lg p-4">
      <h3 className="text-sm font-medium mb-2">Log</h3>
      {errorMessage && (
        <p className="text-xs text-destructive mb-2">{errorMessage}</p>
      )}
      <div className="bg-muted/30 rounded p-3 h-32 overflow-y-auto font-mono text-xs space-y-0.5">
        {logs.length === 0 ? (
          <p className="text-muted-foreground">No log output yet.</p>
        ) : (
          logs.map((line, i) => (
            <div key={i} className="text-muted-foreground whitespace-pre-wrap">
              {line}
            </div>
          ))
        )}
        <div ref={logEndRef} />
      </div>
    </div>
  );
}

export function PredictionPage() {
  return (
    <div className="flex-1 overflow-y-auto p-6 space-y-6">
      <h2 className="text-lg font-semibold">Prediction</h2>
      <p className="text-sm text-muted-foreground -mt-4">
        Load a trained model and predict outcomes for new patients.
      </p>

      <ModelSection />
      <DataSection />
      <RunSection />
      <ResultsSection />
      <LogSection />
    </div>
  );
}
