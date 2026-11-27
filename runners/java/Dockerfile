FROM maven:3.9-eclipse-temurin-21

RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /app && chown 1000:1000 /app
ENV HOME=/tmp
WORKDIR /app

COPY runners/run.sh /usr/local/bin/run-bot.sh
RUN chmod +x /usr/local/bin/run-bot.sh

USER 1000:1000
ENTRYPOINT ["/usr/local/bin/run-bot.sh"]
