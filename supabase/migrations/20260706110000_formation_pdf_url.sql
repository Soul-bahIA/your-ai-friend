-- URL du support PDF produit pour une formation (servi statiquement sous /media).
ALTER TABLE public.formations ADD COLUMN IF NOT EXISTS pdf_url TEXT;
