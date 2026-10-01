import { ReactNode, useState } from "react";
import { Menu } from "lucide-react";
import { useLocation } from "react-router-dom";
import { Sheet, SheetContent, SheetTitle } from "@/components/ui/sheet";
import { useIsMobile } from "@/hooks/use-mobile";
import Sidebar from "./Sidebar";
import CommandBar from "./CommandBar";

const DashboardLayout = ({ children }: { children: ReactNode }) => {
  const isMobile = useIsMobile();
  const [open, setOpen] = useState(false);
  const { pathname } = useLocation();
  // Sur /chat, la page a déjà son propre champ de saisie en bas : la barre de
  // commande flottante le recouvrirait.
  const showCommandBar = pathname !== "/chat";
  const bottomPad = showCommandBar ? "pb-28" : "pb-4";

  return (
    <div className="min-h-screen bg-background bg-mesh">
      {isMobile ? (
        <>
          <header className="sticky top-0 z-40 flex items-center gap-3 border-b border-border bg-background/80 backdrop-blur px-4 py-3">
            <button onClick={() => setOpen(true)} className="text-foreground" aria-label="Ouvrir le menu">
              <Menu className="h-5 w-5" />
            </button>
            <span className="text-sm font-bold tracking-tight">SOULBAH IA</span>
          </header>
          <Sheet open={open} onOpenChange={setOpen}>
            <SheetContent side="left" className="w-64 p-0">
              <SheetTitle className="sr-only">Menu</SheetTitle>
              <Sidebar onNavigate={() => setOpen(false)} />
            </SheetContent>
          </Sheet>
          <main className="min-h-[calc(100vh-53px)]">
            <div className={`bg-grid min-h-[calc(100vh-53px)] ${bottomPad}`}>
              {children}
            </div>
          </main>
        </>
      ) : (
        <>
          <Sidebar />
          <main className="ml-64 min-h-screen">
            <div className={`bg-grid min-h-screen ${bottomPad}`}>
              {children}
            </div>
          </main>
        </>
      )}
      {showCommandBar && <CommandBar />}
    </div>
  );
};

export default DashboardLayout;
