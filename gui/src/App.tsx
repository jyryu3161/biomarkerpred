import { useState, useEffect, useRef } from "react";
import { listen } from "@tauri-apps/api/event";
import { Sidebar, type Page } from "@/components/layout/Sidebar";
import { SetupPage } from "@/pages/SetupPage";
import { ResultsPage } from "@/pages/ResultsPage";
import { SettingsPage } from "@/pages/SettingsPage";
import { EnvironmentSetup } from "@/components/environment/EnvironmentSetup";
import { useAnalysisStore } from "@/stores/analysisStore";
import { useConfigStore } from "@/stores/configStore";
import { checkEnv, checkImageUpdate, pullDockerImage } from "@/lib/tauri/commands";

type UpdateState = "idle" | "checking" | "available" | "updating" | "done" | "dismissed";

function App() {
  const [currentPage, setCurrentPage] = useState<Page>("setup");
  const status = useAnalysisStore((s) => s.status);
  const setRuntimeInfo = useConfigStore((s) => s.setRuntimeInfo);
  const envStatus = useConfigStore((s) => s.envStatus);
  const setEnvStatus = useConfigStore((s) => s.setEnvStatus);
  const setEnvChecking = useConfigStore((s) => s.setEnvChecking);
  const setupStatus = useConfigStore((s) => s.setupStatus);

  const hasResults =
    status === "completed" || status === "running" || status === "failed";

  // Determine if environment is ready (Docker-only)
  const envReady = envStatus
    ? envStatus.dockerAvailable && envStatus.dockerImagePresent
    : false;

  // Show main UI after setup completes (with brief delay for UX)
  const [showMain, setShowMain] = useState(false);
  useEffect(() => {
    if (envReady) {
      const timer = setTimeout(() => setShowMain(true), setupStatus === "completed" ? 1000 : 0);
      return () => clearTimeout(timer);
    } else {
      setShowMain(false);
    }
  }, [envReady, setupStatus]);

  // Image update check state
  const [updateState, setUpdateState] = useState<UpdateState>("idle");
  const [updateLogs, setUpdateLogs] = useState<string[]>([]);
  const updateChecked = useRef(false);

  // Check for image update once after main UI becomes visible
  useEffect(() => {
    if (!showMain || updateChecked.current) return;
    updateChecked.current = true;
    setUpdateState("checking");
    checkImageUpdate()
      .then(({ hasUpdate }) => {
        setUpdateState(hasUpdate ? "available" : "idle");
      })
      .catch(() => setUpdateState("idle")); // never block startup
  }, [showMain]);

  const handleImageUpdate = async () => {
    setUpdateLogs([]);
    setUpdateState("updating");
    const unlisten = await listen<string>("setup://log", (e) => {
      setUpdateLogs((prev) => [...prev, e.payload]);
    });
    const unlistenDone = await listen<{ success: boolean }>("setup://complete", (e) => {
      unlisten();
      unlistenDone();
      setUpdateState(e.payload.success ? "done" : "available");
    });
    try {
      await pullDockerImage();
    } catch {
      unlisten();
      unlistenDone();
      setUpdateState("available");
    }
  };

  // Warn before closing if analysis is running
  useEffect(() => {
    const handler = (e: BeforeUnloadEvent) => {
      if (useAnalysisStore.getState().status === "running") {
        e.preventDefault();
      }
    };
    window.addEventListener("beforeunload", handler);
    return () => window.removeEventListener("beforeunload", handler);
  }, []);

  // Check environment on startup
  useEffect(() => {
    setEnvChecking(true);
    checkEnv()
      .then((status) => {
        setEnvStatus(status);
        // Also populate legacy runtime info
        setRuntimeInfo({
          rPath: status.rPath,
          pixiPath: status.pixiPath,
          rVersion: status.rVersion,
        });
      })
      .catch((e: unknown) => console.error("Env check failed:", e))
      .finally(() => setEnvChecking(false));
  }, [setEnvStatus, setEnvChecking, setRuntimeInfo]);

  // Listen for analysis events from Rust backend
  useEffect(() => {
    const unlisten: (() => void)[] = [];

    listen<{ success: boolean; code: number | null }>(
      "analysis://complete",
      (event) => {
        const { success, code } = event.payload;
        const store = useAnalysisStore.getState();
        if (store.status === "cancelled") {
          store.appendLog(`Analysis cancelled by user (exit code ${code})`);
          return;
        }
        store.appendLog(
          success
            ? `Analysis completed successfully (exit code ${code})`
            : `Analysis finished with exit code ${code}`,
        );
        if (!success) {
          store.setParam("errorMessage", `Exit code ${code}. Check Results > Log for details.`);
        }
        store.setStatus(success ? "completed" : "failed");
      },
    ).then((u) => unlisten.push(u));

    listen<{ message: string }>("analysis://error", (event) => {
      const store = useAnalysisStore.getState();
      if (store.status === "cancelled") return;
      store.appendLog(`Error: ${event.payload.message}`);
      store.setParam("errorMessage", event.payload.message);
      store.setStatus("failed");
    }).then((u) => unlisten.push(u));

    listen<string>("analysis://log", (event) => {
      useAnalysisStore.getState().appendLog(event.payload);
    }).then((u) => unlisten.push(u));

    listen<{ type: string; current: number; total: number; message: string }>(
      "analysis://progress",
      (event) => {
        const { type, current, total, message } = event.payload;
        const store = useAnalysisStore.getState();
        const prev = store.progress;
        if (type === "total") {
          store.setProgress(0, total, message);
        } else if (type === "iteration_complete") {
          store.setProgress(current, prev.total || total, message);
        } else {
          store.setProgress(current, total || prev.total, message);
        }
      },
    ).then((u) => unlisten.push(u));

    return () => {
      unlisten.forEach((u) => u());
    };
  }, []);

  // Environment gate: show setup screen if env not ready
  if (!showMain) {
    return (
      <div className="flex h-screen w-screen overflow-hidden bg-background text-foreground">
        <EnvironmentSetup />
      </div>
    );
  }

  return (
    <div className="flex h-screen w-screen overflow-hidden bg-background text-foreground">
      <Sidebar
        currentPage={currentPage}
        onPageChange={setCurrentPage}
        analysisRunning={hasResults}
      />
      <main className="flex-1 flex flex-col overflow-hidden">
        {/* Image update banner */}
        {updateState === "available" && (
          <div className="flex items-center justify-between gap-3 px-4 py-2 text-xs bg-amber-500/10 border-b border-amber-500/25 shrink-0">
            <span className="text-amber-700 dark:text-amber-400">
              A new version of the analysis image is available.
            </span>
            <div className="flex gap-2">
              <button
                onClick={handleImageUpdate}
                className="px-3 py-1 rounded bg-amber-600 text-white hover:bg-amber-700 transition-colors font-medium"
              >
                Update Now
              </button>
              <button
                onClick={() => setUpdateState("dismissed")}
                className="px-2 py-1 rounded text-amber-700 dark:text-amber-400 hover:bg-amber-500/20 transition-colors"
              >
                Dismiss
              </button>
            </div>
          </div>
        )}
        {updateState === "updating" && (
          <div className="px-4 py-2 text-xs bg-blue-500/10 border-b border-blue-500/25 shrink-0 space-y-1">
            <span className="text-blue-700 dark:text-blue-400 font-medium">
              Updating analysis image...
            </span>
            {updateLogs.length > 0 && (
              <div className="font-mono text-muted-foreground max-h-16 overflow-y-auto">
                {updateLogs.slice(-4).map((l, i) => (
                  <div key={i}>{l}</div>
                ))}
              </div>
            )}
          </div>
        )}
        {updateState === "done" && (
          <div className="flex items-center justify-between px-4 py-2 text-xs bg-green-500/10 border-b border-green-500/25 shrink-0">
            <span className="text-green-700 dark:text-green-400">
              Analysis image updated successfully.
            </span>
            <button
              onClick={() => setUpdateState("dismissed")}
              className="px-2 py-1 rounded text-green-700 dark:text-green-400 hover:bg-green-500/20 transition-colors"
            >
              Dismiss
            </button>
          </div>
        )}

        {currentPage === "setup" && <SetupPage />}
        {currentPage === "results" && <ResultsPage />}
        {currentPage === "settings" && <SettingsPage />}
      </main>
    </div>
  );
}

export default App;
