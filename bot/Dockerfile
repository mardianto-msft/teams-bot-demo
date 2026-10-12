FROM python:3.12-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=80

WORKDIR /app
COPY pyproject.toml README.md ./
COPY src ./src
RUN pip install .

EXPOSE 80
CMD ["python", "src/main.py"]
