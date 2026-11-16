# Self-contained R Code Quest: webR and all the R packages the tasks need are
# downloaded into the image at build time, so the container itself runs with
# no internet access.
#
#   docker compose up --build        then open http://localhost:8080
#
# or without compose:
#   docker build -t r-code-quest .
#   docker run --rm -p 127.0.0.1:8080:8080 r-code-quest

FROM python:3.12-slim

WORKDIR /app

# 1. webR itself (~47 MB). With no tasks/ folder yet this downloads only webR,
#    so this layer is reused until setup_offline.py changes.
COPY setup_offline.py ./
RUN python setup_offline.py

# 2. The R packages listed in tasks/*/task.json (~37 MB). Re-runs when tasks
#    change; webR from step 1 is kept.
COPY tasks/ ./tasks/
RUN python setup_offline.py

# 3. The game itself.
COPY . .

USER nobody
EXPOSE 8080
CMD ["python", "serve.py", "--host", "0.0.0.0", "--port", "8080", "--no-browser"]
