import { useEffect, useRef } from "react";
import { listen } from "@tauri-apps/api/event";
import { useConfigStore } from "@/stores/configStore";
import { checkEnv, pullDockerImage, cancelSetup } from "@/lib/tauri/commands";

export function EnvironmentSetup() {
  const envStatus = useConfigStore((s) => s.envStatus);
  const envChecking = useConfigStore((s) => s.envChecking);
  const setupStatus = useConfigStore((s) => s.setupStatus);
  const setupLogs = useConfigStore((s) => s.setupLogs);
  const setupError = useConfigStore((s) => s.setupError);
  const setEnvStatus = useConfigStore((s) => s.setEnvStatus);
  const setEnvChecking = useConfigStore((s) => s.setEnvChecking);
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
        handleCheckEnv();
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
    handleCheckEnv();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const handleCheckEnv = async () => {
    setEnvChecking(true);
    try {
      const status = await checkEnv();
      setEnvStatus(status);
    } catch (e) {
      console.error("Env check failed:", e);
    } finally {
      setEnvChecking(false);
    }
  };

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
  const dockerOk = envStatus?.dockerAvailable && envStatus?.dockerImagePresent;

  return (
    <div className="flex-1 flex items-center justify-center p-8 bg-background">
      <div className="w-full max-w-lg space-y-6">
        {/* Header */}
        <div className="text-center space-y-2">
          <h1 className="text-2xl font-bold tracking-tight">RESPRED</h1>
          <p className="text-sm text-muted-foreground">
            Drug Response Biomarker Prediction Platform
          </p>
        </div>

        {/* Docker Status */}
        <section className="border border-border rounded-lg p-4 space-y-3">
          <div className="flex items-center justify-between">
            <h2 className="text-sm font-medium">Docker Status</h2>
            <button
              onClick={handleCheckEnv}
              disabled={envChecking}
              className="text-xs text-muted-foreground hover:text-foreground transition-colors disabled:opacity-50"
            >
              {envChecking ? "Checking..." : "Refresh"}
            </button>
          </div>

          {envChecking && !envStatus && (
            <p className="text-xs text-muted-foreground">Checking Docker...</p>
          )}

          {envStatus && (
            <div className="space-y-2 text-xs">
              <div className="flex items-center gap-2">
                <span className={envStatus.dockerAvailable ? "text-green-600" : "text-destructive"}>
                  {envStatus.dockerAvailable ? "\u2713" : "\u2717"}
                </span>
                <span>Docker Desktop</span>
                {!envStatus.dockerAvailable && (
                  <span className="text-muted-foreground">- Not running</span>
                )}
              </div>
              <div className="flex items-center gap-2">
                <span className={envStatus.dockerImagePresent ? "text-green-600" : "text-muted-foreground"}>
                  {envStatus.dockerImagePresent ? "\u2713" : "\u2717"}
                </span>
                <span>Analysis Image</span>
                {envStatus.dockerAvailable && !envStatus.dockerImagePresent && (
                  <span className="text-muted-foreground">- Not downloaded</span>
                )}
              </div>
            </div>
          )}
        </section>

        {/* Docker not installed */}
        {envStatus && !envStatus.dockerAvailable && (
          <section className="border border-amber-500/30 bg-amber-500/5 rounded-lg p-4 space-y-3">
            <h3 className="text-sm font-medium">Docker Desktop Required</h3>
            <p className="text-xs text-muted-foreground">
              RESPRED uses Docker to run analyses. Please install Docker Desktop and make sure it is running.
            </p>
            <a
              href="https://www.docker.com/products/docker-desktop/"
              target="_blank"
              rel="noopener noreferrer"
              className="inline-block px-4 py-2 text-xs font-medium bg-primary text-primary-foreground rounded-lg hover:bg-primary/90 transition-colors"
            >
              Download Docker Desktop
            </a>
            <p className="text-[11px] text-muted-foreground">
              After installing, launch Docker Desktop and click "Refresh" above.
            </p>
          </section>
        )}

        {/* Docker available but image not pulled */}
        {envStatus?.dockerAvailable && !envStatus.dockerImagePresent && !isPulling && setupStatus !== "completed" && (
          <section className="space-y-3">
            <button
              onClick={handlePullImage}
              className="w-full py-2.5 text-sm font-medium bg-primary text-primary-foreground rounded-lg hover:bg-primary/90 transition-colors"
            >
              Download Analysis Image
            </button>
            <p className="text-xs text-center text-muted-foreground">
              Downloads the RESPRED analysis engine (~1-2 GB, one-time)
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
        {(setupStatus === "completed" || dockerOk) && setupStatus !== "idle" && (
          <div className="border border-green-500/30 bg-green-500/5 rounded-lg p-3 text-center">
            <p className="text-sm text-green-600 font-medium">
              Ready! Starting RESPRED...
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
