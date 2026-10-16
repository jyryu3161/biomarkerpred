import { cloneElement, isValidElement, useId, useMemo, useState } from "react";
import type { ReactElement, ReactNode } from "react";
import { api } from "@/lib/api";
import { errorText, label, object, text } from "@/lib/value";
import type { CsvTable, JsonObject } from "@/lib/types";
export function Notice({
  children,
  tone = "info",
}: {
  children: ReactNode;
  tone?: "error" | "warning" | "info" | "success";
}) {
  return (
    <div
      className={`notice ${tone}`}
      role={tone === "error" ? "alert" : "status"}
    >
      {children}
    </div>
  );
}
export function Section({
  title,
  description,
  children,
}: {
  title: string;
  description?: string;
  children: ReactNode;
}) {
  return (
    <section className="card">
      <div className="section-heading">
        <h2>{title}</h2>
        {description && <p className="muted">{description}</p>}
      </div>
      {children}
    </section>
  );
}
export function Field({
  label: name,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: ReactNode;
}) {
  const hintId = useId();
  const child = children as ReactElement<{
    "aria-label"?: string;
    "aria-describedby"?: string;
  }>;
  const control =
    isValidElement(child) &&
    typeof child.type === "string" &&
    ["input", "select", "textarea"].includes(child.type)
      ? cloneElement(child, {
          "aria-label": child.props["aria-label"] ?? name,
          "aria-describedby": hint ? hintId : child.props["aria-describedby"],
        })
      : children;
  return (
    <label className="field">
      <span>{name}</span>
      {control}
      {hint && <small id={hintId}>{hint}</small>}
    </label>
  );
}
export function PathField({
  label: name,
  value,
  onChange,
  directory = false,
  hint,
  disabled = false,
}: {
  label: string;
  value: string;
  onChange: (value: string) => void;
  directory?: boolean;
  hint?: string;
  disabled?: boolean;
}) {
  const [error, setError] = useState("");
  return (
    <div>
      <Field label={name} hint={hint}>
        <span className="input-action">
          <input
            aria-label={name}
            value={value}
            onChange={(event) => onChange(event.target.value)}
            disabled={disabled}
          />
          <button
            type="button"
            disabled={disabled}
            onClick={async () => {
              try {
                const path = await (directory
                  ? api.pickDirectory()
                  : api.pickFile());
                if (path) onChange(path);
                setError("");
              } catch (e) {
                setError(errorText(e));
              }
            }}
          >
            Browse
          </button>
        </span>
      </Field>
      {error && <Notice tone="error">{error}</Notice>}
    </div>
  );
}
export function ColumnChoice({
  label: name,
  value,
  columns,
  onChange,
  optional = false,
}: {
  label: string;
  value: unknown;
  columns: string[];
  onChange: (value: string | null) => void;
  optional?: boolean;
}) {
  const id = useId();
  const current = typeof value === "string" ? value : "";
  const [query, setQuery] = useState("");
  const matches = columns.filter((column) =>
    column.toLocaleLowerCase().includes(query.toLocaleLowerCase()),
  );
  return (
    <div className="column-choice">
      <label className="field" htmlFor={id}>
        <span>{name}</span>
        <input
          id={id}
          value={current}
          onChange={(e) => onChange(e.target.value || null)}
          placeholder={optional ? "None" : "Exact column name"}
        />
      </label>
      <details>
        <summary>Select from {columns.length.toLocaleString()} columns</summary>
        <input
          aria-label={`Search ${name} columns`}
          value={query}
          onChange={(e) => setQuery(e.target.value)}
        />
        {optional && (
          <button className="text-button" onClick={() => onChange(null)}>
            None
          </button>
        )}
        <div className="column-options">
          {matches.slice(0, 60).map((column) => (
            <button
              key={column}
              className={current === column ? "selected" : ""}
              title={column}
              onClick={() => onChange(column)}
            >
              {column}
            </button>
          ))}
        </div>
        <small>
          {matches.length > 60
            ? `Showing 60 of ${matches.length}; narrow the search.`
            : `${matches.length} matching columns`}
        </small>
      </details>
    </div>
  );
}
export function ColumnMultiSelect({
  label: name,
  columns,
  value,
  onChange,
  hint,
}: {
  label: string;
  columns: string[];
  value: string[];
  onChange: (value: string[]) => void;
  hint?: string;
}) {
  const [query, setQuery] = useState("");
  const selected = useMemo(() => new Set(value), [value]);
  const matches = useMemo(
    () =>
      [...new Set([...value, ...columns])].filter((column) =>
        column.toLocaleLowerCase().includes(query.toLocaleLowerCase()),
      ),
    [columns, value, query],
  );
  return (
    <details className="multi-select">
      <summary>
        {name} <span className="badge">{value.length} selected</span>
      </summary>
      {hint && <p className="muted">{hint}</p>}
      <input
        aria-label={`Search ${name}`}
        placeholder="Search exact column names"
        value={query}
        onChange={(e) => setQuery(e.target.value)}
      />
      <div className="row">
        <button onClick={() => onChange([])}>Clear {name.toLowerCase()}</button>
        <small>{matches.length.toLocaleString()} matches; up to 60 shown</small>
      </div>
      <div className="column-options">
        {matches.slice(0, 60).map((column) => (
          <label key={column}>
            <input
              type="checkbox"
              checked={selected.has(column)}
              onChange={(e) =>
                onChange(
                  e.target.checked
                    ? [...value, column]
                    : value.filter((item) => item !== column),
                )
              }
            />
            <span>{column}</span>
          </label>
        ))}
      </div>
      <details>
        <summary>Selected identifiers ({value.length})</summary>
        <ul>
          {value.slice(0, 100).map((column) => (
            <li key={column} className="identifier">
              {column}
            </li>
          ))}
        </ul>
        {value.length > 100 && (
          <p>First 100 shown; search to inspect or remove others.</p>
        )}
      </details>
    </details>
  );
}
export function DataTable({
  data,
  title = "Records",
  columns,
  pageSize = 25,
}: {
  data: CsvTable | JsonObject[];
  title?: string;
  columns?: string[];
  pageSize?: number;
}) {
  const isCsv = !Array.isArray(data);
  const rows = isCsv ? data.rows : data;
  const headers = useMemo(
    () =>
      columns ??
      (isCsv
        ? data.headers
        : [...new Set(rows.flatMap((row) => Object.keys(row)))]),
    [columns, isCsv, data, rows],
  );
  const [query, setQuery] = useState("");
  const [page, setPage] = useState(0);
  const filtered = useMemo(
    () =>
      rows.filter((row) =>
        headers.some((key) =>
          text(row[key], "")
            .toLocaleLowerCase()
            .includes(query.toLocaleLowerCase()),
        ),
      ),
    [rows, headers, query],
  );
  const last = Math.max(0, Math.ceil(filtered.length / pageSize) - 1);
  const current = Math.min(page, last);
  return (
    <div className="data-table">
      <div className="row spread">
        <input
          aria-label={`Search ${title}`}
          placeholder={`Search ${title.toLowerCase()}`}
          value={query}
          onChange={(e) => {
            setQuery(e.target.value);
            setPage(0);
          }}
        />
        <small>
          {filtered.length.toLocaleString()} matching /{" "}
          {isCsv ? data.count.toLocaleString() : rows.length.toLocaleString()}{" "}
          records
        </small>
      </div>
      <div className="table-scroll">
        <table>
          <thead>
            <tr>
              {headers.map((header) => (
                <th key={header}>{label(header)}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {filtered
              .slice(current * pageSize, (current + 1) * pageSize)
              .map((row, i) => (
                <tr key={`${current}-${i}`}>
                  {headers.map((header) => (
                    <td key={header} className="preserve">
                      {text(row[header], "—")}
                    </td>
                  ))}
                </tr>
              ))}
          </tbody>
        </table>
      </div>
      {!filtered.length && <p className="muted">No matching records.</p>}
      <div className="row pager">
        <button disabled={current === 0} onClick={() => setPage(current - 1)}>
          Previous
        </button>
        <span>
          Page {current + 1} / {last + 1}
        </span>
        <button
          disabled={current === last}
          onClick={() => setPage(current + 1)}
        >
          Next
        </button>
      </div>
    </div>
  );
}
export function Facts({
  value,
  omit = [],
}: {
  value: unknown;
  omit?: string[];
}) {
  const entries = Object.entries(object(value)).filter(
    ([key]) => !omit.includes(key),
  );
  return (
    <dl className="facts">
      {entries.map(([key, item]) => (
        <div key={key}>
          <dt>{label(key)}</dt>
          <dd>
            {Array.isArray(item)
              ? item.length
                ? item.map((x) => text(x)).join(" · ")
                : "None"
              : text(item)}
          </dd>
        </div>
      ))}
    </dl>
  );
}
export function JsonDetails({
  value,
  title = "Saved metadata",
}: {
  value: unknown;
  title?: string;
}) {
  return (
    <details>
      <summary>{title}</summary>
      <pre className="json">{JSON.stringify(value, null, 2)}</pre>
    </details>
  );
}
export function FileActions({ path, name }: { path?: string; name: string }) {
  const [error, setError] = useState("");
  if (!path) return null;
  const act = async (save: boolean) => {
    try {
      if (save) await api.save(path, path.split(/[\\/]/).at(-1) || name);
      else await api.open(path);
      setError("");
    } catch (e) {
      setError(errorText(e));
    }
  };
  return (
    <span className="file-actions">
      <button onClick={() => void act(false)}>Open {name}</button>
      <button onClick={() => void act(true)}>Export {name}</button>
      {error && (
        <span role="alert" className="error-text">
          {error}
        </span>
      )}
    </span>
  );
}
