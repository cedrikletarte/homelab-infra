FROM python:3.14.8-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --root-user-action=ignore --disable-pip-version-check -r requirements.txt \
    && mkdir /data && chown 1000:1000 /data
COPY bot.py .

USER 1000:1000
VOLUME /data
ENTRYPOINT ["python", "-u", "bot.py"]
