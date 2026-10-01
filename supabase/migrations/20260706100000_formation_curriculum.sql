-- Curriculum riche des formations (modules → chapitres, quiz, cas, projets, glossaire,
-- FAQ, plan de démonstration, analyse). Le champ `content` conserve la vue "leçons" à
-- plat pour la compat vidéo/UI ; `curriculum` porte la structure professionnelle complète.
ALTER TABLE public.formations ADD COLUMN IF NOT EXISTS curriculum JSONB;
