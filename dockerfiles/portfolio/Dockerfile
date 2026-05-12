# Stage 1: Build the Next.js app
FROM node:20-slim AS builder

WORKDIR /app
COPY . /app

# Install dependencies and build the app
RUN npm install
RUN npm run build

# Stage 2: Run the Next.js app with a lightweight image
FROM node:20-slim

WORKDIR /app

# Copy only the necessary files from the builder stage
COPY --from=builder /app/package.json ./
COPY --from=builder /app/package-lock.json ./
COPY --from=builder /app/.next ./.next
COPY --from=builder /app/public ./public
COPY --from=builder /app/node_modules ./node_modules

EXPOSE 3000

# Start the Next.js production server
CMD ["npm", "start"]