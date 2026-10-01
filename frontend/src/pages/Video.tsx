import DashboardLayout from "@/components/DashboardLayout";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Video, Play } from "lucide-react";

const VideoPage = () => {
  return (
    <DashboardLayout>
      <div className="space-y-6">
        <h1 className="text-3xl font-bold">Vidéos</h1>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Play className="h-5 w-5" /> Mes vidéos de formation
            </CardTitle>
          </CardHeader>
          <CardContent>
            <p className="text-sm text-muted-foreground">
              Aucune vidéo disponible pour le moment. Les vidéos de vos formations apparaîtront ici.
            </p>
          </CardContent>
        </Card>
      </div>
    </DashboardLayout>
  );
};

export default VideoPage;
