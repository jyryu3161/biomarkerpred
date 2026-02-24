import { useEffect, useRef } from "react";
import { cn } from "@/lib/utils";

interface LogConsoleProps {
  /** Array of log lines to display */
  logs: string[];
  /** Optional additional CSS class names */
  className?: string;
}

/**
 * LogConsole
 *
 * A reusable scrollable console-style log output component.
 * Auto-scrolls to the bottom when new log lines are appended.
 */
export function LogConsole({ logs, className }: LogConsoleProps) {
  const endRef = useRef<HTMLDivElement>(null);

  // Auto-scroll to bottom on new log entries
  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [logs.length]);

  // Scroll to bottom immediately on first render
  useEffect(() => {
    endRef.current?.scrollIntoView({ behavior: "instant" });
  }, []);

  return (
    <div
      className={cn(
        "bg-muted/30 rounded p-3 h-48 overflow-y-auto font-mono text-xs space-y-0.5",
        className,
      )}
    >
      {logs.length === 0 ? (
        <p className="text-muted-foreground">No log output yet.</p>
      ) : (
        logs.map((line, i) => (
          <div key={i} className="text-muted-foreground whitespace-pre-wrap">
            {line}
          </div>
        ))
      )}
      <div ref={endRef} />
    </div>
  );
}
