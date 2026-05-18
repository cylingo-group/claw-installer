import { useEffect } from "react";
import { Sidebar } from "@/components/installer/Sidebar";
import { UninstallDialog } from "@/components/installer/UninstallDialog";
import { SettingsPanel } from "@/components/installer/SettingsPanel";
import { useInstaller } from "@/store/installer-store";

export default function App() {
  const bootstrap = useInstaller((s) => s.bootstrap);

  useEffect(() => {
    bootstrap();
  }, [bootstrap]);

  return (
    <div className="grid h-dvh w-full place-items-start bg-surface text-foreground">
      <div className="relative h-dvh w-[280px] overflow-hidden bg-surface">
        <Sidebar />
        <SettingsPanel />
        <UninstallDialog />
      </div>
    </div>
  );
}
