import { checkEnv } from "@/lib/tauri/commands";
import { useConfigStore } from "@/stores/configStore";
import type { DockerStatus } from "@/types/analysis";

// Shared across startup, setup and settings, including requests still in flight
// after a component unmounts. Only the newest request may change global state.
let latestRequest = 0;

export async function refreshEnvironment(): Promise<void> {
  const request = ++latestRequest;
  useConfigStore.setState({ envChecking: true, envCheckError: null });
  try {
    const status = await checkEnv();
    if (request !== latestRequest) return;
    useConfigStore.setState({
      envStatus: status,
      runtime: { rPath: status.rPath, pixiPath: status.pixiPath, rVersion: status.rVersion },
      runtimeChecked: true,
    });
  } catch (error) {
    if (request !== latestRequest) return;
    useConfigStore.setState({
      envStatus: null,
      envCheckError: typeof error === "string" ? error : String(error),
    });
  } finally {
    if (request === latestRequest) useConfigStore.setState({ envChecking: false });
  }
}

export const dockerMessages: Record<DockerStatus, { engine: string; image: string; help: string }> = {
  cli_missing: {
    engine: "Docker executable not found",
    image: "Not checked",
    help: "Install Docker Desktop, launch it, then refresh the status.",
  },
  engine_unreachable: {
    engine: "Engine connection failed",
    image: "Not checked",
    help: "Start Docker Desktop and check the active Docker context, then refresh the status.",
  },
  windows_containers: {
    engine: "Windows containers mode",
    image: "Not checked",
    help: "Switch Docker Desktop to Linux containers, then refresh the status.",
  },
  engine_check_failed: {
    engine: "Container mode could not be verified",
    image: "Not checked",
    help: "Check the Docker engine's container mode and refresh the status.",
  },
  image_missing: {
    engine: "Linux engine connected",
    image: "Not downloaded",
    help: "Download the analysis image to run analyses.",
  },
  image_inspect_failed: {
    engine: "Linux engine connected",
    image: "Image check failed",
    help: "Check the Docker error below, then refresh the status.",
  },
  ready: {
    engine: "Linux engine connected",
    image: "Ready (jyryu3161/biomarkerpred:v0.4.3)",
    help: "",
  },
};
