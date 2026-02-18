import { ReactNode } from "react";
import Sidebar from "./Sidebar";

const DashboardLayout = ({ children }: { children: ReactNode }) => {
  return (
    <div className="min-h-screen bg-background bg-mesh">
      <Sidebar />
      <main className="ml-64 min-h-screen">
        <div className="bg-grid min-h-screen">
          {children}
        </div>
      </main>
    </div>
  );
};

export default DashboardLayout;
