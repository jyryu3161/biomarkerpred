import { useState } from "react";
import { api } from "@/lib/api";
import { errorText, number, object, responseError, text } from "@/lib/value";
import { usePrediction } from "@/stores/prediction";
import { startJob, useJob } from "@/stores/job";
import { openRun, useWorkspace } from "@/stores/workspace";
import {
  Field,
  FileActions,
  Notice,
  PathField,
  Section,
} from "@/components/Common";
import { ModelDetails, SavedCsv } from "@/components/Artifacts";
import { QcView } from "@/components/QcView";
export function PredictionPage() {
  const state = usePrediction();
  const { settings, doctor } = useWorkspace();
  const busy = useJob((s) => s.busy);
  const [error, setError] = useState("");
  const [loading, setLoading] = useState(false);
  const patch = usePrediction.setState;
  const model = state.model?.model;
  const survival = model?.analysis_type === "survival";
  const load = async () => {
    setLoading(true);
    setError("");
    const path = state.modelPath;
    try {
      const loaded = await api.model(path);
      if (usePrediction.getState().modelPath === path)
        patch({ model: loaded, timeUnit: text(loaded.model.time_unit, "") });
    } catch (e) {
      setError(errorText(e));
    } finally {
      setLoading(false);
    }
  };
  const start = async () => {
    setError("");
    try {
      if (!state.model)
        throw new Error("Load and validate the selected frozen model first.");
      const options: Record<string, string | number> = {
        model: state.model.path,
        data: state.dataPath,
        output: state.output,
      };
      if (survival) options["time-unit"] = state.timeUnit;
      if (state.operation === "evaluate") {
        if (state.bootstrap === null || state.seed === null)
          throw new Error("Provide evaluation bootstrap and seed values.");
        options["bootstrap-samples"] = state.bootstrap;
        options.seed = state.seed;
      }
      patch({ result: null });
      await startJob({
        operation: state.operation,
        options,
        ...(settings ? { settings } : {}),
      });
    } catch (e) {
      setError(errorText(e));
    }
  };
  const result = state.result,
    predictions = text(object(result?.result.paths).predictions, "");
  return (
    <div className="stack">
      <header>
        <p className="eyebrow">FROZEN MODEL</p>
        <h1>Prediction & external evaluation</h1>
        <p>
          Apply saved encoders, coefficients, outcome coding and thresholds to a
          new cohort. Evaluation adds outcome-based performance and drift
          diagnostics without fitting.
        </p>
      </header>
      <Section title="Load a frozen model">
        <PathField
          label="Model file"
          value={state.modelPath}
          onChange={(modelPath) =>
            patch({ modelPath, model: null, result: null })
          }
        />
        <button
          disabled={loading || !state.modelPath}
          onClick={() => void load()}
        >
          {loading ? "Loading model…" : "Load model"}
        </button>
        {error && <Notice tone="error">{error}</Notice>}
        {state.model && <ModelDetails loaded={state.model} />}
      </Section>
      <Section title="Score a new cohort">
        <div className="form-grid">
          <Field label="Scoring operation">
            <select
              value={state.operation}
              onChange={(e) =>
                patch({
                  operation: e.target.value as "predict" | "evaluate",
                  result: null,
                })
              }
            >
              <option value="predict">
                Prediction only (outcomes not required)
              </option>
              <option value="evaluate">
                External evaluation (outcomes required)
              </option>
            </select>
          </Field>
          <PathField
            label="New cohort CSV"
            value={state.dataPath}
            onChange={(dataPath) => patch({ dataPath, result: null })}
          />
        </div>
        <PathField
          label="Prediction / evaluation output"
          value={state.output}
          directory
          onChange={(output) => patch({ output })}
          hint={
            state.operation === "predict"
              ? "A destination folder or CSV path. Predictions are written to the engine-reported path."
              : "An output root; evaluation creates its own runs/RUN_ID directory."
          }
        />
        {survival && (
          <Field
            label="External data time unit"
            hint="Declare the actual input unit. The engine rejects mismatches with the frozen model; no implicit unit conversion."
          >
            <select
              value={state.timeUnit}
              onChange={(e) => patch({ timeUnit: e.target.value })}
            >
              <option value="">Select unit</option>
              {["days", "months", "years"].map((unit) => (
                <option key={unit}>{unit}</option>
              ))}
            </select>
          </Field>
        )}
        {state.operation === "evaluate" && (
          <>
            <div className="form-grid">
              <Field label="Evaluation bootstrap samples">
                <input
                  type="number"
                  min="0"
                  step="1"
                  value={state.bootstrap ?? ""}
                  onChange={(e) => patch({ bootstrap: number(e.target.value) })}
                />
              </Field>
              <Field label="Evaluation seed">
                <input
                  type="number"
                  min="0"
                  step="1"
                  value={state.seed ?? ""}
                  onChange={(e) => patch({ seed: number(e.target.value) })}
                />
              </Field>
            </div>
            <p>
              Required outcomes:{" "}
              {survival
                ? `${text(object(model?.outcome).event)} (0 / 1) and ${text(object(model?.outcome).time_variable)} (${text(model?.time_unit)})`
                : text(object(model?.outcome).column)}
              . Class coding and evaluation horizon come from the frozen model.
            </p>
          </>
        )}
        <button
          className="primary"
          disabled={
            busy ||
            !doctor?.success ||
            !state.model ||
            !state.dataPath ||
            !state.output ||
            (survival && !state.timeUnit)
          }
          onClick={() => void start()}
        >
          {state.operation === "predict"
            ? "Run prediction"
            : "Run external evaluation"}
        </button>
      </Section>
      {result && (
        <Section title="Recorded scoring result">
          <Notice
            tone={
              result.cancelled
                ? "warning"
                : result.success
                  ? "success"
                  : "error"
            }
          >
            {result.cancelled
              ? "Request cancelled; inspect retained output separately."
              : result.success
                ? "Engine verified scoring output."
                : responseError(result)}
          </Notice>
          <QcView value={result.result.qc} />
          {text(result.result.run_dir, "") && (
            <>
              <code className="path">{text(result.result.run_dir)}</code>
              <button
                onClick={() =>
                  void openRun(text(result.result.run_dir), "results")
                }
              >
                Open evaluation metrics and drift
              </button>
            </>
          )}
          {predictions && (
            <SavedCsv
              key={predictions}
              path={predictions}
              title="prediction results"
            />
          )}
          <FileActions
            path={text(object(result.result.paths).report_html, "")}
            name="scoring HTML report"
          />
        </Section>
      )}
    </div>
  );
}
