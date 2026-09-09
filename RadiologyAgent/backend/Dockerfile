FROM python:3.12-slim
WORKDIR /app
COPY backend/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt && useradd --uid 10001 --create-home radagent && mkdir /data && chown radagent /data
COPY backend /app/backend
ENV RADAGENT_BACKEND_DATA=/data
USER radagent
EXPOSE 8043
CMD ["uvicorn", "backend.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8043", "--no-access-log"]
