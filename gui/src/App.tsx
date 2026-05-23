import { useEffect } from "react";
import { Sidebar } from "@/components/installer/Sidebar";
import { UninstallDialog } from "@/components/installer/UninstallDialog";
import { SettingsPanel } from "@/components/installer/SettingsPanel";
import { AppSettingsPanel } from "@/components/installer/AppSettingsPanel";
import { RebootModal } from "@/components/installer/RebootModal";
import { Titlebar } from "@/components/installer/Titlebar";
import { useInstaller } from "@/store/installer-store";

export default function App() {
  const bootstrap = useInstaller((s) => s.bootstrap);

  useEffect(() => {
    bootstrap();
  }, [bootstrap]);

  return (
    // Rounded macOS-style mask (radius 10px). The OS window is transparent
    // (tauri.conf.json → transparent:true) so anything outside this rounded
    // shape stays unpainted, and macOS draws its native window shadow around
    // the rounded silhouette.
    <div className="relative flex h-dvh w-full flex-col overflow-hidden rounded-[10px] bg-surface text-foreground ring-1 ring-black/10">
      {/* 7.1 — Titlebar is the first child, spanning full width */}
      <Titlebar />
      {/* Existing horizontal layout: Sidebar + panels fill remaining height */}
      <div className="relative flex flex-1 overflow-hidden">
        <Sidebar />
        <SettingsPanel />
        <AppSettingsPanel />
        <UninstallDialog />
        <RebootModal />
      </div>
    </div>
  );
}
