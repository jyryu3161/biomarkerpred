// Mock @tauri-apps/api for vitest
export function invoke(_cmd: string, _args?: Record<string, unknown>) {
  return Promise.resolve(null);
}

export function listen(_event: string, _handler: (...args: unknown[]) => void) {
  return Promise.resolve(() => {});
}

// Mock @tauri-apps/api/app
export function getVersion() {
  return Promise.resolve("0.3.0");
}

export function getName() {
  return Promise.resolve("RESPRED");
}
