import { object, records, strings, text } from "@/lib/value";
import { DataTable, Facts, JsonDetails, Notice } from "./Common";
export function QcView({ value }: { value: unknown }) {
  const qc = object(value);
  if (!Object.keys(qc).length) return null;
  const errors = strings(qc.errors),
    warnings = strings(qc.warnings);
  const counts = Object.fromEntries(
    Object.entries(qc).filter(
      ([key, v]) =>
        [
          "status",
          "analysis_type",
          "rows",
          "columns",
          "groups",
          "repeated_groups",
          "largest_group",
          "gene_count",
          "clinical_count",
          "events",
          "censored",
          "class_counts",
          "class_group_counts",
          "event_counts",
          "prediction_rows",
        ].includes(key) && v !== undefined,
    ),
  );
  const exclusions = [
    "duplicate_sample_ids",
    "constant_columns",
    "high_missing_columns",
    "excluded_genes",
    "excluded_rows",
  ].filter((key) => strings(qc[key]).length);
  return (
    <div className="stack">
      <Facts value={counts} />
      {errors.map((error, i) => (
        <Notice tone="error" key={i}>
          {error}
        </Notice>
      ))}
      {warnings.map((warning, i) => (
        <Notice tone="warning" key={i}>
          {warning}
        </Notice>
      ))}
      {qc.preprocessing ? <p>{text(qc.preprocessing)}</p> : null}
      <Facts value={qc.validation} />
      {exclusions.map((key) => (
        <details key={key}>
          <summary>
            {key.replaceAll("_", " ")} ({strings(qc[key]).length})
          </summary>
          <DataTable
            data={strings(qc[key]).map((identifier) => ({ identifier }))}
            title={key}
          />
        </details>
      ))}
      {Object.keys(object(qc.missing_fraction)).length > 0 && (
        <details>
          <summary>Missingness by predictor</summary>
          <DataTable
            data={Object.entries(object(qc.missing_fraction)).map(
              ([predictor, fraction]) => ({
                predictor,
                missing_fraction: fraction,
              }),
            )}
            title="predictor missingness"
          />
        </details>
      )}
      {records(qc.exclusions).length > 0 && (
        <DataTable data={records(qc.exclusions)} title="exclusions" />
      )}
      <JsonDetails value={qc} title="Full validation report" />
    </div>
  );
}
