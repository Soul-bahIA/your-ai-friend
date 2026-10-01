# --- Build ---
FROM node:20-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm install
COPY . .
# L'URL de l'API est injectée au build (Vite fige les variables à la compilation).
ARG VITE_API_URL=http://localhost:3000
ARG VITE_SUPABASE_URL=
ARG VITE_SUPABASE_KEY=
ENV VITE_API_URL=$VITE_API_URL
ENV VITE_SUPABASE_URL=$VITE_SUPABASE_URL
ENV VITE_SUPABASE_KEY=$VITE_SUPABASE_KEY
RUN npm run build

# --- Serve (nginx statique) ---
FROM nginx:alpine
COPY --from=builder /app/dist /usr/share/nginx/html
EXPOSE 80
