import { useState } from "react";
import { api } from "@/lib/api";
import {
  errorText,
  label,
  number,
  object,
  properties,
  strings,
  text,
} from "@/lib/value";
import {
  changeAnalysisType,
  inspectData,
  updateConfig,
  useWorkspace,
  validateConfiguration,
} from "@/stores/workspace";
import { startJob, useJob } from "@/stores/job";
import {
  ColumnChoice,
  ColumnMultiSelect,
  DataTable,
  Field,
  JsonDetails,
  Notice,
  PathField,
  Section,
} from "@/components/Common";
import { QcView } from "@/components/QcView";
import { EvidencePicker } from "@/components/EvidencePicker";
const numericFields = [
  "outer_folds",
  "inner_folds",
  "repeats",
  "seed",
  "workers",
  "max_features",
  "max_candidates_per_step",
  "bootstrap_samples",
  "selection_frequency",
  "missing_threshold",
  "p_threshold",
  "top_k",
];
const names: Record<string, string> = {
  outer_folds: "Outer folds",
  inner_folds: "Inner folds",
  max_features: "Maximum genes",
  max_candidates_per_step: "Bootstrap candidate pool",
  bootstrap_samples: "Bootstrap samples",
  selection_frequency: "Selection frequency",
  missing_threshold: "Maximum missing fraction",
  p_threshold: "Adjusted p-value threshold",
  top_k: "Top-ranked gene limit (optional)",
};
export function SetupPage() {
  const {
    config,
    schema,
    dataInfo,
    doctor,
    settings,
    validating,
    validation,
    validatedConfig,
    validationError,
  } = useWorkspace();
  const busy = useJob((s) => s.busy);
  const [error, setError] = useState("");
  const [savePath, setSavePath] = useState("");
  const [arrayDraft, setArrayDraft] = useState<Record<string, string>>({});
  if (!schema)
    return (
      <Notice tone="warning">
        The installed configuration schema has not loaded. Check desktop
        availability and Settings.
      </Notice>
    );
  const props = properties(schema);
  const columns = dataInfo?.columns ?? [];
  const survival = config.analysis_type === "survival";
  const act = async (fn: () => Promise<unknown>) => {
    setError("");
    try {
      await fn();
    } catch (e) {
      setError(errorText(e));
    }
  };
  const setArray = (key: string, raw: string) => {
    setArrayDraft((previous) => ({ ...previous, [key]: raw }));
    const parts = raw.split(/[\s,]+/).filter(Boolean);
    updateConfig({ [key]: parts.map((value) => number(value) ?? value) });
  };
  const run = async () => {
    const state = useWorkspace.getState();
    if (
      !state.validatedConfig ||
      !state.validation?.success ||
      !state.doctor?.success
    )
      throw new Error(
        "Run QC with the current configuration and a ready runtime first.",
      );
    await startJob({
      operation: "analyze",
      config: structuredClone(state.validatedConfig),
      ...(state.settings ? { settings: state.settings } : {}),
    });
  };
  return (
    <div className="stack">
      <header>
        <p className="eyebrow">DEVELOPMENT</p>
        <h1>Analysis setup</h1>
        <p>
          Define the cohort and candidate models, validate the data, then
          estimate performance with nested patient-group validation.
        </p>
      </header>
      {error && <Notice tone="error">{error}</Notice>}
      <Section title="Data and configuration">
        <div className="row">
          <button
            disabled={validating}
            onClick={() =>
              void act(async () => {
                const path = await api.pickFile();
                if (path) {
                  setArrayDraft({});
                  await validateConfiguration(path);
                }
              })
            }
          >
            Import configuration
          </button>
          <details>
            <summary>Save current configuration</summary>
            <Field label="Configuration save path">
              <input
                placeholder="/path/analysis.yaml"
                value={savePath}
                onChange={(e) => setSavePath(e.target.value)}
              />
            </Field>
            <button
              disabled={!savePath}
              onClick={() => void act(() => api.saveConfig(config, savePath))}
            >
              Save YAML
            </button>
          </details>
        </div>
        <div className="form-grid">
          <Field label="Analysis type">
            <select
              value={text(config.analysis_type, "binary")}
              onChange={(e) => {
                changeAnalysisType(e.target.value);
                setArrayDraft({});
              }}
            >
              <option value="binary">Binary outcome</option>
              <option value="survival">Time-to-event / survival</option>
            </select>
          </Field>
          <PathField
            label="Data CSV"
            value={text(config.data_file, "")}
            onChange={(data_file) => updateConfig({ data_file })}
          />
        </div>
        <button
          disabled={!config.data_file}
          onClick={() => void act(() => inspectData(text(config.data_file)))}
        >
          Read CSV columns
        </button>
        {dataInfo && (
          <p className="muted">
            {dataInfo.rowCount.toLocaleString()} rows ·{" "}
            {columns.length.toLocaleString()} exact column names. Identifier
            strings are preserved.
          </p>
        )}
        {dataInfo && (
          <details>
            <summary>CSV preview (first rows and up to 12 columns)</summary>
            <DataTable
              title="CSV preview"
              columns={columns.slice(0, 12)}
              data={Array.from(
                {
                  length: Math.min(
                    5,
                    dataInfo.rowCount,
                    ...columns
                      .slice(0, 12)
                      .map((column) => dataInfo.preview[column]?.length ?? 0),
                  ),
                },
                (_, row) =>
                  Object.fromEntries(
                    columns
                      .slice(0, 12)
                      .map((column) => [
                        column,
                        dataInfo.preview[column]?.[row] ?? "",
                      ]),
                  ),
              )}
            />
          </details>
        )}
        <PathField
          label="Analysis output root"
          value={text(config.output_dir, "")}
          directory
          onChange={(output_dir) => updateConfig({ output_dir })}
          hint="Each analysis creates its own runs/RUN_ID directory under this root."
        />
      </Section>
      <Section title="Cohort and outcome">
        <div className="form-grid">
          <ColumnChoice
            label="Sample ID column"
            value={config.sample_id}
            columns={columns}
            onChange={(sample_id) => updateConfig({ sample_id })}
          />
          <ColumnChoice
            label="Patient / group column"
            value={config.group_column}
            columns={columns}
            optional
            onChange={(group_column) => updateConfig({ group_column })}
          />
          {survival ? (
            <>
              <ColumnChoice
                label="Event column (0 / 1)"
                value={config.event}
                columns={columns}
                onChange={(event) => updateConfig({ event })}
              />
              <ColumnChoice
                label="Survival time column"
                value={config.time_variable}
                columns={columns}
                onChange={(time_variable) => updateConfig({ time_variable })}
              />
              <Field label="Time unit">
                <select
                  value={text(config.time_unit)}
                  onChange={(e) => updateConfig({ time_unit: e.target.value })}
                >
                  {props.time_unit.enum?.map((unit) => (
                    <option key={unit}>{unit}</option>
                  ))}
                </select>
              </Field>
              <Field label="Prediction horizon">
                <input
                  type="number"
                  min="0"
                  step="any"
                  value={text(config.horizon, "")}
                  onChange={(e) =>
                    updateConfig({ horizon: number(e.target.value) })
                  }
                />
              </Field>
            </>
          ) : (
            <>
              <ColumnChoice
                label="Outcome column"
                value={config.outcome}
                columns={columns}
                onChange={(outcome) => updateConfig({ outcome })}
              />
              {[
                ["positive_class", "Positive outcome code"],
                ["negative_class", "Negative outcome code"],
                ["positive_label", "Positive display label"],
                ["negative_label", "Negative display label"],
              ].map(([key, name]) => (
                <Field key={key} label={name}>
                  <input
                    value={text(config[key], "")}
                    onChange={(e) => updateConfig({ [key]: e.target.value })}
                  />
                </Field>
              ))}
            </>
          )}
        </div>
        <ColumnMultiSelect
          label="Clinical covariates"
          columns={columns}
          value={strings(config.clinical_columns)}
          onChange={(clinical_columns) => updateConfig({ clinical_columns })}
          hint="Numeric and categorical encoders are learned inside training partitions."
        />
      </Section>
      <Section
        title="Validation and model candidates"
        description="Algorithms, feature sets, panel size and thresholds are selected within each outer training cohort. Assessment patients never enter preprocessing or tuning."
      >
        <div className="form-grid">
          {numericFields.slice(0, 5).map((key) => (
            <Field key={key} label={names[key] ?? label(key)}>
              <input
                type="number"
                min={props[key].minimum}
                step="1"
                value={text(config[key], "")}
                onChange={(e) =>
                  updateConfig({ [key]: number(e.target.value) })
                }
              />
            </Field>
          ))}
        </div>
        <div className="form-grid">
          {[
            ["models", "Algorithms", ["stepwise", "elastic_net"]],
            ["feature_sets", "Feature sets", ["genes", "clinical", "combined"]],
          ].map(([rawKey, rawName, rawChoices]) => {
            const key = rawKey as string,
              choices = rawChoices as string[];
            return (
              <fieldset key={key}>
                <legend>{rawName as string}</legend>
                {choices.map((choice) => (
                  <label className="check" key={choice}>
                    <input
                      type="checkbox"
                      checked={strings(config[key]).includes(choice)}
                      onChange={(e) =>
                        updateConfig({
                          [key]: e.target.checked
                            ? [...strings(config[key]), choice]
                            : strings(config[key]).filter(
                                (item) => item !== choice,
                              ),
                        })
                      }
                    />
                    {label(choice)}
                  </label>
                ))}
                {key === "feature_sets" && (
                  <small>
                    None selected uses the engine default: genes, plus clinical
                    and combined when clinical covariates are supplied.
                  </small>
                )}
              </fieldset>
            );
          })}
        </div>
        <div className="form-grid">
          {["panel_sizes", "alpha_grid"].map((key) => (
            <Field
              key={key}
              label={
                key === "panel_sizes"
                  ? "Candidate panel sizes"
                  : "Elastic-net alpha grid"
              }
              hint="Numeric values separated by spaces or commas."
            >
              <input
                value={
                  arrayDraft[key] ??
                  (Array.isArray(config[key]) ? config[key].join(", ") : "")
                }
                onChange={(e) => setArray(key, e.target.value)}
              />
            </Field>
          ))}
        </div>
        <p className="muted">
          Elastic-net lambda ratios are fixed engine candidates: 1, 0.1, 0.01,
          0.001. Panel sizes count genes; clinical covariates are separate.
        </p>
      </Section>
      <Section title="Training feature selection">
        <div className="form-grid">
          {numericFields.slice(5).map((key) => (
            <Field key={key} label={names[key] ?? label(key)}>
              <input
                type="number"
                min={props[key].minimum ?? props[key].exclusiveMinimum}
                max={props[key].maximum}
                step={props[key].type === "number" ? "any" : "1"}
                value={text(config[key], "")}
                onChange={(e) =>
                  updateConfig({ [key]: number(e.target.value) })
                }
              />
            </Field>
          ))}
          <Field label="P-value adjustment">
            <select
              value={text(config.p_adjust_method)}
              onChange={(e) =>
                updateConfig({ p_adjust_method: e.target.value })
              }
            >
              {props.p_adjust_method.enum?.map((method) => (
                <option key={method}>{method}</option>
              ))}
            </select>
          </Field>
        </div>
        <p className="muted">
          Median imputation and scaling are fitted within each training
          partition. Full training-only prescreening precedes a bounded
          bootstrap candidate pool; the saved method records this restriction.
        </p>
        {[
          [
            "features",
            "Candidate assay columns",
            "Empty uses all non-role columns.",
          ],
          [
            "include",
            "Forced genes",
            "These genes remain eligible under the declared selection policy.",
          ],
          [
            "exclude",
            "Excluded genes",
            "These columns cannot enter the model.",
          ],
        ].map(([key, name, hint]) => (
          <ColumnMultiSelect
            key={key}
            label={name}
            hint={hint}
            columns={columns}
            value={strings(config[key])}
            onChange={(value) => updateConfig({ [key]: value })}
          />
        ))}
      </Section>
      <Section title="External gene evidence">
        <EvidencePicker
          value={config.evidence}
          onChange={(evidence) => updateConfig({ evidence })}
        />
      </Section>
      <Section title="Preflight QC">
        <p>
          QC describes the cohort and split feasibility. Training-fold
          exclusions and transformations are learned later. Every configuration
          edit invalidates this validation.
        </p>
        {validationError && <Notice tone="error">{validationError}</Notice>}
        <QcView value={object(validation?.result).qc} />
        {validatedConfig && (
          <JsonDetails
            value={validatedConfig}
            title="Exact normalized configuration used for analysis"
          />
        )}
        <div className="action-bar">
          <button
            disabled={validating || !settings || !config.data_file}
            onClick={() => void validateConfiguration()}
          >
            {validating ? "Validating…" : "Run QC"}
          </button>
          <button
            className="primary"
            disabled={
              busy || validating || !validatedConfig || !doctor?.success
            }
            onClick={() => void act(run)}
          >
            Run analysis
          </button>
          <small>
            {!doctor?.success
              ? "A ready runtime is required; inspect Settings."
              : !validatedConfig
                ? "Validate the current configuration first."
                : busy
                  ? "Another operation is active."
                  : "QC passed. A unique run will be created."}
          </small>
        </div>
      </Section>
    </div>
  );
}
