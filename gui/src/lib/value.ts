import type { CsvTable, JsonObject, SchemaProperty } from "./types";
export function object(value: unknown): JsonObject {
  return value !== null && typeof value === "object" && !Array.isArray(value)
    ? (value as JsonObject)
    : {};
}
export function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}
export function records(value: unknown): JsonObject[] {
  return array(value).map(object);
}
export function strings(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((x): x is string => typeof x === "string")
    : typeof value === "string"
      ? [value]
      : [];
}
export function text(value: unknown, fallback = "Unavailable"): string {
  return value === null || value === undefined || value === ""
    ? fallback
    : typeof value === "object"
      ? JSON.stringify(value)
      : String(value);
}
export function number(value: unknown): number | null {
  if (
    value === null ||
    value === undefined ||
    typeof value === "boolean" ||
    (typeof value === "string" && !value.trim())
  )
    return null;
  const n =
    typeof value === "number" || typeof value === "string"
      ? Number(value)
      : NaN;
  return Number.isFinite(n) ? n : null;
}
export function numeric(value: unknown): string {
  const n = number(value);
  return n === null
    ? "Unavailable"
    : n === 0
      ? "0"
      : Math.abs(n) < 0.0001
        ? n.toExponential(3)
        : n.toLocaleString("en-US", { maximumFractionDigits: 4 });
}
export function label(value: string): string {
  return value.replaceAll("_", " ").replace(/^./, (c) => c.toUpperCase());
}
export function properties(schema: JsonObject): Record<string, SchemaProperty> {
  return object(object(object(schema.$defs).analysis).properties) as Record<
    string,
    SchemaProperty
  >;
}
export function schemaDefaults(schema: JsonObject, type: string): JsonObject {
  return Object.fromEntries(
    Object.entries(properties(schema))
      .map(([key, property]) => [
        key,
        structuredClone(
          type === "survival" && Object.hasOwn(property, "x-survival-default")
            ? property["x-survival-default"]
            : property.default,
        ),
      ])
      .concat([["analysis_type", type]]),
  );
}
export function table(value: unknown): CsvTable | null {
  const v = object(value);
  return Array.isArray(v.headers) && Array.isArray(v.rows)
    ? (v as unknown as CsvTable)
    : null;
}
export function errorText(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
export function joinPath(root: string, part: string): string {
  return (
    root.replace(/[\\/]$/, "") +
    (root.includes("\\") && !root.includes("/") ? "\\" : "/") +
    part
  );
}
export function responseError(response: {
  result: JsonObject;
  verificationError: string | null;
  stderrTail: string[];
}): string {
  return (
    [
      response.verificationError,
      response.result.error,
      ...response.stderrTail.slice(-8),
    ]
      .filter(Boolean)
      .map((x) => text(x))
      .join("\n") || "The engine did not verify this operation as successful."
  );
}
