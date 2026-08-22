FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/remotecode \
    DISPLAY=:1

RUN apt-get update && apt-get install -y --no-install-recommends \
        xvfb \
        fluxbox \
        x11vnc \
        novnc \
        websockify \
        chromium \
        imagemagick \
        xdotool \
        x11-utils \
        xterm \
        ca-certificates \
        nodejs \
        npm \
        python3 \
    && rm -rf /var/lib/apt/lists/*

RUN useradd --create-home --home-dir /home/remotecode --shell /bin/bash remotecode \
    && mkdir -p /opt/remotecode-computer

COPY start.sh /opt/remotecode-computer/start.sh
COPY embed.html /opt/remotecode-computer/embed.html
COPY launch-browser.sh /opt/remotecode-computer/launch-browser.sh
RUN chmod 0755 /opt/remotecode-computer/start.sh /opt/remotecode-computer/launch-browser.sh

USER remotecode
WORKDIR /home/remotecode
EXPOSE 6080
CMD ["/opt/remotecode-computer/start.sh"]
