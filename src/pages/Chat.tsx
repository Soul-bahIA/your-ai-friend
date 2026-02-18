import DashboardLayout from "@/components/DashboardLayout";
import AiChat from "@/components/AiChat";

const Chat = () => (
  <DashboardLayout>
    <div className="px-8 py-8">
      <div className="mb-6 opacity-0 animate-fade-in">
        <h1 className="text-3xl font-bold tracking-tight">
          Chat <span className="text-gradient-primary">IA</span>
        </h1>
        <p className="text-sm text-muted-foreground mt-1">
          Discutez avec SOULBAH IA — posez des questions, planifiez vos projets
        </p>
      </div>
      <AiChat />
    </div>
  </DashboardLayout>
);

export default Chat;
