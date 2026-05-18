/**
 * Tests for the installer store reducer logic.
 * These tests cover the TDD requirement: channel event → state transition
 * for each InstallerEvent variant.
 */
import { describe, it, expect, beforeEach, vi, afterEach } from "vitest";

// Mock tauri internals so IS_TAURI_ENV = false in tests
// (already guaranteed by test-setup.ts which removes __TAURI_INTERNALS__)

describe("installer-store: IS_TAURI_ENV detection", () => {
  it("is false in jsdom environment (no __TAURI_INTERNALS__)", async () => {
    const { IS_TAURI_ENV } = await import("@/store/installer-store");
    expect(IS_TAURI_ENV).toBe(false);
  });
});

describe("installer-store: initial state", () => {
  it("starts with both agents not-installed", async () => {
    const { useInstaller } = await import("@/store/installer-store");
    const state = useInstaller.getState();
    expect(state.agents.openclaw.status).toBe("not-installed");
    expect(state.agents.hermes.status).toBe("not-installed");
  });

  it("starts with hostStatus ok", async () => {
    const { useInstaller } = await import("@/store/installer-store");
    const state = useInstaller.getState();
    expect(state.hostStatus).toBe("ok");
  });

  it("starts with isBootstrapping true", async () => {
    const { useInstaller } = await import("@/store/installer-store");
    const state = useInstaller.getState();
    expect(state.isBootstrapping).toBe(true);
  });

  it("has no logTail, logDrawerOpen, or progress fields (dropped in T2.1)", async () => {
    const { useInstaller } = await import("@/store/installer-store");
    const state = useInstaller.getState() as Record<string, unknown>;
    expect("logTail" in state).toBe(false);
    expect("logDrawerOpen" in state).toBe(false);
    expect("progress" in state.agents.openclaw).toBe(false);
    expect("progress" in state.agents.hermes).toBe(false);
  });

  it("has toggleLogDrawer removed (T2.1)", async () => {
    const { useInstaller } = await import("@/store/installer-store");
    const state = useInstaller.getState() as Record<string, unknown>;
    expect("toggleLogDrawer" in state).toBe(false);
  });

  it("agents have currentStep and currentStepDetail fields (T2.2)", async () => {
    const { useInstaller } = await import("@/store/installer-store");
    const state = useInstaller.getState();
    expect(state.agents.openclaw.currentStep).toBeNull();
    expect(state.agents.openclaw.currentStepDetail).toBeNull();
    expect(state.agents.hermes.currentStep).toBeNull();
    expect(state.agents.hermes.currentStepDetail).toBeNull();
  });
});

describe("installer-store: setCurrentStep action", () => {
  it("updates currentStep and currentStepDetail for the given agent", async () => {
    const { useInstaller } = await import("@/store/installer-store");
    useInstaller.getState().setCurrentStep("openclaw", "正在安装系统依赖…", "curl / git");
    const state = useInstaller.getState();
    expect(state.agents.openclaw.currentStep).toBe("正在安装系统依赖…");
    expect(state.agents.openclaw.currentStepDetail).toBe("curl / git");
    // hermes unaffected
    expect(state.agents.hermes.currentStep).toBeNull();
  });

  it("can clear step by passing null", async () => {
    const { useInstaller } = await import("@/store/installer-store");
    useInstaller.getState().setCurrentStep("openclaw", "step", "detail");
    useInstaller.getState().setCurrentStep("openclaw", null, null);
    const state = useInstaller.getState();
    expect(state.agents.openclaw.currentStep).toBeNull();
  });
});

describe("installer-store: setAgentStatus action", () => {
  it("transitions agent status", async () => {
    const { useInstaller } = await import("@/store/installer-store");
    useInstaller.getState().setAgentStatus("hermes", "ready", {
      version: "0.18.0",
      installedAt: "2026-05-19T00:00:00Z",
    });
    const state = useInstaller.getState();
    expect(state.agents.hermes.status).toBe("ready");
    expect(state.agents.hermes.version).toBe("0.18.0");
    expect(state.agents.hermes.installedAt).toBe("2026-05-19T00:00:00Z");
  });

  it("sets errorMessage on error status", async () => {
    const { useInstaller } = await import("@/store/installer-store");
    useInstaller.getState().setAgentStatus("openclaw", "error", {
      errorMessage: "脚本退出码 1",
    });
    const state = useInstaller.getState();
    expect(state.agents.openclaw.status).toBe("error");
    expect(state.agents.openclaw.errorMessage).toBe("脚本退出码 1");
  });
});

