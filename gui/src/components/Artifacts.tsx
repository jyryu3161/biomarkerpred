import { useEffect, useState } from "react";
import { api } from "@/lib/api";
import { array, errorText, object, records, strings, text } from "@/lib/value";
import type { CsvTable, LoadedModel, RunRecord } from "@/lib/types";
import { DataTable, Facts, FileActions, JsonDetails, Notice } from "./Common";
export function ModelDetails({ loaded }: { loaded: LoadedModel }) {
  const model = loaded.model,
    outcome = object(model.outcome),
    features = strings(model.features),
    survival = model.analysis_type === "survival";
  return (
    <div className="stack">
      <Facts
        value={{
          analysis_type: model.analysis_type,
          algorithm: model.algorithm,
          feature_set: model.feature_set,
          model_version: model.model_version,
          sample_id: model.sample_id,
          group_column: model.group_column,
          selected_genes: model.selected_genes,
          clinical_columns: model.clinical_columns,
          required_predictors: features,
          threshold: model.threshold,
          threshold_method: model.threshold_method,
        }}
      />
      {features.length === 0 && (
        <Notice tone="info">
          Valid null model: no predictor columns are required. Sample and
          patient/group identifiers still apply.
        </Notice>
      )}
      <h3>Selected model and tuning</h3>
      <Facts value={model.hyperparameters} />
      <Facts value={model.selection} />
      <h3>Frozen outcome definition</h3>
      <Facts value={outcome} />
      {survival && (
        <Facts
          value={{
            time_unit: model.time_unit,
            horizon: model.horizon,
            baseline_available: Object.keys(object(model.baseline)).length > 0,
            baseline_time_points: array(object(model.baseline).time).length,
            baseline_ties: object(model.baseline).ties,
            baseline_reference_lp: object(model.baseline).reference_lp,
            training_time_range: object(model.training).time_range,
            training_events: object(model.training).events,
            training_censoring_convention: object(
              object(model.training).censor_curve,
            ).convention,
            training_censoring_time_points: array(
              object(object(model.training).censor_curve).time,
            ).length,
          }}
        />
      )}
      <p className="muted">
        {loaded.metrics_reason ||
          "Performance belongs to a verified development or external evaluation run, not the model file."}
      </p>
      <Facts
        value={{
          sha256: loaded.sha256,
          path: loaded.path,
          unknown_category_policy: model.unknown_category_policy,
        }}
      />
      <details>
        <summary>Frozen coefficients and encoding</summary>
        <DataTable
          data={Object.entries(object(model.coefficients)).map(
            ([design_column, coefficient]) => ({ design_column, coefficient }),
          )}
          title="coefficients"
        />
        <JsonDetails value={model.recipe} title="Saved preprocessing recipe" />
      </details>
      <FileActions path={loaded.path} name="model" />
    </div>
  );
}
export function SavedModel({ path }: { path: string }) {
  const [loaded, setLoaded] = useState<LoadedModel | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    let alive = true;
    api
      .model(path)
      .then((value) => {
        if (alive) setLoaded(value);
      })
      .catch((e) => {
        if (alive) setError(errorText(e));
      });
    return () => {
      alive = false;
    };
  }, [path]);
  return error ? (
    <Notice tone="error">{error}</Notice>
  ) : loaded ? (
    <ModelDetails loaded={loaded} />
  ) : (
    <p>Loading frozen model…</p>
  );
}
export function SavedCsv({ path, title }: { path: string; title: string }) {
  const [data, setData] = useState<CsvTable | null>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    let alive = true;
    api
      .csv(path)
      .then((value) => {
        if (alive) setData(value);
      })
      .catch((e) => {
        if (alive) setError(errorText(e));
      });
    return () => {
      alive = false;
    };
  }, [path]);
  return (
    <div className="stack">
      <FileActions path={path} name={title} />
      {error ? (
        <Notice tone="error">{error}</Notice>
      ) : data ? (
        <DataTable data={data} title={title} />
      ) : (
        <p>Loading saved records…</p>
      )}
    </div>
  );
}
export function DriftView({ path }: { path: string }) {
  const [data, setData] = useState<unknown>(null);
  const [error, setError] = useState("");
  useEffect(() => {
    let alive = true;
    api
      .readText(path)
      .then((raw) => {
        const value: unknown = JSON.parse(raw);
        if (alive) setData(value);
      })
      .catch((e) => {
        if (alive) setError(errorText(e));
      });
    return () => {
      alive = false;
    };
  }, [path]);
  const drift = object(data);
  return (
    <div className="stack">
      {error && <Notice tone="error">{error}</Notice>}
      <p>{text(drift.method, "")}</p>
      <Facts value={drift.coverage} />
      <h3>Cohort overlap</h3>
      <Facts value={drift.overlap} />
      {strings(drift.warnings).map((warning, i) => (
        <Notice key={i} tone="warning">
          {warning}
        </Notice>
      ))}
      <DataTable
        data={records(drift.numeric_and_missingness)}
        title="drift diagnostics"
      />
      <DataTable
        data={records(drift.categorical)}
        title="category distributions"
      />
      <p>{text(drift.limitation, "")}</p>
    </div>
  );
}
function FigurePreview({ path, title }: { path: string; title: string }) {
  const [url, setUrl] = useState("");
  const [error, setError] = useState("");
  useEffect(() => {
    let alive = true;
    api
      .image(path)
      .then((base64) => {
        if (alive) setUrl(`data:image/svg+xml;base64,${base64}`);
      })
      .catch((e) => {
        if (alive) setError(errorText(e));
      });
    return () => {
      alive = false;
    };
  }, [path]);
  return error ? (
    <Notice tone="error">{error}</Notice>
  ) : url ? (
    <img className="saved-figure" src={url} alt={title} />
  ) : (
    <p>Loading saved figure…</p>
  );
}
export function Figures({ run }: { run: RunRecord }) {
  const figures = records(object(run.artifacts["figures/index.json"]).figures);
  const [selected, setSelected] = useState("");
  if (!figures.length)
    return <p className="muted">No saved figures are available.</p>;
  return (
    <div className="stack">
      {figures.map((figure, i) => {
        const key = text(figure.id ?? figure.kind, String(i));
        const files = object(figure.files);
        return (
          <article className="figure-card" key={key}>
            <h3>{text(figure.title, key)}</h3>
            <p>{text(figure.caption, "")}</p>
            <small>
              {text(figure.role, "")} {text(figure.reason, "")}
            </small>
            <div className="row">
              {typeof files.svg === "string" && run.paths[files.svg] && (
                <button
                  onClick={() => setSelected(selected === key ? "" : key)}
                >
                  {selected === key ? "Hide" : "Preview"}{" "}
                  {text(figure.title, key)}
                </button>
              )}
              {Object.entries(files).map(([format, name]) => (
                <FileActions
                  key={format}
                  name={format.toUpperCase()}
                  path={run.paths[text(name)]}
                />
              ))}
            </div>
            {selected === key &&
              typeof files.svg === "string" &&
              run.paths[files.svg] && (
                <FigurePreview
                  key={run.paths[files.svg]}
                  path={run.paths[files.svg]}
                  title={text(figure.title)}
                />
              )}
          </article>
        );
      })}
    </div>
  );
}
