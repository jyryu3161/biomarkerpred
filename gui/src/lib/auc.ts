export interface AucRow {
  iteration: number;
  trainAuc: number | null;
  testAuc: number | null;
  trainReason: string | null;
  testReason: string | null;
  genes: string;
}

export function formatAuc(value: number | null, digits: number): string {
  return value != null && Number.isFinite(value) ? value.toFixed(digits) : "NA";
}

/** Read R CSV output, including commas, escaped quotes and newlines in reasons. */
function csvRecords(raw: string): string[][] {
  const records: string[][] = [];
  let record: string[] = [];
  let field = "";
  let quoted = false;
  for (let i = 0; i < raw.length; i++) {
    const char = raw[i];
    if (char === '"') {
      if (quoted && raw[i + 1] === '"') {
        field += '"';
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (!quoted && (char === "," || char === "\n" || char === "\r")) {
      record.push(field.trim());
      field = "";
      if (char !== ",") {
        if (record.some((value) => value !== "")) records.push(record);
        record = [];
        if (char === "\r" && raw[i + 1] === "\n") i++;
      }
    } else {
      field += char;
    }
  }
  record.push(field.trim());
  if (record.some((value) => value !== "")) records.push(record);
  return records;
}

export function parseAucCsv(raw: string): AucRow[] {
  const [header, ...records] = csvRecords(raw);
  if (!header) return [];
  const headers = header.map((h) => h.toLowerCase().replace(/[_\s]/g, ""));
  const findCol = (...names: string[]) => names.map((name) => headers.indexOf(name)).find((i) => i >= 0) ?? -1;
  const iterCol = findCol("iteration", "seed", "iter");
  const trainCol = findCol("trainauc", "traianauc");
  const testCol = findCol("testauc");
  const trainReasonCol = findCol("trainaucreason");
  const testReasonCol = findCol("testaucreason");
  const geneCol = findCol("selectedgenes", "genes", "selectedgene", "gene", "variable");
  const auc = (value: string | undefined) => {
    if (!value) return null;
    const parsed = Number(value);
    return Number.isFinite(parsed) ? parsed : null;
  };
  const reason = (value: string | undefined, metric: number | null) =>
    value && value !== "NA" ? value : metric == null ? "AUC unavailable; no reason recorded" : null;

  return records.flatMap((fields, index) => {
    const iteration = iterCol >= 0 ? Number(fields[iterCol]) : index + 1;
    if (!Number.isFinite(iteration)) return [];
    const trainAuc = auc(fields[trainCol]);
    const testAuc = auc(fields[testCol]);
    return [{
      iteration,
      trainAuc,
      testAuc,
      trainReason: reason(fields[trainReasonCol], trainAuc),
      testReason: reason(fields[testReasonCol], testAuc),
      genes: (fields[geneCol] ?? "").replace(/;/g, ", "),
    }];
  });
}
