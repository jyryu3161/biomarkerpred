import { useState, useRef, useEffect, useMemo } from "react";
import { useAnalysisStore } from "@/stores/analysisStore";

const MAX_VISIBLE = 100;

function ColumnSelect({
  label,
  value,
  columns,
  onChange,
  optional = false,
}: {
  label: string;
  value: string;
  columns: string[];
  onChange: (v: string) => void;
  optional?: boolean;
}) {
  const [query, setQuery] = useState("");
  const [isOpen, setIsOpen] = useState(false);
  const containerRef = useRef<HTMLDivElement>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const filtered = useMemo(() => {
    if (!query) return columns.slice(0, MAX_VISIBLE);
    const q = query.toLowerCase();
    const matches: string[] = [];
    for (const col of columns) {
      if (col.toLowerCase().includes(q)) {
        matches.push(col);
        if (matches.length >= MAX_VISIBLE) break;
      }
    }
    return matches;
  }, [columns, query]);

  // Click outside to close
  useEffect(() => {
    const handler = (e: MouseEvent) => {
      if (containerRef.current && !containerRef.current.contains(e.target as Node)) {
        setIsOpen(false);
        setQuery("");
      }
    };
    document.addEventListener("mousedown", handler);
    return () => document.removeEventListener("mousedown", handler);
  }, []);

  const handleSelect = (col: string) => {
    onChange(col);
    setIsOpen(false);
    setQuery("");
  };

  const handleClear = () => {
    onChange("");
    setIsOpen(false);
    setQuery("");
  };

  return (
    <div className="flex flex-col gap-1">
      <label className="text-xs font-medium text-muted-foreground">
        {label}
        {optional && <span className="ml-1 text-muted-foreground/60">(optional)</span>}
      </label>
      <div ref={containerRef} className="relative">
        <input
          ref={inputRef}
          type="text"
          value={isOpen ? query : value}
          onChange={(e) => {
            setQuery(e.target.value);
            if (!isOpen) setIsOpen(true);
          }}
          onFocus={() => {
            setQuery("");
            setIsOpen(true);
          }}
          placeholder={value || "Search columns..."}
          className="w-full h-9 px-3 rounded-md border border-border bg-background text-sm focus:outline-none focus:ring-1 focus:ring-primary"
        />
        {isOpen && (
          <ul className="absolute z-50 mt-1 w-full max-h-52 overflow-y-auto rounded-md border border-border bg-background shadow-lg">
            {optional && (
              <li>
                <button
                  type="button"
                  onMouseDown={(e) => e.preventDefault()}
                  onClick={handleClear}
                  className="w-full text-left px-3 py-1.5 text-sm text-muted-foreground hover:bg-muted/50 italic"
                >
                  (none)
                </button>
              </li>
            )}
            {filtered.length === 0 ? (
              <li className="px-3 py-2 text-sm text-muted-foreground">
                No matching columns
              </li>
            ) : (
              filtered.map((col) => (
                <li key={col}>
                  <button
                    type="button"
                    onMouseDown={(e) => e.preventDefault()}
                    onClick={() => handleSelect(col)}
                    className={`w-full text-left px-3 py-1.5 text-sm hover:bg-muted/50 ${
                      col === value ? "bg-primary/10 text-primary font-medium" : ""
                    }`}
                  >
                    {col}
                  </button>
                </li>
              ))
            )}
            {!query && columns.length > MAX_VISIBLE && (
              <li className="px-3 py-1.5 text-xs text-muted-foreground border-t border-border">
                Type to search {columns.length.toLocaleString()} columns...
              </li>
            )}
          </ul>
        )}
      </div>
    </div>
  );
}

export function ColumnMappingSection() {
  const analysisType = useAnalysisStore((s) => s.analysisType);
  const dataInfo = useAnalysisStore((s) => s.dataInfo);
  const sampleId = useAnalysisStore((s) => s.sampleId);
  const outcome = useAnalysisStore((s) => s.outcome);
  const event = useAnalysisStore((s) => s.event);
  const timeVariable = useAnalysisStore((s) => s.timeVariable);
  const setColumnMapping = useAnalysisStore((s) => s.setColumnMapping);

  const columns = dataInfo?.columns ?? [];

  return (
    <section className="border border-border rounded-lg p-4">
      <h3 className="text-sm font-medium mb-3">Column Mapping</h3>

      {columns.length === 0 ? (
        <p className="text-sm text-muted-foreground">
          Load a CSV file first to map columns.
        </p>
      ) : (
        <div className="grid grid-cols-2 gap-4">
          <ColumnSelect
            label="Sample ID"
            value={sampleId}
            columns={columns}
            onChange={(v) => setColumnMapping("sampleId", v)}
          />

          {analysisType === "binary" ? (
            <ColumnSelect
              label="Response (0/1)"
              value={outcome}
              columns={columns}
              onChange={(v) => setColumnMapping("outcome", v)}
            />
          ) : (
            <ColumnSelect
              label="Event (0/1)"
              value={event}
              columns={columns}
              onChange={(v) => setColumnMapping("event", v)}
            />
          )}

          <ColumnSelect
            label="Time Variable"
            value={timeVariable}
            columns={columns}
            onChange={(v) => setColumnMapping("timeVariable", v)}
            optional={analysisType === "binary"}
          />
        </div>
      )}
    </section>
  );
}
