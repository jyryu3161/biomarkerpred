import { useEffect, useCallback } from "react";
import { useAnalysisStore } from "@/stores/analysisStore";
import { runAnalysis, cancelAnalysis } from "@/lib/tauri/commands";
import {
  onAnalysisProgress,
  onAnalysisComplete,
  onAnalysisLog,
  onAnalysisError,
} from "@/lib/tauri/events";

/**
 * useAnalysisRunner
 *
 * Encapsulates analysis run/cancel logic and Tauri event subscription that
 * was previously inlined in App.tsx and RunActionBar.tsx.
 *
 * The hook subscribes to the four backend events on mount and unsubscribes on
 * unmount.  It also exposes `run()` and `cancel()` callbacks that update the
 * store and call the Tauri IPC commands.
 *
 * Usage:
 *   const { run, cancel } = useAnalysisRunner();
 */
export function useAnalysisRunner() {
  const buildConfig = useAnalysisStore((s) => s.buildConfig);
  const setStatus = useAnalysisStore((s) => s.setStatus);
  const setParam = useAnalysisStore((s) => s.setParam);
  const appendLog = useAnalysisStore((s) => s.appendLog);
  const setProgress = useAnalysisStore((s) => s.setProgress);

  // Subscribe to Tauri backend events
  useEffect(() => {
    const cleanups: (() => void)[] = [];

    onAnalysisProgress((event) => {
      setProgress(event.current, event.total, event.message);
    }).then((unlisten) => cleanups.push(unlisten));

    onAnalysisLog((line) => {
      useAnalysisStore.getState().appendLog(line);
    }).then((unlisten) => cleanups.push(unlisten));

    onAnalysisComplete((payload) => {
      const store = useAnalysisStore.getState();
      if (store.status === "cancelled") {
        store.appendLog(`Analysis cancelled by user (exit code ${payload.code})`);
        return;
      }
      store.appendLog(
        payload.success
          ? `Analysis completed successfully (exit code ${payload.code})`
          : `Analysis finished with exit code ${payload.code}`,
      );
      if (!payload.success) {
        store.setParam(
          "errorMessage",
          `Exit code ${payload.code}. Check Results > Log for details.`,
        );
      }
      store.setStatus(payload.success ? "completed" : "failed");
    }).then((unlisten) => cleanups.push(unlisten));

    onAnalysisError((payload) => {
      const store = useAnalysisStore.getState();
      if (store.status === "cancelled") return;
      store.appendLog(`Error: ${payload.message}`);
      store.setParam("errorMessage", payload.message);
      store.setStatus("failed");
    }).then((unlisten) => cleanups.push(unlisten));

    return () => {
      cleanups.forEach((u) => u());
    };
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  /** Start a new analysis run. Clears previous state then invokes the backend. */
  const run = useCallback(async () => {
    try {
      setParam("errorMessage", "");
      setParam("logs", [] as string[]);
      setParam("progress", { current: 0, total: 0, message: "" });
      useAnalysisStore.getState().setResult(null);
      setStatus("running");
      const config = buildConfig();
      await runAnalysis(config);
    } catch (e) {
      const msg = typeof e === "string" ? e : String(e);
      setParam("errorMessage", msg);
      setStatus("failed");
      console.error("Analysis error:", e);
    }
  }, [buildConfig, setStatus, setParam]);

  /** Cancel the currently running analysis. */
  const cancel = useCallback(async () => {
    try {
      await cancelAnalysis();
      setStatus("cancelled");
    } catch (e) {
      console.error("Cancel error:", e);
    }
  }, [setStatus]);

  return { run, cancel, appendLog, setProgress };
}
