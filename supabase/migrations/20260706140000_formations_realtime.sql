-- Diffusion temps réel des formations (génération asynchrone : la carte se met à jour
-- toute seule quand le statut/contenu change).
DO $$
BEGIN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.formations;
EXCEPTION
  WHEN duplicate_object THEN NULL;
  WHEN undefined_object THEN NULL;
END $$;
