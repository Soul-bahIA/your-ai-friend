FROM node:22-alpine

WORKDIR /app

# Installation reproductible depuis le lockfile (tsx est une dépendance de prod).
COPY package.json package-lock.json ./
RUN npm ci --omit=dev && npm cache clean --force

COPY tsconfig.json ./
COPY src ./src

ENV NODE_ENV=production
USER node
EXPOSE 3000
CMD ["npm", "run", "start"]
