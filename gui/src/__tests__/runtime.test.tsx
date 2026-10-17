import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { beforeEach, expect, it, vi } from "vitest";
import { api } from "@/lib/api";
import type { DockerStatus, EngineResponse, RuntimeSettings } from "@/lib/types";
import { SettingsPage } from "@/pages/SettingsPage";
import { checkRuntime, downloadImage, useWorkspace } from "@/stores/workspace";

const settings: RuntimeSettings = {
  backend: "docker", rPath: null, dockerPath: null,
  dockerImage: "jyryu3161/biomarkerpred:v0.5.0", outputRoot: null,
};
const ready: DockerStatus = {
  state: "ready", executable: "docker", image: settings.dockerImage,
  imageId: `sha256:${"a".repeat(64)}`, serverOs: "linux",
  message: "Docker prerequisites available; doctor is required.", diagnostics: [],
};
const doctor: EngineResponse = {
  success: true, cancelled: false, exitCode: 0,
  result: { ok: true }, verificationError: null, stderrTail: [],
};
beforeEach(() => {
  useWorkspace.setState({ settings, doctor: null, dockerStatus: null,
    downloadingImage: false, checkingRuntime: false, runtimeError: null, initError: null });
  vi.spyOn(api, "saveSettings").mockImplementation(async (value) => value);
  vi.spyOn(api, "dockerStatus").mockResolvedValue(ready);
  vi.spyOn(api, "pull").mockResolvedValue(settings.dockerImage);
  vi.spyOn(api, "call").mockResolvedValue(doctor);
});
it("separates a disconnected Docker Engine from an unverified image without pulling", async () => {
  const raw = "open //./pipe/dockerDesktopLinuxEngine: The system cannot find the file specified.";
  vi.mocked(api.dockerStatus).mockResolvedValue({ ...ready, state: "engine_unreachable", imageId: null,
    message: "Cannot connect to Docker Engine; wait for Docker Desktop's Linux engine.",
    diagnostics: [{ phase: "server", exitCode: 1, stdout: "", stderr: [raw], timedOut: false, error: null }],
  });
  render(<SettingsPage />);
  fireEvent.click(screen.getByRole("button", { name: "Check runtime" }));
  await screen.findByText("Cannot connect");
  expect(screen.getByText("Not checked (Docker Engine required)")).toBeInTheDocument();
  expect(screen.getByText(/dockerDesktopLinuxEngine/)).toBeInTheDocument();
  expect(screen.queryByText("Not downloaded")).not.toBeInTheDocument();
  expect(api.pull).not.toHaveBeenCalled();
  expect(api.call).not.toHaveBeenCalled();
});
it("saves the chosen executable/image before download, then waits for actual doctor success", async () => {
  let finish!: (value: EngineResponse) => void;
  vi.mocked(api.call).mockReturnValue(new Promise((resolve) => { finish = resolve; }));
  render(<SettingsPage />);
  fireEvent.change(screen.getByLabelText("Docker executable"), { target: { value: "C:\\한글 도구\\docker.exe" } });
  fireEvent.change(screen.getByLabelText("Docker image"), { target: { value: "custom/engine:tested" } });
  fireEvent.click(screen.getByRole("button", { name: "Download analysis image" }));
  await waitFor(() => expect(api.call).toHaveBeenCalled());
  const chosen = { ...settings, dockerPath: "C:\\한글 도구\\docker.exe", dockerImage: "custom/engine:tested" };
  expect(api.saveSettings).toHaveBeenCalledWith(chosen);
  expect(api.pull).toHaveBeenCalledWith(chosen);
  expect(api.dockerStatus).toHaveBeenCalledWith(chosen);
  expect(api.call).toHaveBeenCalledWith({ operation: "doctor", settings: chosen });
  expect(vi.mocked(api.saveSettings).mock.invocationCallOrder[0]).toBeLessThan(vi.mocked(api.pull).mock.invocationCallOrder[0]);
  expect(vi.mocked(api.pull).mock.invocationCallOrder[0]).toBeLessThan(vi.mocked(api.call).mock.invocationCallOrder[0]);
  expect(screen.queryByText(/Ready: docker/)).not.toBeInTheDocument();
  await act(async () => finish(doctor));
  await screen.findByText("Ready: docker engine passed doctor.");
  expect(screen.getByText(/Analysis image downloaded; settings saved/)).toBeInTheDocument();
});
it("shows downloading state and never reports readiness when the pull fails", async () => {
  let fail!: (reason: Error) => void;
  vi.mocked(api.pull).mockReturnValue(new Promise((_, reject) => { fail = reject; }));
  render(<SettingsPage />);
  fireEvent.click(screen.getByRole("button", { name: "Download analysis image" }));
  await screen.findByRole("button", { name: "Downloading analysis image…" });
  expect(screen.getByRole("button", { name: "Check runtime" })).toBeDisabled();
  await act(async () => fail(new Error("Registry authentication failed")));
  await waitFor(() => expect(screen.getAllByText("Registry authentication failed").length).toBeGreaterThan(0));
  expect(api.call).not.toHaveBeenCalled();
  expect(screen.queryByText(/Ready: docker/)).not.toBeInTheDocument();
  expect(screen.queryByText(/Analysis image downloaded; settings saved/)).not.toBeInTheDocument();
});
it("does not turn a successful pull with failed doctor into successful setup", async () => {
  vi.mocked(api.call).mockResolvedValue({ ...doctor, success: false, exitCode: 1, result: { error: "Cairo PDF export failed" } });
  render(<SettingsPage />);
  fireEvent.click(screen.getByRole("button", { name: "Download analysis image" }));
  await screen.findByText("Runtime is not ready.");
  expect(screen.getAllByText("Cairo PDF export failed").length).toBeGreaterThan(0);
  expect(screen.queryByText(/Ready: docker/)).not.toBeInTheDocument();
  expect(screen.queryByText(/Analysis image downloaded; settings saved/)).not.toBeInTheDocument();
});
it("keeps downloads exclusive when Settings is unmounted and reopened", async () => {
  let finish!: (value: string) => void;
  vi.mocked(api.pull).mockReturnValue(new Promise((resolve) => { finish = resolve; }));
  const first = render(<SettingsPage />);
  fireEvent.click(screen.getByRole("button", { name: "Download analysis image" }));
  await waitFor(() => expect(api.pull).toHaveBeenCalledTimes(1));
  first.unmount();
  render(<SettingsPage />);
  expect(screen.getByRole("button", { name: "Downloading analysis image…" })).toBeDisabled();
  expect(screen.getByLabelText("Docker executable")).toBeDisabled();
  expect(screen.getByRole("button", { name: "Save settings and check" })).toBeDisabled();
  await expect(downloadImage(settings)).rejects.toThrow("already in progress");
  expect(api.pull).toHaveBeenCalledTimes(1);
  expect(screen.queryByText(/Analysis image downloaded; settings saved/)).not.toBeInTheDocument();
  await act(async () => finish(settings.dockerImage));
  await screen.findByText("Ready: docker engine passed doctor.");
});
it("ignores an older check for the very same settings, including its late finally", async () => {
  let finish!: (value: DockerStatus) => void;
  vi.mocked(api.dockerStatus).mockReturnValueOnce(new Promise((resolve) => { finish = resolve; }));
  const earlier = checkRuntime();
  await checkRuntime();
  finish({ ...ready, state: "engine_unreachable", message: "stale failure" });
  await earlier;
  expect(useWorkspace.getState().doctor?.success).toBe(true);
  expect(useWorkspace.getState().runtimeError).toBeNull();
  expect(useWorkspace.getState().dockerStatus?.state).toBe("ready");
});
it("keeps local R independent of Docker inspection/download", async () => {
  useWorkspace.setState({ settings: { ...settings, backend: "local" } });
  await checkRuntime();
  expect(api.dockerStatus).not.toHaveBeenCalled();
  expect(api.pull).not.toHaveBeenCalled();
  expect(useWorkspace.getState().doctor?.success).toBe(true);
});
it("opens only the dedicated official Docker download action on an explicit click", async () => {
  vi.spyOn(api, "openDockerDownload").mockResolvedValue();
  render(<SettingsPage />);
  expect(api.openDockerDownload).not.toHaveBeenCalled();
  fireEvent.click(screen.getByRole("button", { name: "Open Docker Desktop download page" }));
  await screen.findByText("Opening the official Docker Desktop download page in your browser.");
  expect(api.openDockerDownload).toHaveBeenCalledWith();
  expect(api.pull).not.toHaveBeenCalled();
});
