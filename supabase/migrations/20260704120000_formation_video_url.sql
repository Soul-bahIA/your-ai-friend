-- URL de la vidéo MP4 produite pour une formation (narration + diapos + montage).
ALTER TABLE public.formations ADD COLUMN IF NOT EXISTS video_url TEXT;
