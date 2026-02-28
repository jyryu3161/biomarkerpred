import { useState, useEffect } from "react";
import { getVersion } from "@tauri-apps/api/app";
import { useConfigStore } from "@/stores/configStore";
import { checkEnv, pullDockerImage } from "@/lib/tauri/commands";

export function SettingsPage() {
  const envStatus = useConfigStore((s) => s.envStatus);
  const setEnvStatus = useConfigStore((s) => s.setEnvStatus);
  const [version, setVersion] = useState<string>("");
  useEffect(() => {
    getVersion().then(setVersion).catch(() => setVersion(""));
  }, []);

  const [dockerPulling, setDockerPulling] = useState(false);

  const handleRefreshEnv = async () => {
    try {
      const status = await checkEnv();
      setEnvStatus(status);
    } catch (e) {
      console.error("Env check failed:", e);
    }
  };

  const handlePullDocker = async () => {
    setDockerPulling(true);
    try {
      await pullDockerImage();
      await handleRefreshEnv();
    } catch (e) {
      console.error("Docker pull failed:", e);
    } finally {
      setDockerPulling(false);
    }
  };

  return (
    <div className="flex-1 overflow-y-auto p-6 space-y-6">
      <h2 className="text-lg font-semibold">Settings</h2>

      {/* Docker Status */}
      <section className="border border-border rounded-lg p-4 space-y-3">
        <div className="flex items-center justify-between">
          <h3 className="text-sm font-medium">Docker</h3>
          <button
            onClick={handleRefreshEnv}
            className="px-3 py-1.5 text-xs bg-secondary text-secondary-foreground rounded-md hover:bg-secondary/80 transition-colors"
          >
            Refresh Status
          </button>
        </div>

        {envStatus && (
          <div className="space-y-2 text-sm">
            <div className="flex justify-between">
              <span className="text-muted-foreground">Docker Desktop:</span>
              <span className={envStatus.dockerAvailable ? "text-green-600 text-xs" : "text-destructive text-xs"}>
                {envStatus.dockerAvailable ? "Running" : "Not running"}
              </span>
            </div>
            <div className="flex justify-between">
              <span className="text-muted-foreground">Analysis Image:</span>
              <span className={envStatus.dockerImagePresent ? "text-green-600 text-xs" : "text-muted-foreground text-xs"}>
                {envStatus.dockerImagePresent ? "Ready (jyryu3161/respred)" : "Not downloaded"}
              </span>
            </div>
          </div>
        )}

        {envStatus?.dockerAvailable && !envStatus.dockerImagePresent && (
          <button
            onClick={handlePullDocker}
            disabled={dockerPulling}
            className="px-3 py-1.5 text-xs bg-primary text-primary-foreground rounded-md hover:bg-primary/90 transition-colors disabled:opacity-50"
          >
            {dockerPulling ? "Downloading..." : "Download Analysis Image"}
          </button>
        )}

        {envStatus?.dockerAvailable && envStatus.dockerImagePresent && (
          <button
            onClick={handlePullDocker}
            disabled={dockerPulling}
            className="px-3 py-1.5 text-xs bg-secondary text-secondary-foreground rounded-md hover:bg-secondary/80 transition-colors disabled:opacity-50"
          >
            {dockerPulling ? "Updating..." : "Update Image"}
          </button>
        )}
      </section>

      <section className="border border-border rounded-lg p-4 space-y-3">
        <h3 className="text-sm font-medium">About</h3>
        <div className="text-sm text-muted-foreground space-y-1">
          <p>RESPRED{version ? ` v${version}` : ""}</p>
          <p>Drug Response Biomarker Prediction Platform</p>
          <p>Cross-platform desktop application powered by Tauri + Docker</p>
        </div>
      </section>
    </div>
  );
}
