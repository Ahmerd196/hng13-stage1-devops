# Use a lightweight base image
FROM nginx:alpine

# Set working directory
WORKDIR /usr/share/nginx/html

# Copy all app files to Nginx web root
COPY . .

# Expose port 80
EXPOSE 80

# Start Nginx server
CMD ["nginx", "-g", "daemon off;"]

