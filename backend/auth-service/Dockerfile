# Base image supplied as build argument
ARG NODE_IMAGE

# Build stage: install dependencies and compile Node.js
FROM ${NODE_IMAGE}

# Set the work directory
WORKDIR /usr/src/app

# Install runtime dependencies before copying source code to reuse the build cache
COPY package*.json ./
RUN npm ci --omit=dev

# Copy application source code and required files
COPY . .

# Create a writable logs directory for the application 
RUN mkdir -p /usr/src/app/logs \
    && chown -R node:node /usr/src/app/logs

# Run the application as a non-root user
USER node

# Execute the start script defined in package.json
CMD ["npm", "start"]
