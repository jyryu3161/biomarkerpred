import { useState, useEffect } from "react";
import { readTextFile } from "@/lib/tauri/commands";

import { formatAuc, parseAucCsv, type AucRow } from "@/lib/auc";

export function AucTable({ outputDir }: { outputDir: string }) {
  const [rows, setRows] = useState<AucRow[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!outputDir) {
      setRows([]);
      return;
    }

    setLoading(true);
    setError(null);

    // The R analysis scripts write auc_iterations.csv to the output directory root
    const csvPath = `${outputDir}/auc_iterations.csv`;

    readTextFile(csvPath)
      .then((content) => {
        const parsed = parseAucCsv(content);
        setRows(parsed);
        setError(null);
      })
      .catch(() => {
        // File may not exist yet (analysis in progress, or no output yet)
        setRows([]);
        setError(null);
      })
      .finally(() => setLoading(false));
  }, [outputDir]);

  if (loading) {
    return (
      <div className="border border-border rounded-lg p-4">
        <h3 className="text-sm font-medium mb-2">AUC Summary</h3>
        <p className="text-xs text-muted-foreground">Loading AUC data...</p>
      </div>
    );
  }

  if (rows.length === 0) {
    return (
      <div className="border border-border rounded-lg p-4">
        <h3 className="text-sm font-medium mb-2">AUC Summary</h3>
        <p className="text-xs text-muted-foreground">
          AUC iteration data will appear here after analysis completes.
          {error && <span className="text-destructive ml-1">({error})</span>}
        </p>
      </div>
    );
  }

  return (
    <div className="border border-border rounded-lg p-4">
      <h3 className="text-sm font-medium mb-3">AUC Summary ({rows.length} iterations)</h3>
      <div className="overflow-x-auto">
        <table className="w-full text-xs">
          <thead>
            <tr className="bg-muted/50">
              <th className="px-3 py-2 text-left font-medium">Iteration</th>
              <th className="px-3 py-2 text-left font-medium">Train AUC</th>
              <th className="px-3 py-2 text-left font-medium">Test AUC</th>
              <th className="px-3 py-2 text-left font-medium">Selected Genes</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.iteration} className="border-t border-border hover:bg-muted/20">
                <td className="px-3 py-2 font-mono">{row.iteration}</td>
                <td className="px-3 py-2 font-mono">
                  {formatAuc(row.trainAuc, 4)}
                  {row.trainReason && <p className="text-muted-foreground font-sans">{row.trainReason}</p>}
                </td>
                <td className="px-3 py-2 font-mono">
                  {formatAuc(row.testAuc, 4)}
                  {row.testReason && <p className="text-muted-foreground font-sans">{row.testReason}</p>}
                </td>
                <td className="px-3 py-2 text-muted-foreground truncate max-w-xs" title={row.genes}>
                  {row.genes || "-"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}
