import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { useQuery } from "@tanstack/react-query";
import DashboardLayout from "@/components/DashboardLayout";
import ErrorState from "@/components/ErrorState";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { Video, Play, Sparkles, ArrowRight } from "lucide-react";
import { supabase } from "@/integrations/supabase/client";
import { useAuth } from "@/hooks/useAuth";
import { useCommandPrefill } from "@/hooks/useCommandPrefill";
import { safeMediaUrl } from "@/lib/api";

async function fetchVideos() {
  const { data, error } = await supabase
    .from("formations")
    .select("id, title, video_url, updated_at")
    .not("video_url", "is", null)
    .order("updated_at", { ascending: false });
  if (error) throw new Error(error.message);
  return data ?? [];
}

const VideoPage = () => {
  const { user } = useAuth();
  const navigate = useNavigate();
  // Demande transmise par la barre de commande (capacité formation_video).
  const [request, setRequest] = useState("");
  useCommandPrefill(setRequest);

  const videos = useQuery({
    queryKey: ["formation-videos", user?.id],
    queryFn: fetchVideos,
    enabled: !!user?.id,
    retry: 1,
  });

  // La vidéo est produite à partir d'une formation : on transmet la demande à la page Formations.
  const createFormation = () => {
    if (!request.trim()) return;
    navigate("/formations", { state: { commandPrompt: request.trim() } });
  };

  return (
    <DashboardLayout>
      <div className="space-y-6 px-4 py-6 md:px-8 md:py-8">
        <h1 className="text-3xl font-bold">Vidéos</h1>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Sparkles className="h-5 w-5" /> Nouvelle vidéo de formation
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-3">
            <p className="text-sm text-muted-foreground">
              Une vidéo est produite à partir d'une formation (diapositives + narration). Décrivez le sujet :
              la formation sera créée, puis vous pourrez lancer la production de sa vidéo.
            </p>
            <Textarea
              value={request}
              onChange={(e) => setRequest(e.target.value)}
              placeholder="Ex : Vidéo de formation sur les bases de Python"
              rows={3}
              aria-label="Sujet de la vidéo"
            />
            <Button onClick={createFormation} disabled={!request.trim()} className="gap-1.5">
              Créer la formation <ArrowRight className="h-4 w-4" />
            </Button>
          </CardContent>
        </Card>

        <Card>
          <CardHeader>
            <CardTitle className="flex items-center gap-2">
              <Play className="h-5 w-5" /> Mes vidéos de formation
            </CardTitle>
          </CardHeader>
          <CardContent>
            {videos.isPending ? (
              <p className="text-sm text-muted-foreground">Chargement…</p>
            ) : videos.isError ? (
              <ErrorState
                compact
                message="Impossible de charger les vidéos."
                detail={videos.error instanceof Error ? videos.error.message : undefined}
                onRetry={() => videos.refetch()}
              />
            ) : videos.data.length === 0 ? (
              <p className="text-sm text-muted-foreground">
                Aucune vidéo pour le moment. Produisez-en une depuis la page Formations.
              </p>
            ) : (
              <ul className="space-y-2">
                {videos.data.map((v) => {
                  const href = safeMediaUrl(v.video_url);
                  return (
                    <li key={v.id} className="flex items-center gap-2 text-sm">
                      <Video className="h-4 w-4 text-primary flex-shrink-0" />
                      {href ? (
                        <a href={href} target="_blank" rel="noopener noreferrer" className="hover:underline truncate">
                          {v.title}
                        </a>
                      ) : (
                        <span className="truncate">{v.title}</span>
                      )}
                    </li>
                  );
                })}
              </ul>
            )}
          </CardContent>
        </Card>
      </div>
    </DashboardLayout>
  );
};

export default VideoPage;
