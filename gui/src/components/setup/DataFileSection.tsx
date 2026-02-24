import { useAnalysisStore } from "@/stores/analysisStore";
import { pickFile, readCsvHeader } from "@/lib/tauri/commands";

export function DataFileSection() {
  const dataFile = useAnalysisStore((s) => s.dataFile);
  const dataInfo = useAnalysisStore((s) => s.dataInfo);
  const setDataFile = useAnalysisStore((s) => s.setDataFile);
  const setDataInfo = useAnalysisStore((s) => s.setDataInfo);

  const handlePickFile = async () => {
    try {
      const path = await pickFile();
      if (path) {
        setDataFile(path);
        const info = await readCsvHeader(path);
        setDataInfo(info);
      }
    } catch (e) {
      console.error("File pick error:", e);
    }
  };

  return (
    <section className="border border-border rounded-lg p-4">
      <h3 className="text-sm font-medium mb-3">Data File</h3>

      <div className="flex items-center gap-3">
        <button
          onClick={handlePickFile}
          className="px-4 py-2 bg-secondary text-secondary-foreground rounded-md text-sm hover:bg-secondary/80 transition-colors"
        >
          Select CSV File
        </button>
        <span className="text-sm text-muted-foreground truncate flex-1">
          {dataFile || "No file selected"}
        </span>
      </div>

      {dataInfo && (
        <div className="mt-3 space-y-2">
          <p className="text-xs text-muted-foreground">
            {dataInfo.columns.length} columns, {dataInfo.rowCount} rows
          </p>

          <div className="overflow-x-auto border border-border rounded">
            <table className="w-full text-xs">
              <thead>
                <tr className="bg-muted/50">
                  {dataInfo.columns.slice(0, 10).map((col) => (
                    <th key={col} className="px-2 py-1 text-left font-medium whitespace-nowrap">
                      {col}
                    </th>
                  ))}
                  {dataInfo.columns.length > 10 && (
                    <th className="px-2 py-1 text-left font-medium text-muted-foreground">
                      +{dataInfo.columns.length - 10} more
                    </th>
                  )}
                </tr>
              </thead>
              <tbody>
                {Array.from({ length: Math.min(3, dataInfo.rowCount) }).map((_, rowIdx) => (
                  <tr key={rowIdx} className="border-t border-border">
                    {dataInfo.columns.slice(0, 10).map((col) => (
                      <td key={col} className="px-2 py-1 whitespace-nowrap text-muted-foreground">
                        {dataInfo.preview[col]?.[rowIdx] ?? ""}
                      </td>
                    ))}
                    {dataInfo.columns.length > 10 && <td className="px-2 py-1">...</td>}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>
      )}
    </section>
  );
}
