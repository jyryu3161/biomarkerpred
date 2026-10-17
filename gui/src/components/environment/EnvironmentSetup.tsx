import { useEffect, useRef } from "react";
import { listen } from "@tauri-apps/api/event";
import { useConfigStore } from "@/stores/configStore";
import { pullDockerImage, cancelSetup } from "@/lib/tauri/commands";

import { dockerMessages, refreshEnvironment } from "@/lib/environment";

export function EnvironmentSetup() {
  const envStatus = useConfigStore((s) => s.envStatus);
  const envChecking = useConfigStore((s) => s.envChecking);
  const setupStatus = useConfigStore((s) => s.setupStatus);
  const setupLogs = useConfigStore((s) => s.setupLogs);
  const setupError = useConfigStore((s) => s.setupError);
  const envCheckError = useConfigStore((s) => s.envCheckError);
  const setSetupStatus = useConfigStore((s) => s.setSetupStatus);
  const appendSetupLog = useConfigStore((s) => s.appendSetupLog);
  const clearSetupLogs = useConfigStore((s) => s.clearSetupLogs);
  const setSetupError = useConfigStore((s) => s.setSetupError);

  const logEndRef = useRef<HTMLDivElement>(null);

  // Auto-scroll log
  useEffect(() => {
    logEndRef.current?.scrollIntoView({ behavior: "smooth" });
  }, [setupLogs]);

  // Listen for setup events
  useEffect(() => {
    const unlisten: (() => void)[] = [];

    listen<string>("setup://log", (event) => {
      appendSetupLog(event.payload);
    }).then((u) => unlisten.push(u));

    listen<{ success: boolean }>("setup://complete", (event) => {
      if (event.payload.success) {
        setSetupStatus("completed");
        void refreshEnvironment();
      } else {
        setSetupStatus("failed");
      }
    }).then((u) => unlisten.push(u));

    return () => {
      unlisten.forEach((u) => u());
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Initial env check
  useEffect(() => {
    void refreshEnvironment();
  }, []);

  const handlePullImage = async () => {
    clearSetupLogs();
    setSetupStatus("installing");
    setSetupError("");
    try {
      await pullDockerImage();
    } catch (e: unknown) {
      setSetupStatus("failed");
      const msg = typeof e === "string" ? e : (e as Error)?.message ?? "Unknown error";
      setSetupError(msg);
      appendSetupLog(`Error: ${msg}`);
    }
  };

  const handleCancel = async () => {
    try {
      await cancelSetup();
      setSetupStatus("cancelled");
      appendSetupLog("Cancelled by user.");
    } catch (e) {
      console.error("Cancel failed:", e);
    }
  };

  const isPulling = setupStatus === "installing";
  const dockerOk = envStatus?.dockerStatus === "ready";
  const messages = envStatus ? dockerMessages[envStatus.dockerStatus] : null;

  return (
    <div className="flex-1 flex items-center justify-center p-8 bg-background">
      <div className="w-full max-w-lg space-y-6">
        {/* Header */}
        <div className="text-center space-y-2">
          <h1 className="text-2xl font-bold tracking-tight">BioMarkerPred</h1>
          <p className="text-sm text-muted-foreground">
            Biomarker Prediction Platform
          </p>
        </div>

        {/* Docker Status */}
        <section className="border border-border rounded-lg p-4 space-y-3">
          <div className="flex items-center justify-between">
            <h2 className="text-sm font-medium">Docker Status</h2>
            <button
              onClick={refreshEnvironment}
              disabled={envChecking}
              className="text-xs text-muted-foreground hover:text-foreground transition-colors disabled:opacity-50"
            >
              {envChecking ? "Checking..." : "Refresh"}
            </button>
          </div>

          {envChecking && !envStatus && (
            <p className="text-xs text-muted-foreground">Checking Docker...</p>
          )}

          {envStatus && messages && (
            <div className="space-y-2 text-xs">
              <div className="flex items-center gap-2">
                <span className={envStatus.dockerAvailable ? "text-green-600" : "text-destructive"}>
                  {envStatus.dockerAvailable ? "\u2713" : "\u2717"}
                </span>
                <span>Docker: {messages.engine}</span>
              </div>
              <div className="flex items-center gap-2">
                <span className={dockerOk ? "text-green-600" : "text-muted-foreground"}>
                  {dockerOk ? "\u2713" : "\u2717"}
                </span>
                <span>Analysis Image: {messages.image}</span>
              </div>
              {messages.help && <p className="text-muted-foreground">{messages.help}</p>}
              {envStatus.dockerError && (
                <pre className="text-destructive whitespace-pre-wrap break-all">{envStatus.dockerError}</pre>
              )}
            </div>
          )}
          {envCheckError && <p className="text-xs text-destructive">Environment check failed: {envCheckError}</p>}
        </section>

        {/* Docker executable missing */}
        {envStatus?.dockerStatus === "cli_missing" && (
          <section className="border border-amber-500/30 bg-amber-500/5 rounded-lg p-4 space-y-3">
            <h3 className="text-sm font-medium">Docker Desktop Required</h3>
            <a
              href="https://www.docker.com/products/docker-desktop/"
              target="_blank"
              rel="noopener noreferrer"
              className="inline-block px-4 py-2 text-xs font-medium bg-primary text-primary-foreground rounded-lg hover:bg-primary/90 transition-colors"
            >
              Download Docker Desktop
            </a>
          </section>
        )}

        {/* Download is offered only after a Linux engine reports the image missing. */}
        {envStatus?.dockerStatus === "image_missing" && !envChecking && !isPulling && (
          <section className="space-y-3">
            <button
              onClick={handlePullImage}
              className="w-full py-2.5 text-sm font-medium bg-primary text-primary-foreground rounded-lg hover:bg-primary/90 transition-colors"
            >
              Download Analysis Image
            </button>
            <p className="text-xs text-center text-muted-foreground">
              Downloads the BioMarkerPred analysis engine (~1-2 GB, one-time)
            </p>
          </section>
        )}

        {/* Cancel button during pull */}
        {isPulling && (
          <button
            onClick={handleCancel}
            className="w-full py-2.5 text-sm font-medium bg-destructive text-destructive-foreground rounded-lg hover:bg-destructive/90 transition-colors"
          >
            Cancel Download
          </button>
        )}

        {/* Completed */}
        {dockerOk && !envChecking && setupStatus !== "idle" && (
          <div className="border border-green-500/30 bg-green-500/5 rounded-lg p-3 text-center">
            <p className="text-sm text-green-600 font-medium">
              Ready! Starting BioMarkerPred...
            </p>
          </div>
        )}

        {/* Error */}
        {setupError && (
          <div className="border border-destructive/30 bg-destructive/5 rounded-lg p-3">
            <p className="text-xs text-destructive">{setupError}</p>
          </div>
        )}

        {/* Pull log */}
        {setupLogs.length > 0 && (
          <section className="border border-border rounded-lg overflow-hidden">
            <div className="max-h-48 overflow-y-auto p-3 bg-muted/10">
              {setupLogs.map((line, i) => (
                <p key={i} className="text-[11px] font-mono text-muted-foreground leading-relaxed">
                  {line}
                </p>
              ))}
              <div ref={logEndRef} />
            </div>
          </section>
        )}
      </div>
    </div>
  );
}
