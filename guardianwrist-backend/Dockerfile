# Use the official lightweight Python image
FROM python:3.11-slim

# Set environment variables to prevent Python from writing pyc files and buffering stdout
ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV PORT=8080

WORKDIR /app

# Install system dependencies if you use PostgreSQL (like libpq-dev)
RUN apt-get update && apt-get install -y --no-install-recommends \
    gcc \
    libpq-dev \
    && rm -rf /var/lib/apt/lists/*

# Install Python dependencies
COPY requirements.txt /app/
RUN pip install --no-cache-dir -r requirements.txt

# Copy the rest of the application code
COPY . /app/

# Expose port 8080
EXPOSE 8080

# Run Gunicorn, binding to 0.0.0.0 and dynamically reading Cloud Run's port
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "guardianwrist-backend.wsgi:application"]