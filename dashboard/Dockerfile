FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY . .

# Exclude test file from image
RUN rm -f test_dashboard.py

EXPOSE 7860

# Use gunicorn for production with gevent workers (SSE support)
# Falls back to flask dev server if gunicorn not available
CMD ["gunicorn", \
     "--bind", "0.0.0.0:7860", \
     "--workers", "2", \
     "--worker-class", "gthread", \
     "--threads", "4", \
     "--timeout", "300", \
     "--access-logfile", "-", \
     "app:app"]
