import { ReactNode, useState } from "react";
import { Menu } from "lucide-react";
import { Sheet, SheetContent, SheetTitle } from "@/components/ui/sheet";
import { useIsMobile } from "@/hooks/use-mobile";
import Sidebar from "./Sidebar";

const DashboardLayout = ({ children }: { children: ReactNode }) => {
  const isMobile = useIsMobile();
  const [open, setOpen] = useState(false);

  return (
    <div className="min-h-screen bg-background bg-mesh">
      {isMobile ? (
        <>
          <header className="sticky top-0 z-40 flex items-center gap-3 border-b border-border bg-background/80 backdrop-blur px-4 py-3">
            <button onClick={() => setOpen(true)} className="text-foreground">
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
            <div className="bg-grid min-h-[calc(100vh-53px)]">
              {children}
            </div>
          </main>
        </>
      ) : (
        <>
          <Sidebar />
          <main className="ml-64 min-h-screen">
            <div className="bg-grid min-h-screen">
              {children}
            </div>
          </main>
        </>
      )}
    </div>
  );
};

export default DashboardLayout;
