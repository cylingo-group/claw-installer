import { useEffect } from "react";
import { Sidebar } from "@/components/installer/Sidebar";
import { UninstallDialog } from "@/components/installer/UninstallDialog";
import { SettingsPanel } from "@/components/installer/SettingsPanel";
import { AppSettingsPanel } from "@/components/installer/AppSettingsPanel";
import { RebootModal } from "@/components/installer/RebootModal";
import { useInstaller } from "@/store/installer-store";

export default function App() {
  const bootstrap = useInstaller((s) => s.bootstrap);

  useEffect(() => {
    bootstrap();
  }, [bootstrap]);

  return (
    <div className="relative flex h-dvh w-full overflow-hidden bg-surface text-foreground">
      <Sidebar />
      <SettingsPanel />
      <AppSettingsPanel />
      <UninstallDialog />
      <RebootModal />
    </div>
  );
}
