# --- Étape 1 : compilation TypeScript → dist/ (T49 : plus de tsx en production) ---
FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN npm run build

# --- Étape 2 : image d'exécution (dépendances de prod + JS compilé uniquement) ---
FROM node:22-alpine
WORKDIR /app
ENV NODE_ENV=production
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force
COPY --from=build /app/dist ./dist

USER node
EXPOSE 3000
# SOULBAH_ENV (dev|test|staging|production) est fourni par docker-compose / l'environnement :
# hors dev/test, le démarrage est refusé sans IA_SERVICE_TOKEN (et sans PG_SSL_CA si DATABASE_SSL=true).
CMD ["node", "dist/server.js"]