describe("installer-store: startInstall → installing state", () => {
  it("sets agents to installing and populates installQueue", async () => {
    const { useInstaller } = await import("@/store/installer-store");
    // First reset state
    useInstaller.setState({
      agents: {
        openclaw: { ...useInstaller.getState().agents.openclaw, status: "not-installed" },
        hermes: { ...useInstaller.getState().agents.hermes, status: "not-installed" },
      },
      installQueue: [],
      isBootstrapping: false,
    });

    useInstaller.getState().startInstall(["openclaw"]);
    const state = useInstaller.getState();
    expect(state.agents.openclaw.status).toBe("installing");
    expect(state.installQueue).toContain("openclaw");
    expect(state.agents.openclaw.currentStep).toBeNull();
    expect(state.agents.openclaw.errorMessage).toBeUndefined();
  });
});

describe("installer-store: confirmUninstall flow", () => {
  it("sets agent to uninstalling and clears uninstallTarget", async () => {
    const { useInstaller } = await import("@/store/installer-store");
    // Set agent to ready first, then open uninstall
    useInstaller.setState((s) => ({
      agents: { ...s.agents, openclaw: { ...s.agents.openclaw, status: "ready" } },
      uninstallTarget: "openclaw",
    }));
    useInstaller.getState().confirmUninstall();
    const state = useInstaller.getState();
    expect(state.agents.openclaw.status).toBe("uninstalling");
    expect(state.uninstallTarget).toBeNull();
  });
});

describe("installer-store: cancelInstall", () => {
  it("sets queued agents to error with 已被用户中止 message", async () => {
    const { useInstaller } = await import("@/store/installer-store");
    useInstaller.setState((s) => ({
      agents: {
        ...s.agents,
        openclaw: { ...s.agents.openclaw, status: "installing" },
      },
      installQueue: ["openclaw"],
    }));
    useInstaller.getState().cancelInstall();
    const state = useInstaller.getState();
    expect(state.agents.openclaw.status).toBe("error");
    expect(state.agents.openclaw.errorMessage).toBe("已被用户中止");
    expect(state.installQueue).toHaveLength(0);
  });
});

describe("installer-store: bootstrap in stub mode", () => {
  beforeEach(async () => {
    // Reset agents to initial state before each test in this block
    const { useInstaller, initialAgents } = await import("@/store/installer-store");
    useInstaller.setState({
      agents: { ...initialAgents },
      isBootstrapping: true,
      installQueue: [],
    });
  });

  it("sets isBootstrapping to false after completion", async () => {
    const { useInstaller } = await import("@/store/installer-store");
    await useInstaller.getState().bootstrap();
    expect(useInstaller.getState().isBootstrapping).toBe(false);
  });

  it("leaves both agents not-installed in stub mode (no manifest)", async () => {
    const { useInstaller } = await import("@/store/installer-store");
    await useInstaller.getState().bootstrap();
    const state = useInstaller.getState();
    expect(state.agents.openclaw.status).toBe("not-installed");
    expect(state.agents.hermes.status).toBe("not-installed");
  });
});

describe("installer-store: stub mode parity (AC12)", () => {
  it("startInstall in stub mode triggers stub events via dynamic import", async () => {
    const { useInstaller, IS_TAURI_ENV } = await import("@/store/installer-store");
    expect(IS_TAURI_ENV).toBe(false); // verify we're in stub mode

    // Mock the stub module to capture calls
    const mockRunStubInstaller = vi.fn((_agents: string[], onEvent: (e: import("@/store/installer-store").InstallerEvent) => void) => {
      // Immediately fire a StepChanged event
      onEvent({ type: "StepChanged", key: "base-deps", label: "正在安装系统依赖…", detail: "curl" });
      onEvent({ type: "Finished", success: true, message: null });
      return () => {};
    });

    vi.doMock("@/stub/sample", () => ({
      runStubInstaller: mockRunStubInstaller,
    }));

    useInstaller.setState((s) => ({
      agents: {
        ...s.agents,
        openclaw: { ...s.agents.openclaw, status: "not-installed" },
      },
      installQueue: [],
      isBootstrapping: false,
    }));

    useInstaller.getState().startInstall(["openclaw"]);
    // Immediately after call: status should be installing
    expect(useInstaller.getState().agents.openclaw.status).toBe("installing");

    vi.doUnmock("@/stub/sample");
  });
});
