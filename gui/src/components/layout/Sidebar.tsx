import { useState, useEffect } from "react";
import { getVersion } from "@tauri-apps/api/app";
import { cn } from "@/lib/utils";

export type Page = "setup" | "results" | "pathway" | "settings";

interface SidebarProps {
  currentPage: Page;
  onPageChange: (page: Page) => void;
  analysisRunning: boolean;
  oraRunning?: boolean;
}

const navItems: { id: Page; label: string; icon: string }[] = [
  { id: "setup", label: "Setup", icon: "⚙️" },
  { id: "results", label: "Results", icon: "📊" },
  { id: "pathway", label: "Pathway Analysis", icon: "🧬" },
  { id: "settings", label: "Settings", icon: "🔧" },
];

export function Sidebar({ currentPage, onPageChange, analysisRunning, oraRunning }: SidebarProps) {
  const [version, setVersion] = useState<string>("");
  useEffect(() => {
    getVersion().then(setVersion).catch(() => setVersion(""));
  }, []);

  return (
    <aside className="w-48 border-r border-border bg-secondary/30 flex flex-col">
      <div className="p-4 border-b border-border">
        <h1 className="text-sm font-bold text-primary">RESPRED</h1>
        <p className="text-xs text-muted-foreground mt-0.5">Drug Response Biomarker Prediction</p>
      </div>
      <nav className="flex-1 p-2 space-y-1">
        {navItems.map((item) => (
          <button
            key={item.id}
            onClick={() => onPageChange(item.id)}
            className={cn(
              "w-full flex items-center gap-2 px-3 py-2 rounded-md text-sm transition-colors text-left",
              currentPage === item.id
                ? "bg-primary text-primary-foreground"
                : "hover:bg-accent text-foreground",
            )}
          >
            <span>{item.icon}</span>
            <span>{item.label}</span>
            {item.id === "results" && analysisRunning && (
              <span className="ml-auto w-2 h-2 rounded-full bg-green-500" />
            )}
            {item.id === "pathway" && oraRunning && (
              <span className="ml-auto w-2 h-2 rounded-full bg-green-500" />
            )}
          </button>
        ))}
      </nav>
      {version && (
        <div className="p-3 border-t border-border text-xs text-muted-foreground">
          v{version}
        </div>
      )}
    </aside>
  );
}
